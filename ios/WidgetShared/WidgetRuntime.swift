import AppIntents
import CoreLocation
import Foundation
import TransitCore
import WidgetKit

struct SubwayWidgetEntry: TimelineEntry, Sendable {
	var date: Date
	var displayUntil: Date?
	var station: Station?
	var board: Board?
	var preference = StationPreference(view: .direction)
	var display = WidgetDisplayOptions()
	var lockScreen = LockScreenWidgetOptions()
	var themeID = "subway"
	var units = UnitPreferences()
	var offline = OfflinePreferences()
	var ride: WidgetRideSnapshot?
	var cached = false
	var locationNotice: String?
	var message: String?
	var url: URL { ride.map { WidgetLink.ride(tripKey: $0.ride.tripKey) } ?? station.map { WidgetLink.board(stationID: $0.id) } ?? URL(string: "subwaynerds://board")! }
	/// Mixed car types give previews the longer details that real boards often have.
	static func example(date: Date = .now) -> SubwayWidgetEntry {
		let station = Station(id: "44", name: "Church Av", borough: "Bk", routes: ["B", "Q"], lat: 40.65, lon: -73.96)
		let rows = (0..<28).map { index in
			Departure(key: "example-\(index)", tripKey: "example-\(index)", route: index.isMultiple(of: 3) ? "B" : "Q", destination: index.isMultiple(of: 2) ? "96 St" : "Coney Island", direction: index.isMultiple(of: 2) ? "NORTH" : "SOUTH", stopId: "D28", partId: "D28", area: "Brighton", time: date.timeIntervalSince1970 + Double(index + 2) * 60, scheduledTrack: index.isMultiple(of: 2) ? "A2" : "A1", pattern: "Local", patternSource: "reported", location: "", feed: "example", timestamp: date.timeIntervalSince1970, consist: Consist(cars: index.isMultiple(of: 3) ? [ConsistCar(number: "4149", type: "R211A"), ConsistCar(number: "4148", type: "R211A")] : [ConsistCar(number: "8713", type: "R160A"), ConsistCar(number: "9802", type: "R160B")], updatedAt: date.timeIntervalSince1970, fetchedAt: date.timeIntervalSince1970))
		}
		return SubwayWidgetEntry(date: date, station: station, board: Board(station: station, generatedAt: date.timeIntervalSince1970, departures: rows))
	}
}

struct SubwayTimelineProvider: TimelineProvider {
	func placeholder(in context: Context) -> SubwayWidgetEntry { .example() }
	func getSnapshot(in context: Context, completion: @escaping @Sendable (SubwayWidgetEntry) -> Void) {
		if context.isPreview { completion(.example()); return }
		Task { completion(await WidgetBoardLoader.load()) }
	}
	func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SubwayWidgetEntry>) -> Void) {
		let isLockScreen: Bool
		switch context.family {
		case .accessoryInline, .accessoryCircular, .accessoryRectangular: isLockScreen = true
		default: isLockScreen = false
		}
		Task {
			let entry = await WidgetBoardLoader.load()
			var entries = [entry]
			if let board = entry.ride?.timelineBoard() ?? entry.board {
				var visible = board
				if entry.ride == nil {
					visible.departures = widgetDepartures(board, preference: entry.preference, limit: 14, now: entry.date.timeIntervalSince1970, cached: true).flatMap(\.departures)
				}
				let dates = widgetOfflineTimelineDates(visible, now: entry.date.timeIntervalSince1970, maximumAgeMinutes: entry.offline.estimateLimitMinutes)
				for date in dates {
					var saved = entry
					saved.date = Date(timeIntervalSince1970: date)
					saved.cached = entry.cached || board.departures.contains { Display.freshness($0, now: date) != .live }
					if entry.ride == nil { saved.message = Display.njtPredictionMessage(board, now: date, cached: saved.cached) ?? entry.message }
					entries.append(saved)
				}
			}
			for index in entries.indices {
				entries[index].displayUntil = index + 1 < entries.count ? entries[index + 1].date : entries[index].date.addingTimeInterval(60)
			}
			let interval = (isLockScreen ? entry.lockScreen.display : entry.display).refreshInterval.seconds
			completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(interval))))
		}
	}
}

