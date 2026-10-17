import Foundation
@testable import TransitCore

/// A small synthetic map on the real page size: a vertical track from Times Sq to
/// Union Sq, then a horizontal one to Bedford Av. It is test geometry only.
enum TrackMapFixture {
	static let times = TrackMapStation(id: "station-127", stationId: "127", partId: "127", name: "Times Sq-42 St", point: TrackMapPoint(x: 100, y: 100), stopIds: ["127N", "127S"])
	static let union = TrackMapStation(id: "station-635", stationId: "602", partId: "635", name: "14 St-Union Sq", point: TrackMapPoint(x: 100, y: 1100), stopIds: ["635N", "635S"])
	static let unionL = TrackMapStation(id: "station-L03", stationId: "602", partId: "L03", name: "14 St-Union Sq", point: TrackMapPoint(x: 140, y: 1100), stopIds: ["L03N", "L03S"])
	static let bedford = TrackMapStation(id: "station-L08", stationId: "L08", partId: "L08", name: "Bedford Av", point: TrackMapPoint(x: 1100, y: 1100), stopIds: ["L08N", "L08S"])
	/// Two unrelated stations that share a name, on different lines.
	static let twentyThirdBroadway = TrackMapStation(id: "station-R19", stationId: "R19", partId: "R19", name: "23 St", point: TrackMapPoint(x: 3000, y: 3000), stopIds: ["R19N", "R19S"])
	static let twentyThirdSixth = TrackMapStation(id: "station-D18", stationId: "D18", partId: "D18", name: "23 St", point: TrackMapPoint(x: 3500, y: 2000), stopIds: ["D18N", "D18S"])
	static let jamaica = TrackMapStation(id: "station-G05", stationId: "G05", partId: "G05", name: "Jamaica Center–Parsons/Archer", point: TrackMapPoint(x: 2000, y: 3000), stopIds: ["G05N"])

	static func topology(mapVersion: String = TrackMapContract.mapVersion, pdfSha256: String = TrackMapContract.pdfSHA256,
		page: TrackMapPage = TrackMapPage(width: TrackMapContract.pageWidth, height: TrackMapContract.pageHeight),
		nodes: [TrackMapNode]? = nil, edges: [TrackMapEdge]? = nil, platforms: [TrackMapPlatform]? = nil) -> TrackMapTopology {
		TrackMapTopology(mapVersion: mapVersion, pdfSha256: pdfSha256, page: page, attribution: "Track map by Vanshnookenraggen, v2.6.8", sourceURL: "https://www.vanshnookenraggen.com/_index/docs/NYC_full_trackmap.pdf",
			stations: [times, union, unionL, bedford, twentyThirdBroadway, twentyThirdSixth, jamaica],
			nodes: nodes ?? [TrackMapNode(id: "n1", point: TrackMapPoint(x: 100, y: 100)), TrackMapNode(id: "n2", point: TrackMapPoint(x: 100, y: 1100)), TrackMapNode(id: "n3", point: TrackMapPoint(x: 1100, y: 1100))],
			edges: edges ?? [
				TrackMapEdge(id: "e1", from: "n1", to: "n2", points: [TrackMapPoint(x: 100, y: 100), TrackMapPoint(x: 100, y: 1100)], bidirectional: true, revenue: true),
				TrackMapEdge(id: "e2", from: "n2", to: "n3", points: [TrackMapPoint(x: 100, y: 1100), TrackMapPoint(x: 1100, y: 1100)], bidirectional: true, revenue: true)
			],
			platforms: platforms ?? [TrackMapPlatform(id: "p1", stopId: "635S", trackCodes: ["1"], nodeId: "n2")],
			coverage: TrackMapTopologyCoverage(mappedStopIds: ["635S"], unresolvedStopIds: [], notes: ["Synthetic"]))
	}

	static func index(_ topology: TrackMapTopology = topology()) throws -> TrackMapIndex { try TrackMapIndex(topology: topology, pdfDigest: TrackMapContract.pdfSHA256) }

