import Foundation
import Observation

/// Where the map was last looking: a top-left map point at the center of the view and
/// the PDF view's scale factor. Kept outside the view so tab switches and rotation keep it.
public struct TrackMapViewport: Codable, Sendable, Equatable {
	public var center: TrackMapPoint
	public var zoom: Double
	public init(center: TrackMapPoint, zoom: Double) { self.center = center; self.zoom = zoom }
	/// Rounded so UI tests can compare viewports across tab switches, details and rotation.
	public var accessibilityValue: String {
		"Center \(Int(center.x.rounded())), \(Int(center.y.rounded())); zoom \(String(format: "%.3f", zoom))"
	}
}

public enum TrackMapFeedStatus: Sendable, Equatable {
	case idle
	case loading
	case ready
	case offline
	case failed(String)
	case rejected(TrackMapError)
}

/// Live train positions for one validated map. Responses only ever change the trains
/// shown; the viewport and route filters belong to the person using the map.
@MainActor @Observable
public final class TrackMapSession {
	public let index: TrackMapIndex
	public private(set) var snapshot: TrackMapAcceptedSnapshot?
	public private(set) var status = TrackMapFeedStatus.idle
	/// Device time of the last accepted response.
	public private(set) var receivedAt: TimeInterval?
	/// Device time at which estimates stopped advancing because of an outage.
	public private(set) var frozenAt: TimeInterval?
	public var viewport: TrackMapViewport?
	public var selectedRoutes: Set<String> = []
	@ObservationIgnored private var generation = 0

	public init(index: TrackMapIndex) { self.index = index }

	public static func shouldPoll(mapTabSelected: Bool, mapOnScreen: Bool, sceneActive: Bool) -> Bool { mapTabSelected && mapOnScreen && sceneActive }

	public func conditions(now: TimeInterval, reduceMotion: Bool) -> TrackMapConditions {
		TrackMapConditions(now: now, animationAllowed: !reduceMotion, frozenAt: frozenAt)
	}

	/// Clears trains from another endpoint. A response already in flight is discarded.
	public func reset() {
		generation += 1
		snapshot = nil
		receivedAt = nil
		frozenAt = nil
		status = .idle
	}

	/// Estimates stay frozen after reconnecting until a response arrives; only the banner clears.
	public func setConnected(_ connected: Bool, now: TimeInterval) {
		guard !connected else {
			if status == .offline { status = snapshot == nil ? .idle : .ready }
			return
		}
		if frozenAt == nil { frozenAt = now }
		status = .offline
	}

	public func refresh(now: @autoclosure () -> TimeInterval, fetch: @Sendable () async throws -> TrackMapSnapshot) async {
		generation += 1
		let requested = generation
		if snapshot == nil, status != .offline { status = .loading }
		do {
			let value = try await fetch()
			guard requested == generation, !Task.isCancelled else { return }
			do {
				snapshot = try index.accept(value)
				receivedAt = now()
				frozenAt = nil
				status = .ready
			} catch let error as TrackMapError { reject(error) }
		} catch let error as TrackMapError {
			guard requested == generation, !Task.isCancelled else { return }
			reject(error)
		} catch {
			guard requested == generation, !Task.isCancelled, !Self.isCancellation(error) else { return }
			if frozenAt == nil { frozenAt = now() }
			status = .failed(snapshot == nil ? "Train positions are unavailable. Retrying every 15 seconds." : "Could not update train positions. Showing the last positions without movement.")
		}
	}

	/// Polls until the calling task is cancelled; cancelling also cancels the request in flight.
	public func run(now: @escaping @MainActor () -> TimeInterval, interval: Duration = TrackMapContract.pollInterval,
		sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
		fetch: @escaping @Sendable () async throws -> TrackMapSnapshot) async {
		while !Task.isCancelled {
			await refresh(now: now(), fetch: fetch)
			do { try await sleep(interval) } catch { return }
		}
	}

	private func reject(_ error: TrackMapError) {
		// Data for other artwork is never plotted, not even the last accepted positions.
		snapshot = nil
		receivedAt = nil
		frozenAt = nil
		status = .rejected(error)
	}

	private static func isCancellation(_ error: Error) -> Bool {
		error is CancellationError || (error as? URLError)?.code == .cancelled
	}
}
