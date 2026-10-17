import Foundation
import Testing
@testable import TransitCore

struct DeviceNetworkStatusTests {
	typealias Status = DeviceNetworkStatus

	private func path(_ status: Status.PathStatus, _ transports: [Status.Transport] = [], reason: Status.PathReason? = nil, name: String? = nil, radio: String? = nil, expensive: Bool = false, constrained: Bool = false, ipv4: Bool = true, ipv6: Bool = false, dns: Bool = true, simulated: Bool = false, reconnecting: Bool = false) -> Status {
		Status(path: status, transports: transports, reason: reason, networkName: name, radioTechnology: radio, isExpensive: expensive, isConstrained: constrained, supportsIPv4: ipv4, supportsIPv6: ipv6, supportsDNS: dns, simulatedOutage: simulated, reconnecting: reconnecting)
	}

	@Test func pathsAreClassifiedByStatusAndCandidateInterfaces() {
		#expect(path(.satisfied, [.wifi]).state == .connected)
		#expect(path(.satisfied, [.wifi], reconnecting: true).state == .connecting)
		#expect(path(.requiresConnection, [.cellular]).state == .connecting)
		#expect(path(.requiresConnection).state == .searching)
		#expect(path(.unsatisfied, [.wifi]).state == .searching)
		#expect(path(.unsatisfied, reason: .notAvailable).state == .offline)
		#expect(path(.unsatisfied, reason: .cellularDenied).state == .offline)
		// Loopback never carries the feed, so it is not a candidate network.
		#expect(path(.unsatisfied, [.loopback], reason: .notAvailable).state == .offline)
		// A simulated outage wins over whatever the real path reports.
		#expect(path(.satisfied, [.wifi], simulated: true).state == .simulatedOutage)
		#expect(path(.unsatisfied, simulated: true).state == .simulatedOutage)
	}

	@Test func pathSnapshotsKeepInterfaceOrderWithoutDuplicatesAndLabelReasons() {
		let status = path(.satisfied, [.wifi, .cellular, .wifi], reason: .cellularDenied)
		#expect(status.transports == [.wifi, .cellular])
		#expect(status.unsatisfiedReason == "cellular data off")
		#expect(path(.unsatisfied, reason: .notAvailable).unsatisfiedReason == nil)
		#expect(Status.PathReason.wifiDenied.label == "Wi-Fi access off for this app")
		#expect(Status.PathReason.localNetworkDenied.label == "local network access denied")
		#expect(Status.PathReason.vpnInactive.label == "VPN not connected")
	}

	@Test func headlinesSayWhatThePhoneIsDoing() {
		#expect(path(.unsatisfied, simulated: true).headline == "Simulated outage · network requests paused")
		#expect(path(.requiresConnection).headline == "Searching for network…")
		#expect(path(.unsatisfied, [.wifi, .cellular]).headline == "Searching for Wi-Fi or cellular network…")
		#expect(path(.unsatisfied, [.wifi, .cellular, .wiredEthernet]).headline == "Searching for Wi-Fi, cellular or Ethernet network…")
		#expect(path(.requiresConnection, reason: .cellularDenied).headline == "Searching for network · cellular data off")
		#expect(path(.requiresConnection, [.wifi]).headline == "Connecting to Wi-Fi…")
		#expect(path(.requiresConnection, [.wifi], name: "MTA-WiFi").headline == "Connecting to Wi-Fi (MTA-WiFi)…")
		#expect(path(.requiresConnection, [.cellular]).headline == "Connecting to cellular network…")
		#expect(path(.satisfied, [.cellular], radio: "LTE", reconnecting: true).headline == "Connecting to cellular network (LTE)…")
		#expect(path(.requiresConnection, [.loopback]).headline == "Searching for network…")
		#expect(path(.unsatisfied, reason: .notAvailable).headline == "Offline · no network available")
		#expect(path(.unsatisfied, reason: .cellularDenied).headline == "Offline · cellular data off")
		#expect(path(.satisfied, [.wifi]).headline == "Connected via Wi-Fi")
		#expect(path(.satisfied, [.wifi], name: "NYCSubway").headline == "Connected via Wi-Fi (NYCSubway)")
		#expect(path(.satisfied, [.cellular]).headline == "Connected via Cellular")
		#expect(path(.satisfied, [.cellular], radio: "5G").headline == "Connected via Cellular (5G)")
		#expect(path(.satisfied, [.wiredEthernet]).headline == "Connected via Ethernet")
		#expect(path(.satisfied, [.other]).headline == "Connected via VPN or other network")
		#expect(path(.satisfied).headline == "Connected")
		#expect(Status(state: .connecting).headline == "Connecting to network…")
	}

