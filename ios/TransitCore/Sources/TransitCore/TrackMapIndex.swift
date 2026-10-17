import CryptoKit
import Foundation

public enum TrackMapError: Error, Equatable, Sendable, LocalizedError {
	case unsupportedSchema(Int)
	case mapVersionMismatch(String)
	case pdfDigestMismatch
	case pageMismatch
	case pageRotated(Int)
	case malformed(String)
	case assetsMissing

	public var errorDescription: String? {
		switch self {
		case .unsupportedSchema: return "This app version cannot read the server's track map data. Update the app to see trains on the map."
		case .mapVersionMismatch: return "The server's train positions are for a different edition of the track map. Update the app to see trains on the map."
		case .pdfDigestMismatch: return "The bundled track map does not match the train position data."
		case .pageMismatch, .pageRotated: return "The bundled track map has an unexpected page layout."
		case .malformed(let detail): return "The track map data is invalid: \(detail)."
		case .assetsMissing: return "The track map is not included in this build."
		}
	}
}

public enum TrackMapDigest {
	public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// A rectangle in top-left map coordinates.
public struct TrackMapRect: Codable, Sendable, Equatable {
	public var x: Double
	public var y: Double
	public var width: Double
	public var height: Double
	public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
	public var maxX: Double { x + width }
	public var maxY: Double { y + height }
	public var center: TrackMapPoint { TrackMapPoint(x: x + width / 2, y: y + height / 2) }
	public func contains(_ point: TrackMapPoint) -> Bool { point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY }
}

/// One station in search results: every map part sharing its station ID, such as the
/// platforms of a transfer complex. Unrelated stations never merge, even with one name.
public struct TrackMapStationMatch: Sendable, Equatable, Identifiable {
	public var name: String
	public var stationId: String
	public var stations: [TrackMapStation]
	/// Another result has the same name, so riders need a subtitle to tell them apart.
	public var sharesName = false
	public var id: String { stationId }

	private static let boroughs = ["M": "Manhattan", "B": "Brooklyn", "Bk": "Brooklyn", "Bx": "Bronx", "Q": "Queens", "SI": "Staten Island"]

	/// Lines and borough from the app's station catalog, only when the name is ambiguous.
	public func subtitle(routes: [String], borough: String?) -> String? {
		guard sharesName else { return nil }
		var parts: [String] = []
		if !routes.isEmpty { parts.append(routes.map(Display.displayRoute).joined(separator: " ")) }
		if let borough, !borough.isEmpty { parts.append(Self.boroughs[borough] ?? borough) }
		return parts.isEmpty ? "Another station with this name" : parts.joined(separator: " · ")
	}
}

/// A snapshot that matches the bundled map. Trains whose geometry cannot be trusted
/// stay listed with a reason but are never plotted.
public struct TrackMapAcceptedSnapshot: Sendable, Equatable {
	public let snapshot: TrackMapSnapshot
	/// Trains in server order, with any repeated key dropped after its first use.
	public let trains: [TrackMapTrain]
	public let invalidGeometry: [String: String]
	/// Headings for trains held at a platform whose directed rail gives one clear direction.
	public let stoppedHeadings: [String: Double]
	public let slowZones: [TrackMapSlowZone]
	public let invalidSlowZoneGeometry: [String: String]
	public func source(for train: TrackMapTrain) -> SourceState? { snapshot.sources.first { $0.id == train.feed } }
}

/// A validated topology for the bundled PDF, with lookups the map needs.
public struct TrackMapIndex: Sendable {
	public let topology: TrackMapTopology
	public let pageRect: TrackMapRect
	private let edgeIDs: Set<String>
	private let revenueEdgeIDs: Set<String>
	private let nodePoints: [String: TrackMapPoint]
	private let platformsByStop: [String: [TrackMapPlatform]]
	/// Directions of travel on directed revenue rail at each node, leaving or arriving.
	private let directedHeadings: [String: [Double]]
	private let searchable: [(station: TrackMapStation, normalized: String, words: [String])]

