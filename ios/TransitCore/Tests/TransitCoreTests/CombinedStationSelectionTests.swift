import Foundation
import Testing
@testable import TransitCore

struct CombinedStationSelectionTests {
	private let now: TimeInterval = 1000
	private let firstGroupID = "combined:00000000-0000-0000-0000-000000000001"
	private let secondGroupID = "combined:00000000-0000-0000-0000-000000000002"

	@Test func closestPrefersCombinedStationOverItsEquidistantRealMember() {
		let member = fulton()
		let other = cortlandt()
		let group = combined(firstGroupID, members: [member, other])
		let location = coordinate(at: member.parts[0])
		let selection = StationSelection(mode: .closest)
		#expect(location.distanceMeters(to: group) == location.distanceMeters(to: member))

		for catalog in [[member, other, group], [group, other, member], [other, member, group]] {
			#expect(selection.select(stations: catalog, favorites: [], location: location, previous: member.id, now: now)?.id == group.id)
		}
	}

	@Test func equidistantCombinedStationsRetainThePreviousGroup() {
		let member = fulton()
		let first = combined(firstGroupID, members: [member, cortlandt()])
		let second = combined(secondGroupID, members: [member, cortlandt()])
		let location = coordinate(at: member.parts[0])
		let selection = StationSelection(mode: .closest)

		for catalog in [[member, first, second], [second, member, first], [first, second, member]] {
			for previous in [first.id, second.id] {
				#expect(selection.select(stations: catalog, favorites: [], location: location, previous: previous, now: now)?.id == previous)
			}
		}
	}

	@Test func equidistantGroupsUseStableIDWhenPreviousIsNotAnEligibleGroup() {
		let member = fulton()
		let first = combined(firstGroupID, members: [member, cortlandt()])
		let second = combined(secondGroupID, members: [member, cortlandt()])
		let location = coordinate(at: member.parts[0])
		let selection = StationSelection(mode: .closest)
		let previousIDs: [String?] = [nil, member.id, "combined:00000000-0000-0000-0000-000000000099"]

		for catalog in [[second, first, member], [member, second, first]] {
			for previous in previousIDs {
				#expect(selection.select(stations: catalog, favorites: [], location: location, previous: previous, now: now)?.id == first.id)
			}
		}
	}

	@Test func strictlyCloserRealStationBeatsAPreviouslySelectedGroup() {
		let member = fulton()
		let group = combined(firstGroupID, members: [member, wtcComplex()])
		let nearest = cortlandt()
		let location = coordinate(at: nearest.parts[0])
		let selection = StationSelection(mode: .closest)
		#expect(location.distanceMeters(to: nearest) < location.distanceMeters(to: group))
		#expect(selection.select(stations: [group, member, nearest], favorites: [group.id], location: location, previous: group.id, now: now)?.id == nearest.id)
	}

	@Test func favoriteModeHonorsExplicitFavoritesWithoutInheritingMemberFavorites() {
		let member = fulton()
		let fartherFavorite = cortlandt()
		let group = combined(firstGroupID, members: [member, fartherFavorite])
		let catalog = [group, member, fartherFavorite]
		let location = coordinate(at: member.parts[0])
		let selection = StationSelection(mode: .favorite)

		#expect(selection.select(stations: catalog, favorites: [fartherFavorite.id], location: location, previous: group.id, now: now)?.id == fartherFavorite.id)
		#expect(selection.select(stations: catalog, favorites: [member.id], location: location, previous: group.id, now: now)?.id == member.id)
		#expect(selection.select(stations: catalog, favorites: [group.id, fartherFavorite.id], location: location, previous: member.id, now: now)?.id == group.id)
		#expect(selection.select(stations: catalog, favorites: [], location: location, previous: group.id, now: now) == nil)
	}

	@Test func nearbyFavoriteKeepsEligibleRealFavoritesAndPrefersGroupsOnClosestFallback() {
		let member = fulton()
		let fartherFavorite = cortlandt()
		let group = combined(firstGroupID, members: [member, fartherFavorite])
		let catalog = [member, fartherFavorite, group]
		let location = coordinate(at: member.parts[0])
		let selection = StationSelection(mode: .nearbyFavorite, radiusFeet: 1)

		#expect(selection.select(stations: catalog, favorites: [member.id], location: location, previous: group.id, now: now)?.id == member.id)
		#expect(selection.select(stations: catalog, favorites: [fartherFavorite.id], location: location, previous: fartherFavorite.id, now: now)?.id == group.id)
		#expect(selection.select(stations: catalog, favorites: [], location: location, previous: member.id, now: now)?.id == group.id)
	}

