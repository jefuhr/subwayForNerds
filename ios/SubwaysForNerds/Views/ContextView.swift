import SwiftUI
import TransitCore

struct ContextView: View {
	let station: Station
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@State private var context: StationContext?
	@State private var error: String?
	@State private var requestGeneration = 0
	private var outageSource: SourceState? { context?.sources.first { $0.id == "outages" } }
	private var equipmentSource: SourceState? { context?.sources.first { $0.id == "equipment" } }
	private var outageFresh: Bool { app.connected && error == nil && (outageSource?.timestamp ?? 0) > 0 && outageSource?.error == nil && app.now - (outageSource?.fetchedAt ?? 0) <= 120 }
	var body: some View {
		List {
			if station.departureMode == "external" {
				Section {
					VStack(alignment: .leading, spacing: 3) {
						Text(station.parts.first?.line ?? "NJ Transit light rail").font(.headline)
						Text("\(station.municipality.map { "\($0) · " } ?? "")NJ Transit station \(station.parts.first?.stationId ?? station.id)").font(.subheadline)
					}
					Notice(text: "Live equipment status and entrance details are not connected for this station.")
					Link("NJ Transit light rail accessibility and travel information", destination: TransitLinks.njtAccessibility).actionStyle()
				}
			} else {
				Section {
					ForEach(station.parts) { part in
						VStack(alignment: .leading, spacing: 2) {
							HStack(alignment: .firstTextBaseline, spacing: 8) {
								Text(part.line).font(.subheadline.weight(.semibold))
								Spacer(minLength: 4)
								HStack(spacing: 4) {
									Image(systemName: "figure.roll")
									Text(part.ada == "1" ? "ADA accessible" : part.ada == "2" ? "Partially accessible" : part.ada == "0" ? "Not ADA accessible" : "Accessibility information unavailable")
								}
								.font(.caption.weight(.semibold))
								.foregroundStyle(part.ada == "1" ? app.theme.accent : app.theme.ink.opacity(0.7))
							}
							if !part.adaNotes.isEmpty { Text(part.adaNotes).font(.caption) }
							Text("\(part.id) · \(part.north) / \(part.south)").font(.caption2).foregroundStyle(.secondary)
						}
						.accessibilityElement(children: .combine)
						.listRowInsets(.vertical, 8)
					}
				} header: { ListHeader("Accessibility") }
				if let error { Section { Notice(text: error) } }
				if let context {
					Section {
						if !outageFresh { Notice(text: "Current equipment status is unavailable or stale") }
						ForEach(Array(context.equipment.enumerated()), id: \.offset) { _, equipment in equipmentRow(equipment, context: context).listRowInsets(.vertical, 8) }
						if context.equipment.isEmpty { Text(equipmentSource?.fetchedAt == nil ? "Equipment feed not yet available" : "No equipment records matched this station").font(.subheadline).foregroundStyle(.secondary) }
					} header: { ListHeader("Elevators & escalators") } footer: {
						Text(outageSource?.fetchedAt == nil ? "Outage feed not yet received" : "Outage feed fetched \(Display.ageLabel(outageSource?.fetchedAt, now: app.now))")
					}
					Section {
						ForEach(Array(context.entrances.enumerated()), id: \.offset) { index, entrance in
							HStack(spacing: 8) {
								VStack(alignment: .leading, spacing: 1) {
									Text("\(entrance["constituent_station_name"] ?? station.name) · \(entrance["entrance_type"] ?? "Entrance")").font(.subheadline.weight(.semibold))
									Text("Entry \(entrance["entry_allowed"]?.lowercased() ?? "unknown") · exit \(entrance["exit_allowed"]?.lowercased() ?? "unknown")").font(.caption2).foregroundStyle(.secondary)
								}
								Spacer(minLength: 4)
								if let url = entranceURL(entrance) {
									Link(destination: url) { Image(systemName: "map").frame(minWidth: 44, minHeight: 44) }
										.buttonStyle(.borderless).actionStyle()
										.accessibilityLabel("View entrance \(index + 1) on map")
								}
							}
							.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 8))
						}
						if context.entrances.isEmpty { Text("No entrance data available").font(.subheadline).foregroundStyle(.secondary) }
					} header: { ListHeader("Entrances · \(context.entrances.count)") } footer: { Text("Entrance coordinates are published locations, not walking directions.") }
					if !context.sources.isEmpty {
						Section { SourcesView(sources: context.sources, now: app.now) } header: { ListHeader("Source freshness") }
					}
					Section { RawJSONView(value: context, title: "Published station records") }
				} else if error == nil { ProgressView("Loading station context…") }
			}
		}.themedList().navigationTitle(station.name).navigationBarTitleDisplayMode(.inline)
			.refreshable { await refresh() }
			.task(id: "\(phase)|\(app.endpoint)|\(app.connected)") { if phase == .active && station.departureMode != "external" { await poll(every: 60) { await refresh() } } }
			.accessibilityIdentifier("stationContext")
	}

	private func equipmentRow(_ equipment: [String: String], context: StationContext) -> some View {
		let reports = context.outages.filter { ($0["equipment"] ?? $0["equipmentno"]) == equipment["equipmentno"] }
		let current = reports.filter { $0["isupcomingoutage"] != "Y" }
		let status = !current.isEmpty ? "Outage reported" : outageFresh && equipmentSource?.fetchedAt != nil ? equipment["isactive"] == "N" ? "Inactive" : "No current outage reported" : "Status unknown"
		return VStack(alignment: .leading, spacing: 2) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("\(equipment["equipmentno"] ?? "Equipment") · \(equipment["shortdescription"] ?? equipment["serving"] ?? "")").font(.subheadline.weight(.semibold))
				Spacer(minLength: 4)
				Text(status).font(.caption.weight(.semibold)).foregroundStyle(current.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
			}
			if let serving = equipment["serving"] { Text(serving).font(.caption) }
			ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
				Text("\(report["isupcomingoutage"] == "Y" ? "Upcoming: " : "")\(report["reason"] ?? "Outage") · \(report["outagedate"] ?? "Time unknown") → \(report["estimatedreturntoservice"] ?? "Return time unknown")").font(.caption2).foregroundStyle(.secondary)
			}
			if !reports.isEmpty, let alternative = equipment["alternativeroute"], !alternative.isEmpty {
				DisclosureGroup("Travel alternative") { Text(alternative).font(.caption) }.font(.caption.weight(.semibold))
			}
		}
	}
	private func entranceURL(_ entrance: [String: String]) -> URL? {
		guard let lat = entrance["entrance_latitude"].flatMap(Double.init), let lon = entrance["entrance_longitude"].flatMap(Double.init), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
		return URL(string: "https://www.openstreetmap.org/?mlat=\(lat)&mlon=\(lon)#map=19/\(lat)/\(lon)")
	}
	private func refresh() async {
		guard station.departureMode != "external" else { return }
		let requestedEndpoint = app.endpoint
		requestGeneration += 1
		let generation = requestGeneration
		do {
			let value = try await app.api.context(stationID: station.id)
			try Task.checkCancellation()
			guard requestedEndpoint == app.endpoint, generation == requestGeneration else { return }
			context = value; error = nil
		} catch { if !Task.isCancelled, requestedEndpoint == app.endpoint, generation == requestGeneration { self.error = "Station context unavailable. Previous equipment reports may be stale." } }
	}
}

