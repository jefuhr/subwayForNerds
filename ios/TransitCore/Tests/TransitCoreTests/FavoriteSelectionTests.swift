import Foundation
import Testing
@testable import TransitCore

struct FavoriteSelectionTests {
	@Test func exactMembershipAndIndividualCarsHaveStableIdentities() {
		let consist = Consist(cars: [ConsistCar(number: "001", type: "R160A"), ConsistCar(number: "002", type: "R160B")], updatedAt: 1000, fetchedAt: 1000)
		#expect(TrainFavorites.carID(number: "001", type: "R160B", feed: "gtfs") == "nyct:R160:001")
		#expect(TrainFavorites.carID(number: "001", type: nil, feed: "gtfs") == nil)
		#expect(TrainFavorites.carID(number: "1:2", type: "R160", feed: "gtfs") == nil)
		for id in ["nyct:R160A:001", "nyct:R160:0\u{85}1", "nyct:R160:0\u{feff}1"] { #expect(!TrainFavorites.validCarID(id)) }
		var favorites = TrainFavorites()
		favorites.consists = [["nyct:R160:002", "nyct:R160:001"]]
		#expect(favorites.match(consist, feed: "gtfs", now: 1000)?.exactConsist == true)
		#expect(favorites.match(consist, feed: "gtfs-si", now: 1000) == nil)
		#expect(favorites.match(consist, feed: "gtfs", now: 1301) == nil)
		#expect(favorites.match(consist, feed: "gtfs", now: 1000, cached: true) == nil)
		let partial = Consist(cars: [ConsistCar(number: "001", type: "R160")], updatedAt: 1000, fetchedAt: 1000)
		#expect(favorites.match(partial, feed: "gtfs", now: 1000) == nil)
		favorites.match = .anyCar
		#expect(favorites.match(partial, feed: "gtfs", now: 1000)?.carIDs == ["nyct:R160:001"])
		#expect(favorites.consists.count == 1)
	}
	@Test func stationModesRadiusAndWidgetOverride() {
		let catalog = [station("favorite", lat: 0.01), station("closest", lat: 0.001)]
		let location = WidgetCoordinate(latitude: 0, longitude: 0, timestamp: 1000)
		var selection = StationSelection()
		#expect(selection.select(stations: catalog, favorites: ["favorite"], location: location, now: 1000)?.id == "favorite")
		selection.mode = .closest
		#expect(selection.select(stations: catalog, favorites: [], location: location, now: 1000)?.id == "closest")
		selection.mode = .nearbyFavorite
		#expect(selection.select(stations: catalog, favorites: ["favorite"], location: location, now: 1000)?.id == "favorite")
		selection.radiusFeet = 1
		#expect(selection.select(stations: catalog, favorites: ["favorite"], location: location, now: 1000)?.id == "closest")
		#expect(!selection.includesFavorite(distanceMeters: 0.3048))
		#expect(selection.includesFavorite(distanceMeters: 0.3047))
		var state = WidgetSharedState(favorites: ["favorite"], stations: catalog, stationSelection: selection)
		#expect(state.selectedStation(location: location, previous: nil, now: 1000)?.id == "closest")
		state.widgets.stationSelection.followApp = false
		#expect(state.selectedStation(location: location, previous: nil, now: 1000)?.id == "favorite")
	}
	@Test func unusableLocationPreservesValidSelectionAndPartsDetermineDistance() {
		var complex = station("complex", lat: 1)
		complex.parts = [StationPart(id: "part", stationId: "complex", name: "Part", line: "", routes: [], lat: 0.0001, lon: 0, ada: "", adaNotes: "", north: "", south: "")]
		let catalog = [station("closest", lat: 0.001), complex]
		let selection = StationSelection(mode: .closest, radiusFeet: 5280)
		let location = WidgetCoordinate(latitude: 0, longitude: 0, timestamp: 1000)
		#expect(selection.select(stations: catalog, favorites: [], location: location, now: 1000)?.id == "complex")
		for time in [700.0, 1001, .nan] {
			#expect(selection.select(stations: catalog, favorites: [], location: WidgetCoordinate(latitude: 0, longitude: 0, timestamp: time), previous: "closest", now: 1000)?.id == "closest")
		}
	}
	@Test func v1MigrationV2ValidationAndMembershipSync() throws {
		let old = try NerdsSettingsFile.decode(Data(contentsOf: Bundle.module.url(forResource: "settings", withExtension: "nerds", subdirectory: "Fixtures")!))
		#expect(old.settings.stationSelection == StationSelection())
		#expect(old.settings.trainFavorites == TrainFavorites())
		var base = PortableSettings(); base.trainFavorites.cars = ["nyct:R160:001"]
		var local = base; local.trainFavorites.cars = ["sir:R211S:100"]; local.stationSelection.radiusFeet = 1
		var remote = base; remote.trainFavorites.cars.append("nyct:R46:001"); remote.stationSelection.radiusFeet = 100
		let merged = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(Set(merged.settings.trainFavorites.cars) == ["nyct:R46:001", "sir:R211S:100"])
		#expect(merged.conflicts.map(\.path) == ["/stationSelection/radiusFeet"])
		let file = NerdsSettingsFile(settings: local, lastStation: "602")
		#expect(try NerdsSettingsFile.decode(file.data()).version == 2)
		#expect(try NerdsSettingsFile.decode(file.data()).settings == local)
		local.stationSelection.radiusFeet = 0
		#expect(throws: (any Error).self) { try local.validated() }
		local = base; local.trainFavorites.consists = [["nyct:R160:001", "nyct:R160:001"]]
		#expect(throws: (any Error).self) { try local.validated() }
	}
	@Test func sharedV2FixtureRoundTripsAllNewPreferences() throws {
		let file = try NerdsSettingsFile.decode(Data(contentsOf: Bundle.module.url(forResource: "favorites", withExtension: "nerds", subdirectory: "Fixtures")!))
		#expect(file.version == 2)
		#expect(file.settings.stationSelection.radiusFeet == 1)
		#expect(file.settings.widgets.stationSelection.selection.radiusFeet == 26400)
		#expect(!file.settings.widgets.stationSelection.followApp)
		#expect(file.settings.trainFavorites.match == .anyCar)
		#expect(file.settings.trainFavorites.cars == ["nyct:R211A:4149", "sir:R211S:100"])
		#expect(try NerdsSettingsFile.decode(file.data()).settings == file.settings)
	}
	private func station(_ id: String, lat: Double) -> Station {
		Station(id: id, name: id, borough: "", routes: [], lat: lat, lon: 0, parts: [])
	}
}