	@Test func summariesReadInsideNoConnectionMessages() {
		#expect(path(.unsatisfied, [.wifi, .cellular]).activitySummary == "searching for Wi-Fi or cellular network")
		#expect(path(.requiresConnection, reason: .cellularDenied).activitySummary == "searching for network (cellular data off)")
		#expect(path(.unsatisfied, reason: .notAvailable).activitySummary == "no network available")
		#expect(path(.unsatisfied, reason: .wifiDenied).activitySummary == "Wi-Fi access off for this app")
		#expect(path(.requiresConnection, [.wifi]).activitySummary == "connecting to Wi-Fi")
		#expect(path(.satisfied, [.wifi]).activitySummary == "connected via Wi-Fi")
		#expect(path(.satisfied, simulated: true).activitySummary == "simulated outage, network requests paused")
		#expect(path(.unsatisfied, [.wifi, .cellular]).shortActivity == "searching")
		#expect(path(.unsatisfied, reason: .notAvailable).shortActivity == "no network")
		#expect(path(.unsatisfied, reason: .cellularDenied).shortActivity == "cellular data off")
		#expect(path(.requiresConnection, [.cellular], radio: "LTE").shortActivity == "connecting to cellular network (LTE)")
		#expect(path(.satisfied, simulated: true).shortActivity == "simulated outage")
	}

	@Test func detailLinesExplainConstraintsAndWhatTheAppIsWaitingFor() {
		let offline = path(.unsatisfied, reason: .notAvailable)
		#expect(offline.detailLine(waitingTargets: 3, inFlightTargets: 0, endpointHost: "juliet.nyc") == "Waiting for a connection to refresh departures (3 queued)")
		#expect(offline.detailLine(waitingTargets: 0, inFlightTargets: 0, endpointHost: nil) == "Automatic refreshes paused until a network is available")
		// IP and DNS readiness only matter once a path exists.
		let searching = path(.unsatisfied, [.wifi, .cellular], dns: false)
		#expect(searching.detailLine(waitingTargets: 1, inFlightTargets: 0, endpointHost: nil) == "Available: Wi-Fi, Cellular · Waiting for a connection to refresh departures (1 queued)")
		let hotspot = path(.satisfied, [.wifi], expensive: true, constrained: true, ipv4: true, ipv6: true)
		#expect(hotspot.detailLine(waitingTargets: 2, inFlightTargets: 1, endpointHost: "juliet.nyc") == "Low Data Mode · Cellular / hotspot data · IPv4 + IPv6, DNS ready · Requesting live updates from juliet.nyc (1 in flight)")
		let noDNS = path(.satisfied, [.cellular], radio: "5G", ipv4: false, ipv6: true, dns: false)
		#expect(noDNS.detailLine(waitingTargets: 4, inFlightTargets: 0, endpointHost: nil) == "IPv6, no DNS · Automatic refreshes active (4 scheduled)")
		let noRoute = path(.requiresConnection, [.wifi], ipv4: false, dns: false)
		#expect(noRoute.detailLine(waitingTargets: 0, inFlightTargets: 2, endpointHost: nil) == "No IP route, no DNS · Requesting live updates from the server (2 in flight)")
		// The simulated outage ignores the real path entirely.
		let simulated = path(.satisfied, [.wifi, .cellular], constrained: true, simulated: true)
		#expect(simulated.detailLine(waitingTargets: 2, inFlightTargets: 0, endpointHost: nil) == "Waiting for a connection to refresh departures (2 queued)")
		#expect(simulated.pathDetails.isEmpty)
	}

	@Test func syncLinesCountTrackedBoardsAndTrains() {
		let offline = path(.unsatisfied, reason: .notAvailable)
		#expect(offline.syncLine(trackedBoards: 1, trackedTrips: 0, inFlight: 0) == "Automatic refreshes paused until a network is available · tracking 1 board")
		#expect(offline.syncLine(trackedBoards: 0, trackedTrips: 0, inFlight: 0) == "Automatic refreshes paused until a network is available")
		let online = path(.satisfied, [.wifi])
		#expect(online.syncLine(trackedBoards: 3, trackedTrips: 1, inFlight: 2) == "Automatic refreshes active · tracking 3 boards, 1 train · 2 downloading")
		#expect(online.syncLine(trackedBoards: 0, trackedTrips: 4, inFlight: 0) == "Automatic refreshes active · tracking 4 trains")
	}

	@Test func radioTechnologiesMapToGenerations() {
		#expect(Status.radioLabel("CTRadioAccessTechnologyNR") == "5G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyNRNSA") == "5G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyLTE") == "LTE")
		#expect(Status.radioLabel("CTRadioAccessTechnologyWCDMA") == "3G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyHSDPA") == "3G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyeHRPD") == "3G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyEdge") == "2G")
		#expect(Status.radioLabel("CTRadioAccessTechnologyCDMA1x") == "2G")
		#expect(Status.radioLabel("CTRadioAccessTechnologySomethingNew") == nil)
		#expect(Status.radioLabel(nil) == nil)
	}

	@Test func accessibilityNamesTheDeviceNetwork() {
		let status = path(.unsatisfied, [.wifi])
		#expect(status.accessibilityLabel == "Device network: Searching for Wi-Fi network…")
		#expect(Status.accessibilityIdentifier == "deviceNetworkStatus")
		#expect(path(.satisfied, [.cellular]).isOnline && path(.satisfied, [.cellular], reconnecting: true).isOnline)
		#expect(!status.isOnline && !path(.satisfied, simulated: true).isOnline)
		for state in [path(.satisfied, [.wifi]), path(.satisfied, [.cellular]), path(.requiresConnection, [.wifi]), status, path(.unsatisfied), path(.satisfied, simulated: true)] {
			#expect(!state.symbolName.isEmpty)
		}
	}
}
