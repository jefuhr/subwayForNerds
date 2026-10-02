import Foundation

// Strings retain unknown future server values; optional fields preserve unknown versus false/zero.
public struct StationPart: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var stationId: String
	public var name: String
	public var line: String
	public var routes: [String]
	public var lat: Double
	public var lon: Double
	public var ada: String
	public var adaNotes: String
	public var north: String
	public var south: String

	public init(id: String, stationId: String, name: String, line: String, routes: [String] = [], lat: Double, lon: Double, ada: String, adaNotes: String = "", north: String, south: String) {
		self.id = id
		self.stationId = stationId
		self.name = name
		self.line = line
		self.routes = routes
		self.lat = lat
		self.lon = lon
		self.ada = ada
		self.adaNotes = adaNotes
		self.north = north
		self.south = south
	}
}

public struct Station: Codable, Sendable, Equatable, Identifiable {
	public var municipality: String?
	public var departureMode: String?
	public var id: String
	public var name: String
	public var borough: String
	public var routes: [String]
	public var lat: Double
	public var lon: Double
	public var parts: [StationPart]

	public init(id: String, name: String, borough: String, routes: [String] = [], lat: Double, lon: Double, parts: [StationPart] = [], municipality: String? = nil, departureMode: String? = nil) {
		self.municipality = municipality
		self.departureMode = departureMode
		self.id = id
		self.name = name
		self.borough = borough
		self.routes = routes
		self.lat = lat
		self.lon = lon
		self.parts = parts
	}
}

public struct SourceState: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var timestamp: TimeInterval?
	public var fetchedAt: TimeInterval?
	public var error: String?

	public init(id: String, timestamp: TimeInterval? = nil, fetchedAt: TimeInterval? = nil, error: String? = nil) {
		self.id = id
		self.timestamp = timestamp
		self.fetchedAt = fetchedAt
		self.error = error
	}
}

public struct ChangeEvidence: Codable, Sendable, Equatable {
	public var source: String
	public var timestamp: TimeInterval
	public var staleAfter: TimeInterval
	public var unavailable: Bool?

	public init(source: String, timestamp: TimeInterval, staleAfter: TimeInterval, unavailable: Bool? = nil) {
		self.source = source
		self.timestamp = timestamp
		self.staleAfter = staleAfter
		self.unavailable = unavailable
	}
}

public struct TripChange: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var kind: String
	public var classification: String
	public var label: String
	public var description: String?
	public var location: String?
	public var stopIndices: [Int]
	public var affectedStops: [String]
	public var before: String?
	public var after: String?
	public var evidence: [ChangeEvidence]
	public var alertIds: [String]
	public var advisory: Bool?

	public init(id: String, kind: String, classification: String, label: String, description: String? = nil, location: String? = nil, stopIndices: [Int] = [], affectedStops: [String] = [], before: String? = nil, after: String? = nil, evidence: [ChangeEvidence] = [], alertIds: [String] = [], advisory: Bool? = nil) {
		self.id = id
		self.kind = kind
		self.classification = classification
		self.label = label
		self.description = description
		self.location = location
		self.stopIndices = stopIndices
		self.affectedStops = affectedStops
		self.before = before
		self.after = after
		self.evidence = evidence
		self.alertIds = alertIds
		self.advisory = advisory
	}
}

public struct StopPrediction: Codable, Sendable, Equatable {
	public var changes: [TripChange]?
	public var sequence: Int?
	public var id: String
	public var name: String
	public var stationId: String?
	public var arrival: TimeInterval?
	public var departure: TimeInterval?
	public var scheduledTrack: String?
	public var actualTrack: String?
	public var relationship: String?

	public init(changes: [TripChange]? = nil, sequence: Int? = nil, id: String, name: String, stationId: String? = nil, arrival: TimeInterval? = nil, departure: TimeInterval? = nil, scheduledTrack: String? = nil, actualTrack: String? = nil, relationship: String? = nil) {
		self.changes = changes
		self.sequence = sequence
		self.id = id
		self.name = name
		self.stationId = stationId
		self.arrival = arrival
		self.departure = departure
		self.scheduledTrack = scheduledTrack
		self.actualTrack = actualTrack
		self.relationship = relationship
	}
}

