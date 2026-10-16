import Foundation

/// What the phone's network stack is doing, so offline screens can say why the
/// app has no connection instead of only that it has none. Built from a network
/// path snapshot without importing Network, so every rule here is testable.
public struct DeviceNetworkStatus: Sendable, Equatable {
	public enum State: Sendable, Equatable {
		case connected
		/// A path exists but still needs a connection, or the app is recovering after one returned.
		case connecting
		/// Interfaces exist but none can reach the network yet.
		case searching
		/// No usable interface: airplane mode, radios off, or access denied.
		case offline
		/// DEBUG outage simulation; the real path is ignored.
		case simulatedOutage
	}

	public enum Transport: Sendable, Equatable, Hashable {
		case wifi, cellular, wiredEthernet, loopback, other
	}

	/// Mirrors `NWPath.Status`.
	public enum PathStatus: Sendable, Equatable {
		case satisfied, requiresConnection, unsatisfied
	}

	/// Mirrors `NWPath.UnsatisfiedReason`.
	public enum PathReason: Sendable, Equatable {
		case notAvailable, cellularDenied, wifiDenied, localNetworkDenied, vpnInactive
		/// Nil when the path only reports that no network is available.
		public var label: String? {
			switch self {
			case .notAvailable: nil
			case .cellularDenied: "cellular data off"
			case .wifiDenied: "Wi-Fi access off for this app"
			case .localNetworkDenied: "local network access denied"
			case .vpnInactive: "VPN not connected"
			}
		}
	}

	public static let accessibilityIdentifier = "deviceNetworkStatus"

	public var state: State
	/// Available interfaces in the system's preference order, without duplicates.
	public var transports: [Transport]
	/// The joined Wi-Fi network's name, when the system shares it.
	public var networkName: String?
	/// The cellular generation, such as "5G" or "LTE", when known.
	public var radioTechnology: String?
	public var unsatisfiedReason: String?
	/// Cellular or personal hotspot data.
	public var isExpensive: Bool
	/// Low Data Mode.
	public var isConstrained: Bool
	public var supportsIPv4: Bool
	public var supportsIPv6: Bool
	public var supportsDNS: Bool

	public init(state: State, transports: [Transport] = [], networkName: String? = nil, radioTechnology: String? = nil, unsatisfiedReason: String? = nil, isExpensive: Bool = false, isConstrained: Bool = false, supportsIPv4: Bool = false, supportsIPv6: Bool = false, supportsDNS: Bool = false) {
		self.state = state
		self.transports = transports
		self.networkName = networkName
		self.radioTechnology = radioTechnology
		self.unsatisfiedReason = unsatisfiedReason
		self.isExpensive = isExpensive
		self.isConstrained = isConstrained
		self.supportsIPv4 = supportsIPv4
		self.supportsIPv6 = supportsIPv6
		self.supportsDNS = supportsDNS
	}

	/// Classifies one path snapshot. `reconnecting` is true while the app's first
	/// refresh after the path returned is still running.
	public init(path status: PathStatus, transports: [Transport], reason: PathReason?, networkName: String? = nil, radioTechnology: String? = nil, isExpensive: Bool, isConstrained: Bool, supportsIPv4: Bool, supportsIPv6: Bool, supportsDNS: Bool, simulatedOutage: Bool = false, reconnecting: Bool = false) {
		var unique: [Transport] = []
		for transport in transports where !unique.contains(transport) { unique.append(transport) }
		// Loopback never carries the feed, so it does not count as a network to join.
		let candidates = unique.contains { $0 != .loopback }
		let state: State = if simulatedOutage { .simulatedOutage }
			else {
				switch status {
				case .satisfied: reconnecting ? .connecting : .connected
				case .requiresConnection: candidates ? .connecting : .searching
				case .unsatisfied: candidates ? .searching : .offline
				}
			}
		self.init(state: state, transports: unique, networkName: networkName, radioTechnology: radioTechnology, unsatisfiedReason: reason?.label, isExpensive: isExpensive, isConstrained: isConstrained, supportsIPv4: supportsIPv4, supportsIPv6: supportsIPv6, supportsDNS: supportsDNS)
	}

	/// Connected, or connected and still finishing the first refresh.
	public var isOnline: Bool { state == .connected || state == .connecting }

	private var candidates: [Transport] { transports.filter { $0 != .loopback } }
	private var primary: Transport? { candidates.first }

	/// "Wi-Fi (NYCSubway)", "Cellular (5G)", "Ethernet".
	public func label(for transport: Transport) -> String {
		switch transport {
		case .wifi: "Wi-Fi" + (networkName.map { " (\($0))" } ?? "")
		case .cellular: "Cellular" + (radioTechnology.map { " (\($0))" } ?? "")
		case .wiredEthernet: "Ethernet"
		case .loopback: "Loopback"
		case .other: "VPN or other network"
		}
	}

	private func joinTarget(_ transport: Transport?) -> String {
		switch transport {
		case .wifi?: label(for: .wifi)
		case .cellular?: "cellular network" + (radioTechnology.map { " (\($0))" } ?? "")
		case .wiredEthernet?: "Ethernet"
		case .other?: "VPN or other network"
		case .loopback?, nil: "network"
		}
	}

