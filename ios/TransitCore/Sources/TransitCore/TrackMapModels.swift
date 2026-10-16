import Foundation

/// Mirrors `shared/track-map.ts`. Every coordinate is a PDF point measured from the
/// top left of the map page's crop box; times are Unix seconds.
public enum TrackMapContract {
	public static let schemaVersion = 1
	public static let mapVersion = "nyc-2.6.8-v1"
	public static let pdfSHA256 = "b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71"
	public static let pageWidth = 7344.0
	public static let pageHeight = 11540.6
	/// Allowed difference between the topology's page and the bundled PDF's crop box.
	public static let pageTolerance = 0.5
	/// Markers go stale this long after their oldest evidence.
	public static let liveSeconds: TimeInterval = 90
	/// Markers disappear this long after their oldest evidence, however recently it was read.
	public static let expirySeconds: TimeInterval = 300
	/// Evidence may be this far past the snapshot's generation time before it counts as future.
	public static let futureTolerance: TimeInterval = 5
	public static let pollInterval: Duration = .seconds(15)
	public static let topologyResource = "topology"
	public static let pdfResource = "NYC_full_trackmap"
	public static let resourceDirectory = "TrackMap"
}

public struct TrackMapPoint: Codable, Sendable, Hashable {
	public var x: Double
	public var y: Double
	public init(x: Double, y: Double) { self.x = x; self.y = y }
	public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct TrackMapStation: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var stationId: String
	public var partId: String
	public var name: String
	public var point: TrackMapPoint
	public var stopIds: [String]
	public init(id: String, stationId: String, partId: String, name: String, point: TrackMapPoint, stopIds: [String]) {
		self.id = id; self.stationId = stationId; self.partId = partId; self.name = name; self.point = point; self.stopIds = stopIds
	}
}

public struct TrackMapNode: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var point: TrackMapPoint
	public init(id: String, point: TrackMapPoint) { self.id = id; self.point = point }
}

public struct TrackMapEdge: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var from: String
	public var to: String
	public var points: [TrackMapPoint]
	public var bidirectional: Bool
	public var revenue: Bool
	public init(id: String, from: String, to: String, points: [TrackMapPoint], bidirectional: Bool, revenue: Bool) {
		self.id = id; self.from = from; self.to = to; self.points = points; self.bidirectional = bidirectional; self.revenue = revenue
	}
}

public struct TrackMapPlatform: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var stopId: String
	public var trackCodes: [String]
	public var nodeId: String
	public init(id: String, stopId: String, trackCodes: [String], nodeId: String) {
		self.id = id; self.stopId = stopId; self.trackCodes = trackCodes; self.nodeId = nodeId
	}
}

public struct TrackMapPage: Codable, Sendable, Equatable {
	public var width: Double
	public var height: Double
	public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct TrackMapTopologyCoverage: Codable, Sendable, Equatable {
	public var mappedStopIds: [String]
	public var unresolvedStopIds: [String]
	public var notes: [String]
	public init(mappedStopIds: [String] = [], unresolvedStopIds: [String] = [], notes: [String] = []) {
		self.mappedStopIds = mappedStopIds; self.unresolvedStopIds = unresolvedStopIds; self.notes = notes
	}
}

public struct TrackMapTopology: Codable, Sendable, Equatable {
	public var schemaVersion: Int
	public var mapVersion: String
	public var pdfSha256: String
	public var page: TrackMapPage
	public var attribution: String
	public var sourceURL: String
	public var stations: [TrackMapStation]
	public var nodes: [TrackMapNode]
	public var edges: [TrackMapEdge]
	public var platforms: [TrackMapPlatform]
	public var coverage: TrackMapTopologyCoverage

	public init(schemaVersion: Int = TrackMapContract.schemaVersion, mapVersion: String = TrackMapContract.mapVersion, pdfSha256: String = TrackMapContract.pdfSHA256,
		page: TrackMapPage = TrackMapPage(width: TrackMapContract.pageWidth, height: TrackMapContract.pageHeight), attribution: String, sourceURL: String,
		stations: [TrackMapStation] = [], nodes: [TrackMapNode] = [], edges: [TrackMapEdge] = [], platforms: [TrackMapPlatform] = [], coverage: TrackMapTopologyCoverage = TrackMapTopologyCoverage()) {
		self.schemaVersion = schemaVersion; self.mapVersion = mapVersion; self.pdfSha256 = pdfSha256; self.page = page
		self.attribution = attribution; self.sourceURL = sourceURL; self.stations = stations; self.nodes = nodes
		self.edges = edges; self.platforms = platforms; self.coverage = coverage
	}

	private enum CodingKeys: String, CodingKey {
		case schemaVersion, mapVersion, pdfSha256, page, attribution, sourceURL, stations, nodes, edges, platforms, coverage
	}

	/// The schema version is checked before anything else, so a newer file reports
	/// itself as unsupported instead of as an unrelated missing field.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		guard schemaVersion == TrackMapContract.schemaVersion else { throw TrackMapError.unsupportedSchema(schemaVersion) }
		mapVersion = try container.decode(String.self, forKey: .mapVersion)
		pdfSha256 = try container.decode(String.self, forKey: .pdfSha256)
		page = try container.decode(TrackMapPage.self, forKey: .page)
		attribution = try container.decode(String.self, forKey: .attribution)
		sourceURL = try container.decode(String.self, forKey: .sourceURL)
		stations = try container.decode([TrackMapStation].self, forKey: .stations)
		nodes = try container.decode([TrackMapNode].self, forKey: .nodes)
		edges = try container.decode([TrackMapEdge].self, forKey: .edges)
		platforms = try container.decode([TrackMapPlatform].self, forKey: .platforms)
		coverage = try container.decode(TrackMapTopologyCoverage.self, forKey: .coverage)
	}
}