public struct ConsistCar: Codable, Sendable, Equatable {
	public var number: String
	public var type: String?

	public init(number: String, type: String? = nil) {
		self.number = number
		self.type = type
	}
}

public struct Consist: Codable, Sendable, Equatable {
	public var cars: [ConsistCar]
	public var updatedAt: TimeInterval
	public var fetchedAt: TimeInterval
	public var source: String

	public init(cars: [ConsistCar], updatedAt: TimeInterval, fetchedAt: TimeInterval, source: String = "helium") {
		self.cars = cars
		self.updatedAt = updatedAt
		self.fetchedAt = fetchedAt
		self.source = source
	}
}

public struct TrainPosition: Codable, Sendable, Equatable {
	public var stopId: String?
	public var name: String
	public var status: String?
	public var timestamp: TimeInterval?

	public init(stopId: String? = nil, name: String, status: String? = nil, timestamp: TimeInterval? = nil) {
		self.stopId = stopId
		self.name = name
		self.status = status
		self.timestamp = timestamp
	}
}

public struct ScheduledPattern: Codable, Sendable, Equatable {
	public var shape: String
	public var headsign: String
	public var stops: [String]
	public var source: String

	public init(shape: String, headsign: String, stops: [String], source: String) {
		self.shape = shape
		self.headsign = headsign
		self.stops = stops
		self.source = source
	}
}

public struct Train: Codable, Sendable, Equatable, Identifiable {
	public var changes: [TripChange]?
	public var startTime: String?
	public var key: String
	public var feed: String
	public var tripId: String
	public var serviceDate: String?
	public var route: String
	public var destination: String
	public var direction: String
	public var trainId: String?
	public var assigned: Bool?
	public var timestamp: TimeInterval
	public var position: TrainPosition?
	public var stops: [StopPrediction]
	public var relationship: String?
	public var alerts: [String]
	public var consist: Consist?
	public var scheduledPattern: ScheduledPattern?
	public var id: String { key }

	public init(changes: [TripChange]? = nil, startTime: String? = nil, key: String, feed: String, tripId: String, serviceDate: String? = nil, route: String, destination: String, direction: String, trainId: String? = nil, assigned: Bool? = nil, timestamp: TimeInterval, position: TrainPosition? = nil, stops: [StopPrediction] = [], relationship: String? = nil, alerts: [String] = [], consist: Consist? = nil, scheduledPattern: ScheduledPattern? = nil) {
		self.changes = changes
		self.startTime = startTime
		self.key = key
		self.feed = feed
		self.tripId = tripId
		self.serviceDate = serviceDate
		self.route = route
		self.destination = destination
		self.direction = direction
		self.trainId = trainId
		self.assigned = assigned
		self.timestamp = timestamp
		self.position = position
		self.stops = stops
		self.relationship = relationship
		self.alerts = alerts
		self.consist = consist
		self.scheduledPattern = scheduledPattern
	}
}

public struct OnwardStop: Codable, Sendable, Equatable {
	public var stationId: String
	public var stopId: String
	public var name: String
	public var time: TimeInterval?

	public init(stationId: String, stopId: String, name: String, time: TimeInterval? = nil) {
		self.stationId = stationId
		self.stopId = stopId
		self.name = name
		self.time = time
	}
}

public struct Departure: Codable, Sendable, Equatable, Identifiable {
	public var changes: [TripChange]?
	public var departure: TimeInterval?
	public var key: String
	public var tripKey: String
	public var route: String
	public var destination: String
	public var direction: String
	public var stopId: String
	public var partId: String
	public var area: String
	public var time: TimeInterval?
	public var arrival: TimeInterval?
	public var scheduledTrack: String?
	public var actualTrack: String?
	public var pattern: String
	public var patternSource: String
	public var location: String
	public var locationTimestamp: TimeInterval?
	public var stopsAway: Int?
	public var assigned: Bool?
	public var feed: String
	public var timestamp: TimeInterval
	public var relationship: String?
	public var alerts: [String]
	public var consist: Consist?
	public var onward: [OnwardStop]
	public var gap: Double?
	public var basis: String?
	public var id: String { key }