	/// "Wi-Fi or cellular network", or "network" when no interface is a candidate.
	private var searchTarget: String {
		let names = candidates.map { transport in
			switch transport {
			case .wifi: "Wi-Fi"
			case .cellular: "cellular"
			case .wiredEthernet: "Ethernet"
			case .loopback, .other: "other"
			}
		}
		guard let last = names.last else { return "network" }
		return (names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last) + " network"
	}

	/// What the phone is doing right now, in one line.
	public var headline: String {
		switch state {
		case .simulatedOutage: "Simulated outage · network requests paused"
		case .searching: "Searching for \(searchTarget)" + (unsatisfiedReason.map { " · \($0)" } ?? "…")
		case .connecting: "Connecting to \(joinTarget(primary))…"
		case .offline: "Offline · \(unsatisfiedReason ?? "no network available")"
		case .connected: primary.map { "Connected via \(label(for: $0))" } ?? "Connected"
		}
	}

	/// The headline as a phrase for "No connection · …" messages.
	public var activitySummary: String {
		switch state {
		case .simulatedOutage: "simulated outage, network requests paused"
		case .searching: "searching for \(searchTarget)" + (unsatisfiedReason.map { " (\($0))" } ?? "")
		case .connecting: "connecting to \(joinTarget(primary))"
		case .offline: unsatisfiedReason ?? "no network available"
		case .connected: primary.map { "connected via \(label(for: $0))" } ?? "connected"
		}
	}

	/// A few words for loading bars: "searching", "no network", "connecting to Wi-Fi".
	public var shortActivity: String {
		switch state {
		case .simulatedOutage: "simulated outage"
		case .searching: "searching"
		case .connecting, .connected: activitySummary
		case .offline: unsatisfiedReason ?? "no network"
		}
	}

	/// Interfaces, Low Data Mode, metered data and, once a path exists, IP and DNS readiness.
	public var pathDetails: [String] {
		guard state != .simulatedOutage else { return [] }
		var parts: [String] = []
		if candidates.count > 1 { parts.append("Available: " + candidates.map(label(for:)).joined(separator: ", ")) }
		if isConstrained { parts.append("Low Data Mode") }
		if isExpensive { parts.append("Cellular / hotspot data") }
		if isOnline {
			let ip = switch (supportsIPv4, supportsIPv6) {
			case (true, true): "IPv4 + IPv6"
			case (true, false): "IPv4"
			case (false, true): "IPv6"
			case (false, false): "No IP route"
			}
			parts.append(ip + (supportsDNS ? ", DNS ready" : ", no DNS"))
		}
		return parts
	}

	/// What the app is doing with this connection, or waiting for without one.
	public func activity(waitingTargets: Int, inFlightTargets: Int, endpointHost: String?) -> String {
		if isOnline {
			if inFlightTargets > 0 { return "Requesting live updates from \(endpointHost ?? "the server") (\(inFlightTargets) in flight)" }
			return waitingTargets > 0 ? "Automatic refreshes active (\(waitingTargets) scheduled)" : "Automatic refreshes active"
		}
		return waitingTargets > 0 ? "Waiting for a connection to refresh departures (\(waitingTargets) queued)" : "Automatic refreshes paused until a network is available"
	}

	/// Path details followed by the app's activity.
	public func detailLine(waitingTargets: Int, inFlightTargets: Int, endpointHost: String?) -> String {
		(pathDetails + [activity(waitingTargets: waitingTargets, inFlightTargets: inFlightTargets, endpointHost: endpointHost)]).joined(separator: " · ")
	}

	/// Whether automatic refreshes run, and how many boards and trains they cover.
	public func syncLine(trackedBoards: Int, trackedTrips: Int, inFlight: Int) -> String {
		var parts = [isOnline ? "Automatic refreshes active" : "Automatic refreshes paused until a network is available"]
		let tracked = [Self.count(trackedBoards, "board"), Self.count(trackedTrips, "train")].compactMap { $0 }
		if !tracked.isEmpty { parts.append("tracking " + tracked.joined(separator: ", ")) }
		if isOnline, inFlight > 0 { parts.append("\(inFlight) downloading") }
		return parts.joined(separator: " · ")
	}

	public var accessibilityLabel: String { "Device network: \(headline)" }

	public var symbolName: String {
		switch state {
		case .simulatedOutage: "bolt.horizontal.circle"
		case .searching: "wifi.exclamationmark"
		case .offline: "wifi.slash"
		case .connecting: "arrow.triangle.2.circlepath"
		case .connected:
			switch primary {
			case .cellular?: "antenna.radiowaves.left.and.right"
			case .wiredEthernet?: "cable.connector"
			case .wifi?: "wifi"
			default: "network"
			}
		}
	}

	/// Maps a `CTRadioAccessTechnology` value to its generation; nil when unknown.
	public static func radioLabel(_ technology: String?) -> String? {
		guard let technology else { return nil }
		let name = technology.hasPrefix("CTRadioAccessTechnology") ? String(technology.dropFirst("CTRadioAccessTechnology".count)) : technology
		switch name {
		case "NR", "NRNSA": return "5G"
		case "LTE": return "LTE"
		case "WCDMA", "HSDPA", "HSUPA", "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB", "eHRPD": return "3G"
		case "GPRS", "Edge", "CDMA1x": return "2G"
		default: return nil
		}
	}

	private static func count(_ value: Int, _ noun: String) -> String? {
		value > 0 ? "\(value) \(noun)\(value == 1 ? "" : "s")" : nil
	}
}
