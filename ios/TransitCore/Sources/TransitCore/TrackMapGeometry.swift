import CoreGraphics
import Foundation

/// Converts between the contract's top-left map points and PDF page space, whose
/// origin is the bottom left of the media box. Only an unrotated page is accepted.
public struct TrackMapPageTransform: Sendable, Equatable {
	public let cropBox: CGRect

	public init(cropBox: CGRect, rotation: Int, page: TrackMapPage) throws {
		let normalized = ((rotation % 360) + 360) % 360
		guard normalized == 0 else { throw TrackMapError.pageRotated(normalized) }
		guard abs(cropBox.width - page.width) <= TrackMapContract.pageTolerance, abs(cropBox.height - page.height) <= TrackMapContract.pageTolerance else { throw TrackMapError.pageMismatch }
		self.cropBox = cropBox
	}

	public func pdfPoint(_ point: TrackMapPoint) -> CGPoint { CGPoint(x: cropBox.minX + point.x, y: cropBox.maxY - point.y) }
	public func mapPoint(_ point: CGPoint) -> TrackMapPoint { TrackMapPoint(x: point.x - cropBox.minX, y: cropBox.maxY - point.y) }
	public func pdfRect(_ rect: TrackMapRect) -> CGRect { CGRect(x: cropBox.minX + rect.x, y: cropBox.maxY - rect.maxY, width: rect.width, height: rect.height) }
	public func mapRect(_ rect: CGRect) -> TrackMapRect { TrackMapRect(x: rect.minX - cropBox.minX, y: cropBox.maxY - rect.maxY, width: rect.width, height: rect.height) }
}

public struct TrackMapSample: Sendable, Equatable {
	public var point: TrackMapPoint
	/// Radians in top-left map space (0 points right, π/2 points down); nil when the line has no length.
	public var heading: Double?
}

/// A polyline measured by arc length, so equal progress covers equal distance.
public struct TrackMapPolyline: Sendable {
	public let points: [TrackMapPoint]
	private let cumulative: [Double]
	public var length: Double { cumulative.last ?? 0 }

	public init(_ points: [TrackMapPoint]) {
		self.points = points
		var running = 0.0
		var lengths: [Double] = points.isEmpty ? [] : [0]
		for (a, b) in zip(points, points.dropFirst()) {
			running += hypot(b.x - a.x, b.y - a.y)
			lengths.append(running)
		}
		cumulative = lengths
	}

	public func sample(_ progress: Double) -> TrackMapSample {
		guard let first = points.first else { return TrackMapSample(point: TrackMapPoint(x: 0, y: 0), heading: nil) }
		guard length > 0 else { return TrackMapSample(point: first, heading: nil) }
		let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
		let target = clamped * length
		// The first segment that reaches the target and has length.
		var index = points.count - 1
		for i in 1..<points.count where cumulative[i] > cumulative[i - 1] && cumulative[i] >= target { index = i; break }
		let a = points[index - 1], b = points[index]
		let span = cumulative[index] - cumulative[index - 1]
		let t = span > 0 ? min(1, max(0, (target - cumulative[index - 1]) / span)) : 0
		let point = TrackMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
		return TrackMapSample(point: point, heading: span > 0 ? atan2(b.y - a.y, b.x - a.x) : nil)
	}
}

public enum TrackMapMotionMath {
	/// Linear progress across the motion's time window, held at each end outside it.
	public static func progress(_ motion: TrackMapMotion, at time: TimeInterval) -> Double {
		if time <= motion.startTime && motion.endTime > motion.startTime { return motion.fromProgress }
		if time >= motion.endTime { return motion.toProgress }
		if time < motion.startTime { return motion.fromProgress }
		let fraction = (time - motion.startTime) / (motion.endTime - motion.startTime)
		return motion.fromProgress + (motion.toProgress - motion.fromProgress) * fraction
	}
}

public enum TrackMapOverlap {
	/// Candidates within `radius` of `point`, nearest first.
	public static func hits<ID>(at point: CGPoint, candidates: [(ID, CGPoint)], radius: Double) -> [ID] {
		candidates.map { ($0.0, hypot($0.1.x - point.x, $0.1.y - point.y)) }
			.filter { $0.1 <= radius }
			.sorted { $0.1 < $1.1 }
			.map(\.0)
	}
}
