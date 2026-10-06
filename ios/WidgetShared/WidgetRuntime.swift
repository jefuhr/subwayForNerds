import AppIntents
import CoreLocation
import Foundation
import TransitCore
import WidgetKit

struct SubwayWidgetEntry: TimelineEntry, Sendable {
	let date: Date
	var station: Station?
	var board: Board?
	var preference = StationPreference(view: .direction)
	var display = WidgetDisplayOptions()
	var lockScreen = LockScreenWidgetOptions()
	var themeID = "subway"
	var cached = false
	var locationNotice: String?
	var message: String?
	var url: URL { station.map { WidgetLink.board(stationID: $0.id) } ?? URL(string: "subwaynerds://board")! }
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
		Task {
			let entry = await WidgetBoardLoader.load()
			var entries = [entry]
			if !entry.cached, let board = entry.board {
				let dates = widgetTimelineDates(board, now: entry.date.timeIntervalSince1970)
				for date in dates {
					let saved = SubwayWidgetEntry(date: Date(timeIntervalSince1970: date), station: entry.station, board: board, preference: entry.preference, display: entry.display, lockScreen: entry.lockScreen, themeID: entry.themeID, cached: date == dates.last, locationNotice: entry.locationNotice, message: entry.message)
					entries.append(saved)
				}
			}
			completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(300))))
		}
	}
}

enum WidgetBoardLoader {
	static func load() async -> SubwayWidgetEntry {
		var entry = SubwayWidgetEntry(date: .now)
		guard let store = WidgetSharedStore.configured(), let state = try? store.load() else {
			entry.message = "Open the app to set up your widgets."
			return entry
		}
		entry.themeID = state.themeID
		entry.display = state.widgets.display
		entry.lockScreen = state.widgets.lockScreen
		guard !state.favorites.isEmpty else { entry.message = "Add a favorite in the app."; return entry }
		let locator = await WidgetLocator()
		let location = await locator.locate()
		let previous = store.selection()
		let fallbackCoordinate = previous == nil ? state.appLocation : nil
		guard let station = state.selectedStation(location: location ?? fallbackCoordinate, previous: previous?.stationID) else {
			entry.message = "Open the app to load your favorite stations."
			return entry
		}
		entry.station = station
		entry.preference = state.widgets.preference(for: station.id, app: state.appFilters)
		entry.locationNotice = location == nil ? "Location unavailable · saved favorite" : nil
		try? store.saveSelection(stationID: station.id, location: location ?? previous?.location ?? fallbackCoordinate)
		if station.departureMode == "external" { entry.message = "Open station for departure times."; return entry }
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
		do {
			let board = try await TransitAPI(baseURL: endpoint, session: session).board(stationID: station.id)
			entry.board = board
			try? store.saveBoard(board, endpoint: endpoint.absoluteString)
		} catch {
			entry.board = store.board(stationID: station.id, endpoint: endpoint.absoluteString)
			entry.cached = true
			entry.message = entry.board == nil ? "Train feed unavailable. Tap to open the app." : nil
		}
		return entry
	}
}

struct RefreshSubwayWidget: AppIntent {
	static let title: LocalizedStringResource = "Refresh train widget"
	static let description = IntentDescription("Request a new report for your closest favorite station.")
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
		guard let location = locations.last, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 300 else { finish(nil); return }
		finish(WidgetCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp.timeIntervalSince1970))
	}
	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
	private func finish(_ location: WidgetCoordinate?) { timeout?.cancel(); timeout = nil; let continuation = waiting; waiting = nil; continuation?.resume(returning: location) }
}
