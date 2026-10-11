import SwiftUI
import TransitCore
import FleetOffline

private struct FleetFilters {
	var q = ""
	var view = "groups"
	var category = ""
	var status = ""
	var equipment = ""
	var route = ""
	var yard = ""
	var retired = false
	var page = 1
	var query: [String: String] {
		["q": q, "view": view, "category": category, "status": status, "equipment": equipment, "route": route, "yard": yard, "retired": retired ? "true" : "", "page": String(page)]
	}
	var filterKey: String { query.filter { $0.key != "page" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }
}

/// A car or consist chosen in the fleet list.
struct FleetPick: Hashable {
	let id: String
	let kind: String
}

/// Regular widths show the fleet list beside the chosen car's details; compact widths push them.
struct FleetSplitView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.horizontalSizeClass) private var sizeClass
	@State private var selection: FleetPick?
	var body: some View {
		NavigationSplitView {
			FleetView(selection: $selection, sideBySide: sizeClass == .regular)
				.toolbar(removing: .sidebarToggle)
				.navigationSplitViewColumnWidth(400)
		} detail: {
			NavigationStack {
				if let selection {
					FleetDetailView(id: selection.id, kind: selection.kind, preferSaved: app.useSavedFleet)
				} else {
					ContentUnavailableView("Choose a car or consist", systemImage: "train.side.front.car", description: Text("Reports, roster facts and movement history appear here."))
						.themedList()
				}
			}
			.id(selection)
		}
		.navigationSplitViewStyle(.balanced)
		.background(app.theme.background)
	}
}