	@Test func closestUsesTheNearestMemberPartInsteadOfTheCombinedCentroid() {
		let member = fulton()
		let group = combined(firstGroupID, members: [member, cortlandt(), pathWTC()])
		let competitor = wtcComplex()
		let location = coordinate(at: member.parts[1])
		var centroidOnly = group
		centroidOnly.parts = []
		// A centroid-based implementation would incorrectly select the WTC complex.
		#expect(location.distanceMeters(to: group) == 0)
		#expect(location.distanceMeters(to: competitor) < location.distanceMeters(to: centroidOnly))
		#expect(StationSelection(mode: .closest).select(stations: [competitor, group], favorites: [], location: location, previous: competitor.id, now: now)?.id == group.id)
	}

	private func coordinate(at part: StationPart) -> WidgetCoordinate {
		WidgetCoordinate(latitude: part.lat, longitude: part.lon, timestamp: now)
	}

	private func combined(_ id: String, members: [Station]) -> Station {
		Station(id: id, name: "Downtown connection", borough: "M",
			routes: Array(Set(members.flatMap(\.routes))).sorted(),
			lat: members.map(\.lat).reduce(0, +) / Double(members.count),
			lon: members.map(\.lon).reduce(0, +) / Double(members.count),
			parts: members.flatMap(\.parts))
	}

	private func fulton() -> Station {
		Station(id: "628", name: "Fulton St", borough: "M", routes: ["2", "3", "4", "5", "A", "C", "J", "Z"], lat: 40.710374, lon: -74.007582, parts: [
			StationPart(id: "M22", stationId: "106", name: "Fulton St", line: "Jamaica", routes: ["J", "Z"], lat: 40.710374, lon: -74.007582, ada: "1", north: "Brooklyn", south: "Downtown"),
			StationPart(id: "418", stationId: "412", name: "Fulton St", line: "Lexington Av", routes: ["4", "5"], lat: 40.710368, lon: -74.009509, ada: "1", north: "Uptown", south: "Downtown")
		])
	}

	private func cortlandt() -> Station {
		Station(id: "328", name: "WTC Cortlandt", borough: "M", routes: ["1"], lat: 40.711835, lon: -74.012188, parts: [
			StationPart(id: "138", stationId: "328", name: "WTC Cortlandt", line: "Broadway - 7Av", routes: ["1"], lat: 40.711835, lon: -74.012188, ada: "1", north: "Uptown", south: "Downtown")
		])
	}

	private func wtcComplex() -> Station {
		Station(id: "624", name: "Cortlandt St / Chambers St / World Trade Center / Park Place", borough: "M", routes: ["2", "3", "A", "C", "E", "R", "W"], lat: 40.710668, lon: -74.011029, parts: [
			StationPart(id: "R25", stationId: "21", name: "Cortlandt St", line: "Broadway", routes: ["R", "W"], lat: 40.710668, lon: -74.011029, ada: "1", north: "Uptown", south: "Downtown"),
			StationPart(id: "E01", stationId: "171", name: "World Trade Center", line: "8th Av - Fulton St", routes: ["E"], lat: 40.712582, lon: -74.009781, ada: "1", north: "Uptown", south: "Last Stop")
		])
	}

	private func pathWTC() -> Station {
		Station(id: "path-wtc", name: "World Trade Center (PATH)", borough: "M", routes: ["PATH-NWK-WTC", "PATH-HOB-WTC"], lat: 40.71224, lon: -74.012522, parts: [
			StationPart(id: "path-wtc", stationId: "path-wtc", name: "World Trade Center (PATH)", line: "PATH", routes: ["PATH-NWK-WTC", "PATH-HOB-WTC"], lat: 40.71224, lon: -74.012522, ada: "", north: "To New York", south: "To New Jersey")
		])
	}
}