enum WidgetBoardLoader {
	static func load() async -> SubwayWidgetEntry {
		var entry = SubwayWidgetEntry(date: .now)
		guard let store = WidgetSharedStore.configured(), var state = try? store.load() else {
			entry.message = "Open the app to set up your widgets."
			return entry
		}
		entry.themeID = state.themeID
		entry.units = state.units
		entry.display = state.widgets.display
		entry.lockScreen = state.widgets.lockScreen
		entry.offline = state.offline
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 8
		configuration.timeoutIntervalForResource = 8
		#if DEBUG
		let endpoint = URL(string: state.endpoint) ?? TransitAPI.productionBaseURL
		#else
		let endpoint = TransitAPI.productionBaseURL
		#endif
		let session = URLSession(configuration: configuration)
		defer { session.finishTasksAndInvalidate() }
		let client = TransitAPI(baseURL: endpoint, session: session)
		if state.offline.widgetsFollowActiveRide, let saved = store.ride(endpoint: endpoint.absoluteString) {
			entry.ride = saved
			entry.cached = true
			// PATH rows are not stable trip identities. Such rows cannot be pinned.
			if saved.trip.train?.feed != "path" {
				do {
					let detail = try await client.trip(key: saved.ride.tripKey)
					if detail.train.key == saved.ride.tripKey, detail.train.timestamp >= (saved.trip.sourceTimestamp ?? 0) {
						var trip = saved.trip
						trip.detail = detail
						if detail.train.timestamp > (saved.trip.sourceTimestamp ?? 0) { trip.savedAt = Date().timeIntervalSince1970 }
						if try store.updateRideTrip(trip, for: saved.ride, endpoint: endpoint.absoluteString) { entry.cached = false }
					}
				} catch { /* A saved ride remains useful when its live trip disappears. */ }
			}
			// Re-read after awaiting: the app may have ended or replaced this ride.
			state = (try? store.load()) ?? state
			entry.offline = state.offline
			entry.ride = state.offline.widgetsFollowActiveRide ? store.ride(endpoint: endpoint.absoluteString) : nil
			if let current = entry.ride {
				if current.ride != saved.ride { entry.cached = true }
				// The source may have advanced during the fetch; age it at completion.
				entry.date = .now
				return entry
			}
		}
		let location: WidgetCoordinate?
		if state.effectiveStationSelection.mode == .favorite && state.favorites.isEmpty { location = nil }
		else {
			let locator = await WidgetLocator()
			location = await locator.locate()
			// The app may publish a newer location or settings while Core Location waits.
			state = (try? store.load()) ?? state
		}
		entry.themeID = state.themeID
		entry.units = state.units
		entry.display = state.widgets.display
		entry.lockScreen = state.widgets.lockScreen
		entry.offline = state.offline
		guard state.effectiveStationSelection.mode != .favorite || !state.favorites.isEmpty else { entry.message = "Add a favorite or choose Closest station in Settings."; return entry }
		let previous = store.selection()
		let now = Date().timeIntervalSince1970
		let coordinate = WidgetCoordinate.newestUsable(in: [location, state.appLocation, previous?.location], now: now)
		guard var station = state.selectedStation(location: coordinate, previous: previous?.stationID, now: now) else {
			entry.message = "Open the app to load your stations."
			return entry
		}
		if let saved = try? store.saveSelection(stationID: station.id, location: coordinate) {
			// Another widget may have saved a newer fix between our read and write.
			station = state.selectedStation(location: saved.location, previous: saved.stationID) ?? station
		}
		entry.station = station
		entry.preference = state.widgets.preference(for: station.id, app: state.appFilters)
		entry.locationNotice = coordinate == nil ? "Location unavailable · saved station" : nil
		do {
			let board = try await client.board(stationID: station.id)
			entry.cached = false
			entry.board = (try? store.saveBoard(board, endpoint: endpoint.absoluteString)) ?? board
		} catch {
			entry.board = store.board(stationID: station.id, endpoint: endpoint.absoluteString)
			entry.cached = true
			entry.message = entry.board == nil ? "Train feed unavailable. Tap to open the app." : nil
		}
		if let board = entry.board {
			if board.usesExternalDepartures {
				entry.board = nil
				entry.message = "Open station for departure times."
			} else { entry.message = Display.njtPredictionMessage(board, now: Date().timeIntervalSince1970, cached: entry.cached) }
		} else if station.departureMode == "external" { entry.message = "Open station for departure times." }
		// Include the location lookup and network wait in the age of the entry.
		entry.date = .now
		return entry
	}
}

struct RefreshSubwayWidget: AppIntent {
	static let title: LocalizedStringResource = "Refresh train widget"
	static let description = IntentDescription("Request a new report using your widget station settings.")
	func perform() async throws -> some IntentResult {
		_ = await WidgetBoardLoader.load()
		WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind)
		return .result()
	}
}

@MainActor
private final class WidgetLocator: NSObject, @preconcurrency CLLocationManagerDelegate {
	private let manager = CLLocationManager()
	private var waiting: CheckedContinuation<WidgetCoordinate?, Never>?
	private var timeout: Task<Void, Never>?
	override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
	func locate() async -> WidgetCoordinate? {
		guard manager.isAuthorizedForWidgetUpdates else { return nil }
		return await withCheckedContinuation { continuation in
			waiting = continuation
			timeout = Task { [weak self] in
				do { try await Task.sleep(for: .seconds(4)) } catch { return }
				self?.finish(nil)
			}
			manager.requestLocation()
		}
	}
	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		let coordinates = locations.filter { $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0 }.map {
			WidgetCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, timestamp: $0.timestamp.timeIntervalSince1970)
		}
		finish(WidgetCoordinate.newestUsable(in: coordinates, now: Date().timeIntervalSince1970))
	}
	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
	private func finish(_ location: WidgetCoordinate?) {
		timeout?.cancel(); timeout = nil
		let continuation = waiting; waiting = nil
		manager.stopUpdatingLocation()
		continuation?.resume(returning: location)
	}
}