struct FleetView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@State private var filters: FleetFilters
	@State private var data: FleetPage?
	@State private var error: String?
	@State private var usingSaved = false
	@State private var requestGeneration = 0
	private let selection: Binding<FleetPick?>?
	private let sideBySide: Bool
	/// With a selection, rows choose what a split view's detail column shows; without one they push details.
	init(initialSearch: String = "", selection: Binding<FleetPick?>? = nil, sideBySide: Bool = false) {
		_filters = State(initialValue: FleetFilters(q: initialSearch))
		self.selection = selection
		self.sideBySide = sideBySide
	}
	private var loadKey: String { "\(filters.filterKey)|\(filters.page)|\(app.useSavedFleet)|\(app.offlineManifest?.id ?? "none")|\(phase)|\(app.endpoint)|\(app.connected)" }

	var body: some View {
		Group {
			if let selection { List(selection: selection) { sections } } else { List { sections } }
		}
		.themedList().tint(app.theme.selection).navigationTitle("The fleet").navigationBarTitleDisplayMode(.inline)
		.searchable(text: $filters.q, placement: sideBySide ? .sidebar : .navigationBarDrawer(displayMode: .always), prompt: "Car number, alias, or equipment")
		.autocorrectionDisabled().textInputAutocapitalization(.never)
		.onChange(of: filters.filterKey) { _, _ in filters.page = 1 }
		.task(id: loadKey) {
			guard phase == .active else { return }
			data = nil
			error = nil
			do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
			await poll(every: 10) { await refresh() }
		}
		.refreshable { await refresh() }
		.accessibilityIdentifier("fleetBrowser")
	}

	@ViewBuilder private var sections: some View {
		@Bindable var app = app
		if app.offlineManifest != nil {
			Section {
				Toggle("Browse saved fleet", isOn: $app.useSavedFleet).accessibilityIdentifier("browseSavedFleet")
			}
		}
		Section {
			Picker("Grouping", selection: $filters.view) {
				Text("Grouped consists").tag("groups")
				Text("Individual cars").tag("cars")
			}
			.pickerStyle(.segmented).accessibilityIdentifier("fleetGrouping")
			.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
			chipRow(value: $filters.category, options: [("", "All"), ("passenger", "Passenger"), ("work", "Work"), ("museum", "Museum"), ("sir", "SIR")])
				.accessibilityIdentifier("fleetCategory")
			chipRow(value: $filters.status, options: [("", "Any status"), ("reporting", "Reporting now"), ("unreported", "Not reporting now")])
				.accessibilityIdentifier("fleetStatus")
			DisclosureGroup {
				facetRow("Car type", value: $filters.equipment, options: data?.facets.equipment ?? [])
				facetRow("Route", value: $filters.route, options: data?.facets.route ?? [])
				facetRow("Yard", value: $filters.yard, options: data?.facets.yard ?? [])
				Toggle("Include retired / scrapped", isOn: $filters.retired).font(.subheadline)
				Button("Reset filters") { filters = FleetFilters() }.actionStyle()
			} label: {
				Text(moreFiltersLabel).font(.subheadline)
			}
		}
		.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
		if let error { Section { Notice(text: error) } }
		if usingSaved, let saved = app.offlineManifest {
			Section { Notice(text: "Saved fleet · \(easternDate(saved.generatedAt, timeFormat: app.units.time)). Every report is historical.") }
		}
		if let data {
			Section {
				if let message = data.error { Notice(text: message) }
				ForEach(data.rows) { row in
					let pick = FleetPick(id: row.id, kind: row.kind == "car" ? "cars" : "consists")
					let label = FleetRowView(row: row, now: app.now, historical: !app.connected || usingSaved || error != nil || data.error != nil)
					Group {
						if selection == nil {
							NavigationLink { FleetDetailView(id: pick.id, kind: pick.kind, preferSaved: app.useSavedFleet) } label: { label }
						} else {
							NavigationLink(value: pick) { label }
						}
					}
					.listRowInsets(.vertical, 6)
					.accessibilityIdentifier("fleet_\(row.id)")
				}
				if data.rows.isEmpty {
					ContentUnavailableView("No matching cars", systemImage: "tram", description: Text(usingSaved && filters.status == "reporting" ? "Saved reports are historical. Choose any reporting status to browse this download." : "Try another car number or change the filters."))
				}
			} header: { ListHeader("\(data.total.formatted()) matching \(filters.view == "cars" ? "cars" : "groups")") } footer: { Text("Missing from a feed does not mean inactive.") }
			Section {
				HStack {
					Button("Previous") { filters.page = max(1, data.page - 1) }.disabled(data.page <= 1)
					Spacer()
					Text("\(data.page) / \(max(1, data.pages))").font(.subheadline.monospacedDigit())
					Spacer()
					Button("Next") { filters.page = data.page + 1 }.disabled(data.page >= data.pages)
				}.buttonStyle(.borderless)
			}
			Section {
				DisclosureGroup("Coverage & sources") {
					VStack(alignment: .leading, spacing: 6) {
						ForEach(Array(data.coverage.enumerated()), id: \.offset) { _, coverage in Text("\(coverage.category): \(coverage.count.formatted()) cars. \(coverage.note)") }
						ForEach(Array(data.sources.enumerated()), id: \.offset) { _, evidence in EvidenceView(evidence: evidence) }
						Text("“All” covers the imported inventory, not every vehicle ever built. Collection starts when the server runs; historical movements cannot be reconstructed from a missing feed.").foregroundStyle(.secondary)
					}
					.font(.caption)
				}
			}
		} else if error == nil { ProgressView("Loading fleet inventory…") }
	}

	private var moreFiltersLabel: String {
		let active = [filters.equipment, filters.route, filters.yard].filter { !$0.isEmpty }.count + (filters.retired ? 1 : 0)
		return active == 0 ? "More filters" : "More filters · \(active) active"
	}

	private func chipRow(value: Binding<String>, options: [(id: String, name: String)]) -> some View {
		ScrollView(.horizontal) {
			HStack(spacing: 6) {
				ForEach(options, id: \.id) { option in
					Button { value.wrappedValue = option.id } label: { Text(option.name).chip(selected: value.wrappedValue == option.id) }
						.buttonStyle(.plain)
						.accessibilityAddTraits(value.wrappedValue == option.id ? .isSelected : [])
				}
			}
		}
		.scrollIndicators(.hidden)
	}

	private func facetRow(_ title: String, value: Binding<String>, options: [String]) -> some View {
		HStack(spacing: 4) {
			Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
			chipRow(value: value, options: [("", "All")] + options.filter { $0 != "unknown" }.map { ($0, $0) } + [("unknown", "Unknown / unreported")])
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title)
	}
	private func refresh() async {
		let identity = loadKey
		let query = filters.query
		requestGeneration += 1
		let generation = requestGeneration
		do {
			let value: FleetPage
			let savedMode = (app.useSavedFleet || !app.connected) && app.offlineManifest != nil
			if savedMode, let store = app.offlineStore {
				value = try await store.page(query: query)
				try Task.checkCancellation()
			} else {
				value = try await app.api.fleet(query: query)
				try Task.checkCancellation()
			}
			guard identity == loadKey, generation == requestGeneration else { return }
			usingSaved = savedMode
			data = value
			error = nil
		} catch {
			guard !Task.isCancelled, identity == loadKey, generation == requestGeneration else { return }
			if let store = app.offlineStore, app.offlineManifest != nil, let saved = try? await store.page(query: query) {
				guard !Task.isCancelled, identity == loadKey, generation == requestGeneration else { return }
				data = saved
				usingSaved = true
				self.error = "Live fleet unavailable. Showing the saved fleet download."
			} else { self.error = "Fleet data unavailable. Previous reports are not current; departures are unaffected." }
		}
	}
}