	public init(changes: [TripChange]? = nil, departure: TimeInterval? = nil, key: String, tripKey: String, route: String, destination: String, direction: String, stopId: String, partId: String, area: String, time: TimeInterval? = nil, arrival: TimeInterval? = nil, scheduledTrack: String? = nil, actualTrack: String? = nil, pattern: String, patternSource: String, location: String, locationTimestamp: TimeInterval? = nil, stopsAway: Int? = nil, assigned: Bool? = nil, feed: String, timestamp: TimeInterval, relationship: String? = nil, alerts: [String] = [], consist: Consist? = nil, onward: [OnwardStop] = [], gap: Double? = nil, basis: String? = nil) {
		self.changes = changes
		self.departure = departure
		self.key = key
		self.tripKey = tripKey
		self.route = route
		self.destination = destination
		self.direction = direction
		self.stopId = stopId
		self.partId = partId
		self.area = area
		self.time = time
		self.arrival = arrival
		self.scheduledTrack = scheduledTrack
		self.actualTrack = actualTrack
		self.pattern = pattern
		self.patternSource = patternSource
		self.location = location
		self.locationTimestamp = locationTimestamp
		self.stopsAway = stopsAway
		self.assigned = assigned
		self.feed = feed
		self.timestamp = timestamp
		self.relationship = relationship
		self.alerts = alerts
		self.consist = consist
		self.onward = onward
		self.gap = gap
		self.basis = basis
	}
}

public struct AlertSelector: Codable, Sendable, Equatable {
	public var route: String?
	public var stop: String?
	public var trip: String?
	public var direction: Int?
	public var serviceDate: String?
	public var startTime: String?
	public var priority: Int?

	public init(route: String? = nil, stop: String? = nil, trip: String? = nil, direction: Int? = nil, serviceDate: String? = nil, startTime: String? = nil, priority: Int? = nil) {
		self.route = route
		self.stop = stop
		self.trip = trip
		self.direction = direction
		self.serviceDate = serviceDate
		self.startTime = startTime
		self.priority = priority
	}
}

public struct AlertPeriod: Codable, Sendable, Equatable {
	public var start: TimeInterval?
	public var end: TimeInterval?

	public init(start: TimeInterval? = nil, end: TimeInterval? = nil) {
		self.start = start
		self.end = end
	}
}

public struct ServiceAlert: Codable, Sendable, Equatable, Identifiable {
	public var alertType: String?
	public var activePeriodLabel: String?
	public var planNumbers: [String]?
	public var affectedSelectors: [AlertSelector]?
	public var id: String
	public var title: String
	public var description: String
	public var effect: String?
	public var routes: [String]
	public var stops: [String]
	public var selectors: [AlertSelector]
	public var periods: [AlertPeriod]
	public var updatedAt: TimeInterval?
	public var raw: JSONValue?

	public init(alertType: String? = nil, activePeriodLabel: String? = nil, planNumbers: [String]? = nil, affectedSelectors: [AlertSelector]? = nil, id: String, title: String, description: String, effect: String? = nil, routes: [String] = [], stops: [String] = [], selectors: [AlertSelector] = [], periods: [AlertPeriod] = [], updatedAt: TimeInterval? = nil, raw: JSONValue? = nil) {
		self.alertType = alertType
		self.activePeriodLabel = activePeriodLabel
		self.planNumbers = planNumbers
		self.affectedSelectors = affectedSelectors
		self.id = id
		self.title = title
		self.description = description
		self.effect = effect
		self.routes = routes
		self.stops = stops
		self.selectors = selectors
		self.periods = periods
		self.updatedAt = updatedAt
		self.raw = raw
	}
}

public struct Board: Codable, Sendable, Equatable {
	public var station: Station
	public var generatedAt: TimeInterval
	public var sources: [SourceState]
	public var departures: [Departure]
	public var alerts: [ServiceAlert]

	public init(station: Station, generatedAt: TimeInterval, sources: [SourceState] = [], departures: [Departure] = [], alerts: [ServiceAlert] = []) {
		self.station = station
		self.generatedAt = generatedAt
		self.sources = sources
		self.departures = departures
		self.alerts = alerts
	}
}