	/// An L-shaped motion: 1000 points down, then 1000 across, from t=1000 to t=1100.
	static let motion = TrackMapMotion(edgeIds: ["e1", "e2"], points: [TrackMapPoint(x: 100, y: 100), TrackMapPoint(x: 100, y: 1100), TrackMapPoint(x: 1100, y: 1100)],
		fromProgress: 0, toProgress: 1, startTime: 1000, endTime: 1100)

	static func train(_ key: String = "gtfs|20260916|A1|", route: String = "4", feed: String = "gtfs", placement: TrackMapPlacement = .track, positionBasis: TrackMapPositionBasis = .estimated,
		trackBasis: TrackMapTrackBasis = .reported, trackCode: String? = "1", point: TrackMapPoint? = TrackMapPoint(x: 100, y: 100), motion: TrackMapMotion? = TrackMapFixture.motion,
		observedAt: TimeInterval? = 990, feedTimestamp: TimeInterval = 995, staleAt: TimeInterval? = 1080, expiresAt: TimeInterval? = 1290, freshness: TrackMapFreshness = .live) -> TrackMapTrain {
		TrackMapTrain(key: key, feed: feed, route: route, destination: "Crown Hts-Utica Av", direction: "S", stopId: "635S", stationId: "635", status: "IN_TRANSIT_TO", trackCode: trackCode,
			trackBasis: trackBasis, positionBasis: positionBasis, placement: placement, point: point, motion: motion, observedAt: observedAt, feedTimestamp: feedTimestamp,
			staleAt: staleAt, expiresAt: expiresAt, freshness: freshness)
	}

	static func snapshot(_ trains: [TrackMapTrain] = [train()], generatedAt: TimeInterval = 1000, sources: [SourceState] = [SourceState(id: "gtfs", timestamp: 995, fetchedAt: 998)],
		mapVersion: String = TrackMapContract.mapVersion, pdfSha256: String = TrackMapContract.pdfSHA256) -> TrackMapSnapshot {
		TrackMapSnapshot(mapVersion: mapVersion, pdfSha256: pdfSha256, generatedAt: generatedAt, sources: sources, trains: trains, coverage: TrackMapSnapshotCoverage(placed: trains.count))
	}

	static func accepted(_ trains: [TrackMapTrain] = [train()], generatedAt: TimeInterval = 1000, sources: [SourceState] = [SourceState(id: "gtfs", timestamp: 995, fetchedAt: 998)]) throws -> TrackMapAcceptedSnapshot {
		try index().accept(snapshot(trains, generatedAt: generatedAt, sources: sources))
	}

	/// The wire format exactly as the server sends it, including JSON nulls.
	static let snapshotJSON = """
	{
		"schemaVersion": 1,
		"mapVersion": "nyc-2.6.8-v1",
		"pdfSha256": "b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71",
		"generatedAt": 1000,
		"sources": [{"id": "gtfs", "timestamp": 995, "fetchedAt": 998, "error": null, "staleAfter": 90}],
		"trains": [
			{
				"key": "gtfs|20260916|A1|", "feed": "gtfs", "route": "4", "destination": "Crown Hts-Utica Av", "direction": "S",
				"stopId": "635S", "stationId": "635", "trackCode": "1", "trackBasis": "reported", "positionBasis": "estimated", "placement": "track",
				"point": {"x": 100, "y": 100},
				"motion": {"edgeIds": ["e1", "e2"], "points": [{"x": 100, "y": 100}, {"x": 100, "y": 1100}, {"x": 1100, "y": 1100}], "fromProgress": 0, "toProgress": 1, "startTime": 1000, "endTime": 1100},
				"observedAt": 990, "feedTimestamp": 995, "staleAt": 1080, "expiresAt": 1290, "freshness": "live"
			},
			{
				"key": "gtfs|20260916|B2|", "feed": "gtfs", "route": "GS", "destination": "Grand Central", "direction": "N",
				"trackBasis": "unknown", "positionBasis": "unknown", "placement": "unplaced",
				"observedAt": null, "feedTimestamp": 995, "staleAt": null, "expiresAt": null, "freshness": "unavailable", "reason": "No vehicle observation"
			}
		],
		"coverage": {"placed": 1, "uncertain": 0, "unplaced": 1}
	}
	"""
}
