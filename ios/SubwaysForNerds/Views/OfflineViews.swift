import SwiftUI
import TransitCore

/// The followed train, shown on the board until the rider ends it. Times are the
/// saved predictions; offline they are estimates, never observed positions.
struct ActiveRideBanner: View {
	@Environment(AppModel.self) private var app
	let open: (String) -> Void
	@State private var confirmEnd = false
	var body: some View {
		if let ride = app.activeRide {
			let trip = app.activeRideTrip
			let source = trip?.sourceTimestamp
			let cached = !app.connected || Display.freshness(source, now: app.now, staleAfter: trip?.train.map { Display.predictionStaleAfter($0.staleAfter, feed: $0.feed) }) != .live
			let stops = trip?.stops ?? []
			let withdrawn = ["CANCELED", "DELETED"].contains(trip?.train?.relationship ?? "") ? "Canceled in the last report · no estimate"
				: trip?.train?.assigned == false ? "Not assigned to a train in the last report · no estimate" : nil
			let next = withdrawn == nil ? OfflineDisplay.estimatedNextStopIndex(stops, now: app.now) : nil
			VStack(alignment: .leading, spacing: 4) {
				HStack(alignment: .center, spacing: 8) {
					if let route = trip?.train?.route { RouteBullet(route: route, small: true) }
					VStack(alignment: .leading, spacing: 1) {
						Text("Your ride\(trip?.train.map { " · \($0.destination)" } ?? "")").font(.subheadline.weight(.semibold))
						if let withdrawn {
							Text(withdrawn).font(.caption)
						} else if let next {
							// Always an estimate: the next stop comes from predictions, never an observed position.
							let stop = stops[next]
							let countdown = OfflineDisplay.countdown(stop: stop, sourceTimestamp: source, now: app.now, cached: cached, preferences: app.offlinePreferences, timeFormat: app.units.time, staleAfter: trip?.train.map { Display.predictionStaleAfter($0.staleAfter, feed: $0.feed) })
							Text("Estimated next stop \(stop.name) · \(countdown.unit == "min" ? "\(countdown.value) min" : "\(countdown.value) \(countdown.unit)")")
								.font(.caption.monospacedDigit())
								.accessibilityIdentifier("rideNextStop")
						} else if trip == nil {
							Text("No saved details for this train yet.").font(.caption)
						} else {
							Text("Every saved stop time has passed · estimate passed").font(.caption)
						}
					}
					Spacer(minLength: 4)
				}
				if cached, trip != nil {
					Text(OfflineDisplay.estimateLabel(timestamp: source, now: app.now, preferences: app.offlinePreferences) + (next == nil ? "" : " · next stop not observed"))
						.font(.caption2).foregroundStyle(.secondary)
				}
				if let trip, let label = OfflineDisplay.completenessLabel(trip) { Text(label).font(.caption2.weight(.semibold)) }
				HStack(spacing: 6) {
					Button { open(ride.tripKey) } label: { Label("Ride details", systemImage: "list.bullet").chip() }
						.buttonStyle(.plain).accessibilityIdentifier("openRide")
					Button { confirmEnd = true } label: { Label("End ride", systemImage: "xmark.circle").chip() }
						.buttonStyle(.plain).accessibilityIdentifier("endRideFromBanner")
						.confirmationDialog("End this ride?", isPresented: $confirmEnd, titleVisibility: .visible) {
							Button("End ride", role: .destructive) { Task { await app.endRide() } }
							Button("Cancel", role: .cancel) {}
						} message: { Text("Its snapshot then expires like other cached trips unless you saved it.") }
				}
			}
			.accessibilityElement(children: .contain)
			.accessibilityIdentifier("activeRideBanner")
		}
	}
}

/// Trips saved with "Save trip offline". They stay until removed here or from the trip.
struct SavedTripsView: View {
	@Environment(AppModel.self) private var app
	@State private var removing: CachedTrip?
	var body: some View {
		List {
			if let message = app.offlineActionError { Section { Notice(text: message) } }
			Section {
				ForEach(app.savedTrips) { trip in
					HStack(spacing: 8) {
						NavigationLink { TrainDetailView(tripKey: trip.tripKey, snapshotOnly: OfflineIdentity.isPositionalTrip(trip.tripKey)) } label: { SavedTripRow(trip: trip) }
							.accessibilityIdentifier("savedTrip_\(trip.tripKey)")
						Button { removing = trip } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
							.buttonStyle(.borderless).foregroundStyle(.red)
							.accessibilityLabel("Remove saved train \(trip.train?.destination ?? trip.tripKey)")
							.accessibilityIdentifier("removeSavedTrip_\(trip.tripKey)")
					}
				}
				if app.savedTrips.isEmpty { Text("Use Save trip offline in train details to keep a train here.").foregroundStyle(.secondary) }
			} footer: { Text("Saved trains stay on this device until you remove them. Their times are the predictions from when they were saved.") }
		}
		.themedList().navigationTitle("Saved trains").navigationBarTitleDisplayMode(.inline)
		.task { await app.reloadOfflineStatus() }
		.confirmationDialog("Remove this saved train?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { trip in
			Button("Remove saved train", role: .destructive) { Task { await app.removeSavedTrip(trip.tripKey) } }
			Button("Cancel", role: .cancel) {}
		} message: { _ in Text("Its offline snapshot may then expire with other cached trips.") }
	}
}