struct FleetDetailView: View {
	let id: String
	let kind: String
	var preferSaved = false
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@State private var data: FleetDetail?
	@State private var error: String?
	@State private var usingSaved = false
	@State private var loadingMore = false
	@State private var hasMore = false
	@State private var requestGeneration = 0
	@State private var liveTrip: String?
	private var current: FleetObservation? {
		guard app.connected, !usingSaved, error == nil else { return nil }
		return data?.cars.first { observedNow($0, now: app.now) && (!id.hasPrefix("observed:") || $0.last?.consistId == id) }?.last
	}
	private var loadKey: String { "\(phase)|\(id)|\(app.useSavedFleet)|\(app.offlineManifest?.id ?? "none")|\(app.endpoint)|\(app.connected)" }

	var body: some View {
		List {
			if let error { Section { Notice(text: error) } }
			if usingSaved, let manifest = app.offlineManifest {
				Section { Notice(text: "Saved fleet · \(easternDate(manifest.generatedAt, timeFormat: app.units.time)). Every report is historical.") }
			}
			if let data {
				Section {
					if kind != "cars", !data.cars.isEmpty, data.cars.count <= 20, data.cars.allSatisfy({ TrainFavorites.validCarID($0.id) }) {
						FavoriteConsistButton(ids: data.cars.map(\.id))
					}
					if let current {
						VStack(alignment: .leading, spacing: 2) {
							if let next = current.next, next.time == nil || (next.time ?? 0) >= app.now {
								HStack(alignment: .firstTextBaseline, spacing: 8) {
									Text("Next stop: \(next.name)").font(.subheadline.weight(.semibold))
									Spacer(minLength: 4)
									Text(Display.clockTime(next.time, format: app.units.time)).font(.subheadline.monospacedDigit())
								}
								Text("Estimated · \(current.route)").font(.caption2).foregroundStyle(.secondary)
							} else { Text("Next stop unavailable").font(.subheadline) }
						}
						ScrollView(.horizontal) {
							HStack(spacing: 6) {
								if let stationID = current.next?.stationId, current.next?.time == nil || (current.next?.time ?? 0) >= app.now {
									Button { app.selectStation(stationID) } label: {
										HStack(spacing: 4) { Image(systemName: "tram.fill"); Text("Open station board") }.chip()
									}
									.buttonStyle(.plain)
								}
								Button { liveTrip = current.tripKey } label: {
									HStack(spacing: 4) { Image(systemName: "arrow.right.circle"); Text("Open live train details") }.chip()
								}
								.buttonStyle(.plain)
							}
						}
						.scrollIndicators(.hidden)
						.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 10))
					} else { Text("Next stop unavailable").font(.subheadline).foregroundStyle(.secondary) }
				} footer: { Text("Reported order does not establish the leading end. Historical formations are not confirmed current links.") }
				ForEach(data.cars) { car in carSection(car) }
				Section {
					ForEach(Array(data.history.enumerated()), id: \.offset) { _, observation in
						VStack(alignment: .leading, spacing: 2) {
							Text("\(observation.route) · \(observation.location)").font(.subheadline.weight(.semibold))
							Text(easternDate(observation.timestamp, timeFormat: app.units.time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
							Text("Cars " + observation.cars.map { $0.split(separator: ":").last.map(String.init) ?? $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
							if !observation.consistId.isEmpty && observation.consistId != id {
								NavigationLink("Observed consist") { FleetDetailView(id: observation.consistId, kind: "consists", preferSaved: usingSaved) }
									.font(.caption)
							}
						}
						.listRowInsets(.vertical, 6)
					}
					if data.history.isEmpty { Text("No movement history collected for this period.").font(.subheadline).foregroundStyle(.secondary) }
					if usingSaved && hasMore {
						Button { Task { await loadMore() } } label: {
							if loadingMore { ProgressView() } else { Text("Load more history") }
						}.actionStyle().disabled(loadingMore).accessibilityIdentifier("loadMoreFleetHistory")
					}
				} header: { ListHeader(usingSaved ? "Downloaded movement history" : "Observed changes · last 30 days") } footer: {
					Text(usingSaved ? "All retained changes are available using Load more history. Times are observation times, not inferred movement times." : "Latest 200 changes. Download the fleet in Settings for all retained history. Times are observation times, not inferred movement times.")
				}
				Section { RawJSONView(value: data, title: "Fleet identifiers & reports") }
			} else if error == nil { ProgressView("Loading car history…") }
		}.themedList().navigationTitle("Car & consist details").navigationBarTitleDisplayMode(.inline)
			.navigationDestination(item: $liveTrip) { TrainDetailView(tripKey: $0) }
			.task(id: loadKey) {
				guard phase == .active else { return }
				data = nil
				await poll(every: 10) { await refresh() }
			}
			.refreshable { await refresh(force: true) }
			.accessibilityIdentifier("fleetDetails")
	}

	private func carSection(_ car: FleetCar) -> some View {
		let historical = !app.connected || usingSaved || error != nil
		return Section {
			HStack {
				if kind != "cars" {
					NavigationLink { FleetDetailView(id: car.id, kind: "cars", preferSaved: usingSaved) } label: {
						CarReportView(car: car, now: app.now, historical: historical)
					}
					.accessibilityLabel("\(car.number) · \(car.equipment) car details")
				} else {
					CarReportView(car: car, now: app.now, historical: historical)
				}
				if TrainFavorites.validCarID(car.id) { FavoriteCarButton(id: car.id) }
			}
			FactGrid(facts: carFacts(car)).listRowInsets(.vertical, 8)
			if let last = car.last, kind == "cars", !last.consistId.isEmpty {
				NavigationLink(!usingSaved && error == nil && observedNow(car, now: app.now) ? "Current consist" : "Last observed consist") {
					FleetDetailView(id: last.consistId, kind: "consists", preferSaved: usingSaved)
				}
				.font(.subheadline)
			}
			if let yard = car.estimatedYard {
				VStack(alignment: .leading, spacing: 2) {
					Text("Est. home yard: \(yard.name)").font(.subheadline)
					if let url = URL(string: yard.url) { Link("Source · \(yard.date)", destination: url).font(.caption).actionStyle() }
					Text(yard.note).font(.caption).foregroundStyle(.secondary)
				}
			}
			ForEach(Array((car.conflicts ?? []).enumerated()), id: \.offset) { _, conflict in Notice(text: conflict) }
			if !car.evidence.isEmpty {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(Array(car.evidence.enumerated()), id: \.offset) { _, evidence in EvidenceView(evidence: evidence) }
				}
			}
		} header: { Text("\(car.number) · \(car.equipment)").font(.footnote.weight(.semibold).monospacedDigit()).textCase(nil) }
	}

	/// Roster facts arrive as raw strings; trim midnight timestamps and whole-number decimals.
	private func carFacts(_ car: FleetCar) -> [(label: String, value: String)] {
		var facts: [(label: String, value: String)] = [("Roster", car.lifecycle)]
		if !car.aliases.isEmpty { facts.append(("Aliases", car.aliases.joined(separator: ", "))) }
		for key in (car.facts ?? [:]).keys.sorted() {
			var value = car.facts?[key] ?? ""
			if let range = value.range(of: #"^\d{4}-\d{2}-\d{2}(?=T00:00:00(\.0+)?Z?$)"#, options: .regularExpression) { value = String(value[range]) }
			else if value.range(of: #"^\d+\.0+$"#, options: .regularExpression) != nil { value = String(value.prefix { $0 != "." }) }
			let label = key.replacingOccurrences(of: "_", with: " ")
			facts.append((label.prefix(1).uppercased() + label.dropFirst(), value))
		}
		return facts
	}

	private func refresh(force: Bool = false) async {
		if usingSaved && (preferSaved || app.useSavedFleet || !app.connected) && data != nil && !force { return }
		let identity = loadKey
		requestGeneration += 1
		let generation = requestGeneration
		do {
			let value: FleetDetail
			let savedMode = (preferSaved || app.useSavedFleet || !app.connected) && app.offlineManifest != nil
			if savedMode, let store = app.offlineStore {
				value = try await store.detail(id: id, offset: 0, limit: 200)
				try Task.checkCancellation()
			} else {
				value = try await app.api.fleetDetail(kind: kind, id: id)
				try Task.checkCancellation()
			}
			guard identity == loadKey, generation == requestGeneration else { return }
			usingSaved = savedMode
			data = value
			hasMore = usingSaved && value.history.count == 200
			error = nil
		} catch {
			guard !Task.isCancelled, identity == loadKey, generation == requestGeneration else { return }
			if let store = app.offlineStore, app.offlineManifest != nil, let saved = try? await store.detail(id: id, offset: 0, limit: 200) {
				guard !Task.isCancelled, identity == loadKey, generation == requestGeneration else { return }
				if !force, usingSaved, let previous = data, previous.generatedAt == saved.generatedAt {
					data = FleetDetail(cars: saved.cars, history: previous.history, generatedAt: saved.generatedAt)
				} else {
					data = saved
					hasMore = saved.history.count == 200
				}
				usingSaved = true
				self.error = "Live fleet unavailable. Showing saved historical reports."
			} else { self.error = "Car history unavailable. Previous reports are not current." }
		}
	}

	private func loadMore() async {
		guard !loadingMore, let store = app.offlineStore, let previous = data else { return }
		let identity = loadKey
		let generation = requestGeneration
		loadingMore = true
		defer { loadingMore = false }
		do {
			let next = try await store.detail(id: id, offset: previous.history.count, limit: 200)
			try Task.checkCancellation()
			guard identity == loadKey, generation == requestGeneration, data?.history.count == previous.history.count else { return }
			data = FleetDetail(cars: previous.cars, history: previous.history + next.history, generatedAt: previous.generatedAt)
			hasMore = next.history.count == 200
		} catch { if !Task.isCancelled { self.error = "Could not load more saved history. Try again." } }
	}
}

private func observedNow(_ car: FleetCar, now: TimeInterval) -> Bool {
	car.reporting == true && car.last.map { now - $0.timestamp <= 90 } == true
}

private struct FleetRowView: View {
	let row: FleetRow
	let now: TimeInterval
	let historical: Bool
	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(row.cars.map(\.number).joined(separator: " · ")).font(.subheadline.weight(.semibold).monospacedDigit())
				Spacer(minLength: 4)
				Text("\(Array(Set(row.cars.map(\.equipment))).sorted().joined(separator: " / ")) · \(row.cars.count) \(row.cars.count == 1 ? "car" : "cars")\(row.id.hasPrefix("set:") ? " · documented link" : "")")
					.font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
			}
			if let car = row.cars.first { CarReportView(car: car, now: now, historical: historical) }
		}
		.accessibilityElement(children: .combine)
	}
}

private struct CarReportView: View {
	let car: FleetCar
	let now: TimeInterval
	let historical: Bool
	private var live: Bool { !historical && observedNow(car, now: now) }
	private var status: String { live ? "\(car.last?.route ?? "") · currently reporting" : car.last == nil ? "Never observed" : "Last seen" }
	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text("\(Text(status).fontWeight(.semibold)) · \(car.last?.location ?? "No location report collected")")
				.font(.caption)
			if let last = car.last {
				Text("Position \(Display.ageLabel(last.locationTimestamp, now: now)) · association \(Display.ageLabel(last.timestamp, now: now))").font(.caption2).foregroundStyle(.secondary)
			}
			if !live { Text("Est. home yard: \(car.estimatedYard?.name ?? "unknown")").font(.caption2).foregroundStyle(.secondary) }
		}.accessibilityElement(children: .combine)
	}
}

private struct EvidenceView: View {
	let evidence: Evidence
	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			if let url = URL(string: evidence.url) { Link("Source · \(evidence.date)", destination: url).actionStyle() }
			else { Text("Source · \(evidence.date)") }
			Text(evidence.note).foregroundStyle(.secondary)
		}
		.font(.caption)
	}
}