	/// `pdfDigest` is the SHA-256 of the PDF bytes actually bundled with the app.
	public init(topology: TrackMapTopology, pdfDigest: String) throws {
		guard topology.schemaVersion == TrackMapContract.schemaVersion else { throw TrackMapError.unsupportedSchema(topology.schemaVersion) }
		guard topology.mapVersion == TrackMapContract.mapVersion else { throw TrackMapError.mapVersionMismatch(topology.mapVersion) }
		guard topology.pdfSha256.lowercased() == TrackMapContract.pdfSHA256, pdfDigest.lowercased() == TrackMapContract.pdfSHA256 else { throw TrackMapError.pdfDigestMismatch }
		guard abs(topology.page.width - TrackMapContract.pageWidth) <= TrackMapContract.pageTolerance,
			abs(topology.page.height - TrackMapContract.pageHeight) <= TrackMapContract.pageTolerance else { throw TrackMapError.pageMismatch }
		let page = TrackMapRect(x: 0, y: 0, width: topology.page.width, height: topology.page.height)
		func check(_ point: TrackMapPoint, _ owner: String) throws {
			guard point.isFinite, page.contains(point) else { throw TrackMapError.malformed("\(owner) lies outside the map page") }
		}
		func unique<T>(_ values: [T], _ id: (T) -> String, _ kind: String) throws -> Set<String> {
			var seen = Set<String>()
			for value in values where !seen.insert(id(value)).inserted { throw TrackMapError.malformed("duplicate \(kind) \(id(value))") }
			return seen
		}
		let nodeIDs = try unique(topology.nodes, \.id, "node")
		_ = try unique(topology.stations, \.id, "station")
		_ = try unique(topology.platforms, \.id, "platform")
		edgeIDs = try unique(topology.edges, \.id, "edge")
		for node in topology.nodes { try check(node.point, "node \(node.id)") }
		for station in topology.stations { try check(station.point, "station \(station.id)") }
		let points = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0.point) })
		for edge in topology.edges {
			guard nodeIDs.contains(edge.from), nodeIDs.contains(edge.to) else { throw TrackMapError.malformed("edge \(edge.id) references a missing node") }
			guard edge.points.count >= 2 else { throw TrackMapError.malformed("edge \(edge.id) has fewer than two points") }
			for point in edge.points { try check(point, "edge \(edge.id)") }
			// Like the server, an edge must start and end exactly on its nodes and have length.
			guard edge.points.first == points[edge.from], edge.points.last == points[edge.to],
				edge.points.contains(where: { $0 != edge.points[0] }) else { throw TrackMapError.malformed("edge \(edge.id) is disconnected or has no length") }
		}
		for platform in topology.platforms where !nodeIDs.contains(platform.nodeId) { throw TrackMapError.malformed("platform \(platform.id) references a missing node") }
		self.topology = topology
		pageRect = page
		revenueEdgeIDs = Set(topology.edges.filter(\.revenue).map(\.id))
		nodePoints = points
		platformsByStop = Dictionary(grouping: topology.platforms, by: \.stopId)
		var headings: [String: [Double]] = [:]
		for edge in topology.edges where !edge.bidirectional && edge.revenue {
			let line = TrackMapPolyline(edge.points)
			if let start = line.sample(0).heading { headings[edge.from, default: []].append(start) }
			if let end = line.sample(1).heading { headings[edge.to, default: []].append(end) }
		}
		directedHeadings = headings
		searchable = topology.stations.map { station in
			let normalized = Self.normalize(station.name)
			return (station, normalized, normalized.split(separator: " ").map(String.init))
		}
	}

	public var attribution: String { topology.attribution }

	/// Rejects a snapshot made for other artwork; keeps per-train geometry problems local.
	public func accept(_ snapshot: TrackMapSnapshot) throws -> TrackMapAcceptedSnapshot {
		guard snapshot.schemaVersion == TrackMapContract.schemaVersion else { throw TrackMapError.unsupportedSchema(snapshot.schemaVersion) }
		guard snapshot.mapVersion == topology.mapVersion else { throw TrackMapError.mapVersionMismatch(snapshot.mapVersion) }
		guard snapshot.pdfSha256.lowercased() == topology.pdfSha256.lowercased() else { throw TrackMapError.pdfDigestMismatch }
		guard snapshot.generatedAt.isFinite else { throw TrackMapError.malformed("generation time is not a number") }
		var seen = Set<String>()
		var trains: [TrackMapTrain] = []
		var invalid: [String: String] = [:]
		var stopped: [String: Double] = [:]
		for train in snapshot.trains where seen.insert(train.key).inserted {
			trains.append(train)
			if let problem = geometryProblem(train) { invalid[train.key] = problem }
			else if let heading = stoppedHeading(train) { stopped[train.key] = heading }
		}
		var zoneIDs = Set<String>()
		var zones: [TrackMapSlowZone] = []
		var invalidZones: [String: String] = [:]
		for zone in snapshot.slowZones?.zones ?? [] where zoneIDs.insert(zone.id).inserted {
			zones.append(zone)
			if zone.paths.isEmpty { invalidZones[zone.id] = "Not on map: no reviewed rail path" }
			else if zone.paths.contains(where: { path in
				path.count < 2 || !path.allSatisfy { $0.isFinite && pageRect.contains($0) } || !path.contains { $0 != path.first }
			}) { invalidZones[zone.id] = "Not on map: invalid rail path" }
		}
		return TrackMapAcceptedSnapshot(snapshot: snapshot, trains: trains, invalidGeometry: invalid, stoppedHeadings: stopped, slowZones: zones, invalidSlowZoneGeometry: invalidZones)
	}

	/// A train without motion, drawn on its platform's node, faces along the directed rail
	/// there only when every directed edge at that node agrees. Otherwise it has no heading.
	func stoppedHeading(_ train: TrackMapTrain) -> Double? {
		guard train.motion == nil, train.placement == .track, let point = train.point, let stopId = train.stopId,
			let platforms = platformsByStop[stopId] else { return nil }
		let code = train.trackBasis == .unknown ? nil : train.trackCode
		let nodes = Set(platforms.filter { platform in code.map(platform.trackCodes.contains) ?? true }.map(\.nodeId)
			.filter { id in nodePoints[id].map { hypot($0.x - point.x, $0.y - point.y) <= 2 } ?? false })
		guard nodes.count == 1, let node = nodes.first, let headings = directedHeadings[node], let first = headings.first else { return nil }
		func difference(_ a: Double, _ b: Double) -> Double { abs(atan2(sin(a - b), cos(a - b))) }
		guard headings.allSatisfy({ difference($0, first) <= Double.pi / 9 }) else { return nil }
		return atan2(headings.map(sin).reduce(0, +), headings.map(cos).reduce(0, +))
	}

	private func geometryProblem(_ train: TrackMapTrain) -> String? {
		if let point = train.point, !(point.isFinite && pageRect.contains(point)) { return "Reported map point is outside the track map" }
		guard let motion = train.motion else { return nil }
		guard motion.points.count >= 2, motion.points.allSatisfy({ $0.isFinite && pageRect.contains($0) }) else { return "Motion path is outside the track map" }
		guard (0...1).contains(motion.fromProgress), (0...1).contains(motion.toProgress) else { return "Motion progress is out of range" }
		guard motion.toProgress >= motion.fromProgress else { return "Motion runs backwards along its path" }
		guard motion.startTime.isFinite, motion.endTime.isFinite, motion.endTime >= motion.startTime else { return "Motion time window is invalid" }
		guard motion.edgeIds.allSatisfy(edgeIDs.contains) else { return "Motion uses track that is not on this map" }
		guard motion.edgeIds.allSatisfy(revenueEdgeIDs.contains) else { return "Motion uses non-revenue track" }
		return nil
	}

	// MARK: Search

	public static func normalize(_ text: String) -> String {
		let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
		return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
			.split(separator: " ").joined(separator: " ")
	}

	/// Name prefixes first, then names whose words start with every typed word, then any
	/// other name containing the text. Parts of one station are one result.
	public func searchStations(_ query: String, limit: Int = 20) -> [TrackMapStationMatch] {
		let needle = Self.normalize(query)
		guard !needle.isEmpty else { return [] }
		let tokens = needle.split(separator: " ").map(String.init)
		var ranked: [String: (rank: Int, match: TrackMapStationMatch)] = [:]
		var order: [String] = []
		for entry in searchable {
			let rank: Int
			if entry.normalized.hasPrefix(needle) { rank = 0 }
			else if tokens.allSatisfy({ token in entry.words.contains { $0.hasPrefix(token) } }) { rank = 1 }
			else if entry.normalized.contains(needle) { rank = 2 }
			else { continue }
			let key = entry.station.stationId
			if var existing = ranked[key] {
				// The result takes the name of its best-matching part.
				if rank < existing.rank { existing.rank = rank; existing.match.name = entry.station.name }
				existing.match.stations.append(entry.station)
				ranked[key] = existing
			} else {
				ranked[key] = (rank, TrackMapStationMatch(name: entry.station.name, stationId: key, stations: [entry.station]))
				order.append(key)
			}
		}
		var results = order.compactMap { ranked[$0] }
			.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.match.name.localizedStandardCompare($1.match.name) == .orderedAscending }
			.prefix(limit).map(\.match)
		let names = Dictionary(grouping: results, by: \.name).filter { $0.value.count > 1 }
		for index in results.indices where names[results[index].name] != nil { results[index].sharesName = true }
		return results
	}

	// MARK: Focus

	/// The page area around the given app station IDs, or nil when none are on the map.
	public func focusRect(stationIDs: [String], padding: Double = 600) -> TrackMapRect? {
		let ids = Set(stationIDs)
		return focusRect(stations: topology.stations.filter { ids.contains($0.stationId) }, padding: padding)
	}

	public func focusRect(stations: [TrackMapStation], padding: Double = 600) -> TrackMapRect? {
		guard let first = stations.first else { return nil }
		var minX = first.point.x, maxX = first.point.x, minY = first.point.y, maxY = first.point.y
		for station in stations.dropFirst() {
			minX = min(minX, station.point.x); maxX = max(maxX, station.point.x)
			minY = min(minY, station.point.y); maxY = max(maxY, station.point.y)
		}
		let left = max(0, minX - padding), top = max(0, minY - padding)
		let right = min(pageRect.maxX, maxX + padding), bottom = min(pageRect.maxY, maxY + padding)
		return TrackMapRect(x: left, y: top, width: right - left, height: bottom - top)
	}
}