private struct SavedTripRow: View {
	@Environment(AppModel.self) private var app
	let trip: CachedTrip
	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			if let route = trip.train?.route { RouteBullet(route: route, small: true) }
			VStack(alignment: .leading, spacing: 1) {
				Text(trip.train?.destination ?? "Saved train").font(.subheadline.weight(.semibold))
				Text("\(trip.train.map { Display.directionLabel($0.direction) } ?? "Direction unknown") · saved \(Display.ageLabel(trip.savedAt, now: app.now)) · source \(Display.ageLabel(trip.sourceTimestamp, now: app.now))")
					.font(.caption2).foregroundStyle(.secondary)
				if let label = OfflineDisplay.completenessLabel(trip) { Text(label).font(.caption2.weight(.semibold)) }
				if app.activeRide?.tripKey == trip.tripKey { Text("Your current ride").font(.caption2.weight(.semibold)).foregroundStyle(app.theme.accent) }
			}
			Spacer(minLength: 0)
		}
		.accessibilityElement(children: .combine)
	}
}

/// Offline caching preferences, storage use and removal. Preferences sync with
/// settings; cached content and the active ride stay on this device.
struct OfflineSettingsView: View {
	@Environment(AppModel.self) private var app
	@State private var confirmAutomatic = false
	@State private var working = false
	private var preferences: OfflinePreferences { app.offlinePreferences }
	private func update(_ change: (inout OfflinePreferences) -> Void) {
		var value = app.offlinePreferences
		change(&value)
		value.tripDetailsPerLineDirection = min(value.tripDetailsPerLineDirection, value.departuresPerLineDirection)
		app.setOfflinePreferences(value)
	}
	private static let radiusChoices = [0, 1320, 2640, 5280, 10560, 26400]

	var body: some View {
		List {
			if let message = app.offlineActionError { Section { Notice(text: message).accessibilityIdentifier("offlineSettingsError") } }
			if let error = app.settingsError { Section { Notice(text: error) } }
			storageSection
			Section {
				Stepper("Departures per line and direction: \(preferences.departuresPerLineDirection)", value: Binding(get: { preferences.departuresPerLineDirection }, set: { value in update { $0.departuresPerLineDirection = value } }), in: OfflinePreferences.departuresRange)
					.accessibilityIdentifier("offlineDepartures")
				Stepper("Full trips per line and direction: \(preferences.tripDetailsPerLineDirection)", value: Binding(get: { preferences.tripDetailsPerLineDirection }, set: { value in update { $0.tripDetailsPerLineDirection = value } }), in: 0...preferences.departuresPerLineDirection)
					.accessibilityIdentifier("offlineTripDetails")
				Toggle("Save trains I open", isOn: Binding(get: { preferences.saveOpenedTrips }, set: { value in update { $0.saveOpenedTrips = value } }))
					.accessibilityIdentifier("offlineSaveOpenedTrips")
			} header: { ListHeader("Viewed station") } footer: { Text("Each board you view keeps its next departures for every line and direction, plus full stop lists for the next trains, while you are connected.") }
			Section {
				choiceRow(Self.radiusChoices, selected: preferences.nearbyRadiusFeet, identifier: "offlineRadius", label: { $0 == 0 ? "Off" : app.units.distance.radiusLabel(feet: $0) }) { value in update { $0.nearbyRadiusFeet = value } }
				Toggle("Also save trips at favorite and nearby stations", isOn: Binding(get: { preferences.preloadOtherStationTrips }, set: { value in update { $0.preloadOtherStationTrips = value } }))
					.accessibilityIdentifier("offlinePreloadOtherTrips")
			} header: { ListHeader("Other stations") } footer: { Text("Favorite boards, and boards within this straight-line distance of the station you are viewing, are saved in the background while the app is open. Your location is not used. Saving their trips works for favorites even with the distance off.") }
			Section {
				choiceRow(OfflinePreferences.estimateLimitChoices, selected: preferences.estimateLimitMinutes, identifier: "offlineEstimateLimit", label: { "\($0) min" }) { value in update { $0.estimateLimitMinutes = value } }
			} header: { ListHeader("Offline countdowns") } footer: { Text("Without a connection, countdowns use saved predictions until their source is this old, then show the last clock times. Every offline time is labeled as an estimate with its source age; passed times say estimate passed.") }
			Section {
				choiceRow(OfflinePreferences.retentionChoices, selected: preferences.retentionHours, identifier: "offlineRetention", label: { "\($0) h" }) { value in update { $0.retentionHours = value } }
				choiceRow(OfflinePreferences.storageLimitChoices, selected: preferences.storageLimitMiB, identifier: "offlineStorageLimit", label: { "\($0) MiB" }) { value in update { $0.storageLimitMiB = value } }
			} header: { ListHeader("Keep automatic copies") } footer: { Text("Automatic boards and trips expire after this many hours and the oldest are removed above the storage limit. Saved trains and your current ride are kept until you remove them.") }
			Section {
				Toggle("Widgets follow my ride", isOn: Binding(get: { preferences.widgetsFollowActiveRide }, set: { value in update { $0.widgetsFollowActiveRide = value } }))
					.accessibilityIdentifier("offlineWidgetsFollowRide")
			} footer: { Text("While you are on a train, Home and Lock Screen widgets show its next stops instead of a station board.") }
		}
		.themedList().navigationTitle("Offline").navigationBarTitleDisplayMode(.inline)
		.task { await app.reloadOfflineStatus() }
	}