public struct TripDetail: Codable, Sendable, Equatable {
	public var train: Train
	public var raw: JSONValue?
	public var source: TripSource?

	public init(train: Train, raw: JSONValue? = nil, source: TripSource? = nil) {
		self.train = train
		self.raw = raw
		self.source = source
	}
}

public struct TripSource: Codable, Sendable, Equatable {
	public var state: SourceState
	public var header: JSONValue?
	public init(state: SourceState, header: JSONValue? = nil) {
		self.state = state
		self.header = header
	}
}

public struct TransferResult: Codable, Sendable, Equatable {
	public var originTimestamp: TimeInterval?
	public var station: Station?
	public var arrival: TimeInterval?
	public var basis: String
	public var message: String?
	public var connections: [Departure]
	public var sources: [SourceState]

	public init(originTimestamp: TimeInterval? = nil, station: Station? = nil, arrival: TimeInterval? = nil, basis: String, message: String? = nil, connections: [Departure] = [], sources: [SourceState] = []) {
		self.originTimestamp = originTimestamp
		self.station = station
		self.arrival = arrival
		self.basis = basis
		self.message = message
		self.connections = connections
		self.sources = sources
	}
}

public struct StationContext: Codable, Sendable, Equatable {
	public var entrances: [[String:String]]
	public var equipment: [[String:String]]
	public var outages: [[String:String]]
	public var sources: [SourceState]

	public init(entrances: [[String:String]] = [], equipment: [[String:String]] = [], outages: [[String:String]] = [], sources: [SourceState] = []) {
		self.entrances = entrances
		self.equipment = equipment
		self.outages = outages
		self.sources = sources
	}
}

public struct Evidence: Codable, Sendable, Equatable {
	public var url: String
	public var date: String
	public var note: String

	public init(url: String, date: String, note: String) {
		self.url = url
		self.date = date
		self.note = note
	}
}

public struct YardEvidence: Codable, Sendable, Equatable {
	public var url: String
	public var date: String
	public var note: String
	public var name: String

	public init(url: String, date: String, note: String, name: String) {
		self.url = url
		self.date = date
		self.note = note
		self.name = name
	}
}

public struct FleetNextStop: Codable, Sendable, Equatable {
	public var stationId: String?
	public var name: String
	public var time: TimeInterval?

	public init(stationId: String? = nil, name: String, time: TimeInterval? = nil) {
		self.stationId = stationId
		self.name = name
		self.time = time
	}
}

public struct FleetObservation: Codable, Sendable, Equatable {
	public var timestamp: TimeInterval
	public var locationTimestamp: TimeInterval?
	public var location: String
	public var route: String
	public var tripKey: String
	public var consistId: String
	public var cars: [String]
	public var next: FleetNextStop?

	public init(timestamp: TimeInterval, locationTimestamp: TimeInterval? = nil, location: String, route: String, tripKey: String, consistId: String, cars: [String] = [], next: FleetNextStop? = nil) {
		self.timestamp = timestamp
		self.locationTimestamp = locationTimestamp
		self.location = location
		self.route = route
		self.tripKey = tripKey
		self.consistId = consistId
		self.cars = cars
		self.next = next
	}
}

public struct FleetCar: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var number: String
	public var equipment: String
	public var category: String
	public var aliases: [String]
	public var lifecycle: String
	public var evidence: [Evidence]
	public var conflicts: [String]?
	public var fixedSet: String?
	public var facts: [String:String]?
	public var yard: YardEvidence?
	public var last: FleetObservation?
	public var reporting: Bool?
	public var estimatedYard: YardEvidence?

	public init(id: String, number: String, equipment: String, category: String, aliases: [String] = [], lifecycle: String, evidence: [Evidence] = [], conflicts: [String]? = nil, fixedSet: String? = nil, facts: [String:String]? = nil, yard: YardEvidence? = nil, last: FleetObservation? = nil, reporting: Bool? = nil, estimatedYard: YardEvidence? = nil) {
		self.id = id
		self.number = number
		self.equipment = equipment
		self.category = category
		self.aliases = aliases
		self.lifecycle = lifecycle
		self.evidence = evidence
		self.conflicts = conflicts
		self.fixedSet = fixedSet
		self.facts = facts
		self.yard = yard
		self.last = last
		self.reporting = reporting
		self.estimatedYard = estimatedYard
	}
}