/// Progress is arc length along `points`, from 0 to 1, clamped to this window.
public struct TrackMapMotion: Codable, Sendable, Equatable {
	public var edgeIds: [String]
	public var points: [TrackMapPoint]
	public var fromProgress: Double
	public var toProgress: Double
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	public init(edgeIds: [String], points: [TrackMapPoint], fromProgress: Double, toProgress: Double, startTime: TimeInterval, endTime: TimeInterval) {
		self.edgeIds = edgeIds; self.points = points; self.fromProgress = fromProgress; self.toProgress = toProgress; self.startTime = startTime; self.endTime = endTime
	}
}

public enum TrackMapTrackBasis: String, Codable, Sendable, CaseIterable { case reported, scheduled, inferred, unknown }
public enum TrackMapPositionBasis: String, Codable, Sendable, CaseIterable { case reported, estimated, unknown }
public enum TrackMapPlacement: String, Codable, Sendable, CaseIterable { case track, nearStop = "near-stop", unplaced }
public enum TrackMapFreshness: String, Codable, Sendable, CaseIterable { case live, stale, unavailable }

public struct TrackMapTrain: Codable, Sendable, Equatable, Identifiable {
	public var key: String
	public var feed: String
	public var route: String
	public var destination: String
	public var direction: String
	public var stopId: String?
	public var stationId: String?
	public var status: String?
	public var trackCode: String?
	public var trackBasis: TrackMapTrackBasis
	public var positionBasis: TrackMapPositionBasis
	public var placement: TrackMapPlacement
	public var point: TrackMapPoint?
	public var motion: TrackMapMotion?
	/// Original evidence age, never the time a cached response was read.
	public var observedAt: TimeInterval?
	public var feedTimestamp: TimeInterval
	public var staleAt: TimeInterval?
	public var expiresAt: TimeInterval?
	public var freshness: TrackMapFreshness
	public var reason: String?
	public var id: String { key }

	public init(key: String, feed: String, route: String, destination: String, direction: String, stopId: String? = nil, stationId: String? = nil, status: String? = nil,
		trackCode: String? = nil, trackBasis: TrackMapTrackBasis = .unknown, positionBasis: TrackMapPositionBasis = .unknown, placement: TrackMapPlacement = .unplaced,
		point: TrackMapPoint? = nil, motion: TrackMapMotion? = nil, observedAt: TimeInterval?, feedTimestamp: TimeInterval, staleAt: TimeInterval?, expiresAt: TimeInterval?,
		freshness: TrackMapFreshness, reason: String? = nil) {
		self.key = key; self.feed = feed; self.route = route; self.destination = destination; self.direction = direction
		self.stopId = stopId; self.stationId = stationId; self.status = status; self.trackCode = trackCode; self.trackBasis = trackBasis
		self.positionBasis = positionBasis; self.placement = placement; self.point = point; self.motion = motion; self.observedAt = observedAt
		self.feedTimestamp = feedTimestamp; self.staleAt = staleAt; self.expiresAt = expiresAt; self.freshness = freshness; self.reason = reason
	}
}

public struct TrackMapSnapshotCoverage: Codable, Sendable, Equatable {
	public var placed: Int
	public var uncertain: Int
	public var unplaced: Int
	public init(placed: Int = 0, uncertain: Int = 0, unplaced: Int = 0) { self.placed = placed; self.uncertain = uncertain; self.unplaced = unplaced }
}

public struct TrackMapSnapshot: Codable, Sendable, Equatable {
	public var schemaVersion: Int
	public var mapVersion: String
	public var pdfSha256: String
	public var generatedAt: TimeInterval
	public var sources: [SourceState]
	public var trains: [TrackMapTrain]
	public var coverage: TrackMapSnapshotCoverage

	public init(schemaVersion: Int = TrackMapContract.schemaVersion, mapVersion: String = TrackMapContract.mapVersion, pdfSha256: String = TrackMapContract.pdfSHA256,
		generatedAt: TimeInterval, sources: [SourceState] = [], trains: [TrackMapTrain] = [], coverage: TrackMapSnapshotCoverage = TrackMapSnapshotCoverage()) {
		self.schemaVersion = schemaVersion; self.mapVersion = mapVersion; self.pdfSha256 = pdfSha256; self.generatedAt = generatedAt
		self.sources = sources; self.trains = trains; self.coverage = coverage
	}

	private enum CodingKeys: String, CodingKey { case schemaVersion, mapVersion, pdfSha256, generatedAt, sources, trains, coverage }

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		guard schemaVersion == TrackMapContract.schemaVersion else { throw TrackMapError.unsupportedSchema(schemaVersion) }
		mapVersion = try container.decode(String.self, forKey: .mapVersion)
		pdfSha256 = try container.decode(String.self, forKey: .pdfSha256)
		generatedAt = try container.decode(TimeInterval.self, forKey: .generatedAt)
		sources = try container.decode([SourceState].self, forKey: .sources)
		trains = try container.decode([TrackMapTrain].self, forKey: .trains)
		coverage = try container.decode(TrackMapSnapshotCoverage.self, forKey: .coverage)
	}
}