	private var storageSection: some View {
		Section {
			if let usage = app.offlineUsage {
				LabeledContent("Stored", value: "\(ByteCountFormatter.string(fromByteCount: Int64(usage.totalBytes), countStyle: .file)) of \(preferences.storageLimitMiB) MiB").font(.subheadline)
					.accessibilityIdentifier("offlineUsage")
				Text("\(usage.boardCount) boards · \(usage.tripCount) trips · \(usage.savedTripCount) saved\(usage.protectedBytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(usage.protectedBytes), countStyle: .file)) kept" : "")")
					.font(.caption).foregroundStyle(.secondary)
				if usage.overLimit { Notice(text: "Saved trains and your ride use more than the limit. They are never removed automatically.") }
			} else if app.transitStore == nil {
				Notice(text: "Offline storage is unavailable. Try reopening the app.")
			} else { ProgressView("Checking storage…") }
			ForEach(app.offlineFailures) { failure in
				Notice(text: "Could not save \(failure.kind.rawValue) \(Display.ageLabel(failure.failedAt, now: app.now)): \(failure.message)")
			}
			if !app.offlineFailures.isEmpty {
				Button("Dismiss save errors") { Task { await app.dismissOfflineFailures() } }.buttonStyle(.borderless).actionStyle().font(.subheadline)
			}
			NavigationLink { SavedTripsView() } label: { LabeledContent("Saved trains", value: "\(app.savedTrips.count)") }
				.accessibilityIdentifier("offlineSavedTrains")
			Button("Clear automatic downloads", role: .destructive) { confirmAutomatic = true }
				.buttonStyle(.borderless).foregroundStyle(.red).font(.subheadline).frame(minHeight: 44)
				.disabled(working).accessibilityIdentifier("clearAutomaticOffline")
				// Attached to the button so iPad's popover points at it.
				.confirmationDialog("Clear automatic downloads?", isPresented: $confirmAutomatic, titleVisibility: .visible) {
					Button("Clear automatic downloads", role: .destructive) { Task { working = true; await app.removeAutomaticOfflineData(); working = false } }
					Button("Cancel", role: .cancel) {}
				} message: { Text("Removes boards and trips saved automatically for this server. Saved trains and your current ride are kept. Boards are saved again while you browse online.") }
		} header: { ListHeader("Storage") } footer: { Text("Offline boards, trips and your ride stay on this device and do not sync. These preferences transfer with your settings.") }
	}

	/// Direct choices instead of a menu, so the current value stays visible.
	private func choiceRow(_ values: [Int], selected: Int, identifier: String, label: @escaping (Int) -> String, set: @escaping (Int) -> Void) -> some View {
		ScrollView(.horizontal) {
			HStack(spacing: 6) {
				ForEach(values, id: \.self) { value in
					Button { set(value) } label: { Text(label(value)).chip(selected: value == selected) }
						.buttonStyle(.plain)
						.accessibilityIdentifier("\(identifier)_\(value)")
						.accessibilityAddTraits(value == selected ? .isSelected : [])
				}
			}
		}
		.scrollIndicators(.hidden)
	}
}