public struct FleetRow: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var kind: String
	public var cars: [FleetCar]
	public var reporting: Bool

	public init(id: String, kind: String, cars: [FleetCar] = [], reporting: Bool) {
		self.id = id
		self.kind = kind
		self.cars = cars
		self.reporting = reporting
	}
}

public struct FleetCoverage: Codable, Sendable, Equatable {
	public var category: String
	public var count: Int
	public var note: String

	public init(category: String, count: Int, note: String) {
		self.category = category
		self.count = count
		self.note = note
	}
}

public struct FleetFacets: Codable, Sendable, Equatable {
	public var equipment: [String]
	public var route: [String]
	public var yard: [String]

	public init(equipment: [String] = [], route: [String] = [], yard: [String] = []) {
		self.equipment = equipment
		self.route = route
		self.yard = yard
	}
}

public struct FleetPage: Codable, Sendable, Equatable {
	public var rows: [FleetRow]
	public var total: Int
	public var page: Int
	public var pages: Int
	public var generatedAt: TimeInterval
	public var coverage: [FleetCoverage]
	public var facets: FleetFacets
	public var sources: [Evidence]
	public var error: String?

	public init(rows: [FleetRow] = [], total: Int, page: Int, pages: Int, generatedAt: TimeInterval, coverage: [FleetCoverage] = [], facets: FleetFacets, sources: [Evidence] = [], error: String? = nil) {
		self.rows = rows
		self.total = total
		self.page = page
		self.pages = pages
		self.generatedAt = generatedAt
		self.coverage = coverage
		self.facets = facets
		self.sources = sources
		self.error = error
	}
}

public struct FleetDetail: Codable, Sendable, Equatable {
	public var cars: [FleetCar]
	public var history: [FleetObservation]
	public var generatedAt: TimeInterval

	public init(cars: [FleetCar] = [], history: [FleetObservation] = [], generatedAt: TimeInterval) {
		self.cars = cars
		self.history = history
		self.generatedAt = generatedAt
	}
}

public struct FleetOfflineCounts: Codable, Sendable, Equatable {
	public var cars: Int
	public var consists: Int
	public var events: Int
	public var assertions: Int

	public init(cars: Int, consists: Int, events: Int, assertions: Int) {
		self.cars = cars
		self.consists = consists
		self.events = events
		self.assertions = assertions
	}
}

public struct FleetOfflineManifest: Codable, Sendable, Equatable, Identifiable {
	public var schemaVersion: Int
	public var id: String
	public var generatedAt: TimeInterval
	public var historyStart: TimeInterval
	public var historyEnd: TimeInterval
	public var counts: FleetOfflineCounts
	public var byteLength: Int64
	public var sha256: String
	public var downloadURL: String
	public var observedAt: TimeInterval?
	public var compression: String?
	public var compressedByteLength: Int64?
	public var compressedSha256: String?
	public var downloadByteLength: Int64 { compression == "gzip" ? compressedByteLength ?? byteLength : byteLength }

	public init(schemaVersion: Int, id: String, generatedAt: TimeInterval, historyStart: TimeInterval, historyEnd: TimeInterval, counts: FleetOfflineCounts, byteLength: Int64, sha256: String, downloadURL: String, observedAt: TimeInterval? = nil, compression: String? = nil, compressedByteLength: Int64? = nil, compressedSha256: String? = nil) {
		self.schemaVersion = schemaVersion
		self.id = id
		self.generatedAt = generatedAt
		self.historyStart = historyStart
		self.historyEnd = historyEnd
		self.counts = counts
		self.byteLength = byteLength
		self.sha256 = sha256
		self.downloadURL = downloadURL
		self.observedAt = observedAt
		self.compression = compression
		self.compressedByteLength = compressedByteLength
		self.compressedSha256 = compressedSha256
	}
}