struct AlertsView: View {
	let alerts: [ServiceAlert]
	let sources: [SourceState]
	var cached = false
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		List {
			Section {
				if cached || !app.connected || sources.first(where: { $0.id == "subway-alerts" }).map({ $0.error != nil || Display.freshness($0.timestamp, now: app.now) != .live }) != false {
					Notice(text: "Alert information is cached, stale, or unavailable. Check source ages before relying on these reports.")
				}
				SourcesView(sources: sources.filter { $0.id == "subway-alerts" }, now: app.now)
			}
			if alerts.isEmpty { ContentUnavailableView("No matching alerts", systemImage: "checkmark.circle", description: Text("An empty alert list does not guarantee normal service. Check the alert feed age above.")) }
			ForEach(alerts) { alert in
				Section {
					VStack(alignment: .leading, spacing: 6) {
						if !alert.routes.isEmpty { RouteStrip(routes: alert.routes) }
						Text(alert.title).font(.subheadline.weight(.semibold))
						Text(alert.description).font(.footnote)
						if let meta = meta(alert) { Text(meta).font(.caption.weight(.semibold)) }
						ForEach(Array(alert.periods.enumerated()), id: \.offset) { _, period in
							Text("\(period.start.map(easternDate) ?? "Start not specified") → \(period.end.map(easternDate) ?? "Until further notice")").font(.caption2).foregroundStyle(.secondary)
						}
					}
					.listRowInsets(.vertical, 10)
					RawJSONView(value: alert, title: "Alert scope, selectors & source").font(.subheadline)
				}
			}
		}.themedList().navigationTitle("Service alerts").navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
	}

	private func meta(_ alert: ServiceAlert) -> String? {
		var parts: [String] = []
		if let effect = alert.effect, !effect.isEmpty { parts.append("Effect: \(effect)") }
		if let type = alert.alertType, !type.isEmpty { parts.append("Type: \(type)") }
		if let period = alert.activePeriodLabel, !period.isEmpty { parts.append(period) }
		if let plans = alert.planNumbers, !plans.isEmpty { parts.append("Plans " + plans.joined(separator: ", ")) }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}
