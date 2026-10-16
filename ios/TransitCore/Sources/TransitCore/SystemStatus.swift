import Darwin
import Foundation

/// Where the app's bytes live on the device. Every value is logical file size,
/// so totals match what the offline store reports for its own entries.
public struct AppStorageBreakdown: Sendable, Equatable {
	public enum Category: String, Sendable, Equatable, CaseIterable, Identifiable {
		case appBundle, settings, cache, fleet
		public var id: String { rawValue }
		public var title: String {
			switch self {
			case .appBundle: "App bundle"
			case .settings: "Settings"
			case .cache: "Cache"
			case .fleet: "Downloaded fleet"
			}
		}
	}

	/// The installed `.app`, including extensions and frameworks inside it.
	public var appBundleBytes: Int64
	/// Settings, preferences, and widget choices.
	public var settingsBytes: Int64
	/// Offline boards and trips.
	public var transitCacheBytes: Int64
	/// The saved station catalog.
	public var catalogBytes: Int64
	/// Boards and state shared with widgets.
	public var widgetCacheBytes: Int64
	/// URLCache's on-disk HTTP responses.
	public var urlCacheBytes: Int64
	/// The saved fleet pack.
	public var fleetBytes: Int64
	public var deviceFreeBytes: Int64?
	public var deviceTotalBytes: Int64?

	public init(appBundleBytes: Int64 = 0, settingsBytes: Int64 = 0, transitCacheBytes: Int64 = 0, catalogBytes: Int64 = 0, widgetCacheBytes: Int64 = 0, urlCacheBytes: Int64 = 0, fleetBytes: Int64 = 0, deviceFreeBytes: Int64? = nil, deviceTotalBytes: Int64? = nil) {
		self.appBundleBytes = appBundleBytes
		self.settingsBytes = settingsBytes
		self.transitCacheBytes = transitCacheBytes
		self.catalogBytes = catalogBytes
		self.widgetCacheBytes = widgetCacheBytes
		self.urlCacheBytes = urlCacheBytes
		self.fleetBytes = fleetBytes
		self.deviceFreeBytes = deviceFreeBytes
		self.deviceTotalBytes = deviceTotalBytes
	}

	public var cacheBytes: Int64 { transitCacheBytes + catalogBytes + widgetCacheBytes + urlCacheBytes }
	/// Everything the app wrote after installation.
	public var userDataBytes: Int64 { settingsBytes + cacheBytes + fleetBytes }
	public var totalAppBytes: Int64 { appBundleBytes + userDataBytes }

	public func bytes(_ category: Category) -> Int64 {
		switch category {
		case .appBundle: appBundleBytes
		case .settings: settingsBytes
		case .cache: cacheBytes
		case .fleet: fleetBytes
		}
	}

	/// The category's share of the app's total, in `0...1`; 0 before anything is measured.
	public func fraction(_ category: Category) -> Double {
		Self.share(bytes(category), of: Category.allCases.reduce(0) { $0 + max(0, bytes($1)) })
	}

	/// The app's share of the device volume, in `0...1`; nil when the volume size is unknown.
	public var deviceShare: Double? {
		guard let deviceTotalBytes, deviceTotalBytes > 0 else { return nil }
		return Self.share(totalAppBytes, of: deviceTotalBytes)
	}

	private static func share(_ part: Int64, of whole: Int64) -> Double {
		guard whole > 0 else { return 0 }
		return min(1, max(0, Double(part) / Double(whole)))
	}
}

/// The app's memory use against the device's installed memory.
public struct AppMemoryStatus: Sendable, Equatable {
	/// What the system charges the app for, the number jetsam limits apply to.
	public var appFootprintBytes: UInt64
	public var devicePhysicalMemoryBytes: UInt64
	/// URLCache's in-memory responses.
	public var urlCacheMemoryBytes: Int64

	public init(appFootprintBytes: UInt64, devicePhysicalMemoryBytes: UInt64, urlCacheMemoryBytes: Int64) {
		self.appFootprintBytes = appFootprintBytes
		self.devicePhysicalMemoryBytes = devicePhysicalMemoryBytes
		self.urlCacheMemoryBytes = urlCacheMemoryBytes
	}

	public var footprintFraction: Double { min(1, Double(appFootprintBytes) / Double(max(1, devicePhysicalMemoryBytes))) }

	/// "0.8% of 8 GB".
	public var percentLabel: String {
		guard devicePhysicalMemoryBytes > 0 else { return "Device memory unknown" }
		return String(format: "%.1f%% of ", footprintFraction * 100) + ByteCountFormatter.string(fromByteCount: Int64(clamping: devicePhysicalMemoryBytes), countStyle: .memory)
	}
}

/// `ProcessInfo.ThermalState`, named for people.
public enum ThermalLevel: String, Sendable, Equatable {
	case nominal, fair, serious, critical, unknown

	public init(_ state: ProcessInfo.ThermalState) {
		switch state {
		case .nominal: self = .nominal
		case .fair: self = .fair
		case .serious: self = .serious
		case .critical: self = .critical
		@unknown default: self = .unknown
		}
	}

	public var label: String {
		switch self {
		case .nominal: "Nominal"
		case .fair: "Fair (warm)"
		case .serious: "Serious (throttling)"
		case .critical: "Critical"
		case .unknown: "Unknown"
		}
	}
}

/// How quickly the train feed answered, the closest thing to signal strength an app can measure.
public enum LinkLatencyTier: Sendable, Equatable {
	case strong, good, slow

	public init(milliseconds: Int) {
		self = milliseconds < 100 ? .strong : milliseconds <= 300 ? .good : .slow
	}

	public var label: String {
		switch self {
		case .strong: "Strong (<100 ms)"
		case .good: "Good (100–300 ms)"
		case .slow: "Slow (>300 ms)"
		}
	}
}

extension DeviceNetworkStatus {
	private var linkTransports: [Transport] { transports.filter { $0 != .loopback } }

	/// The active link and, once a request has finished, how fast it is.
	/// Old latency is ignored without a usable link, since it describes a network that is gone.
	public func signalStrengthLabel(roundTripMilliseconds: Int?) -> String {
		switch state {
		case .offline: return "No signal"
		case .simulatedOutage: return "Simulated outage"
		case .searching: return "Searching for signal…"
		case .connecting: return "Connecting…"
		case .connected:
			let link = switch linkTransports.first {
			case .wifi?: "Wi-Fi link active" + (networkName.map { " (\($0))" } ?? "")
			case .cellular?: "Cellular (\(radioTechnology ?? "active"))"
			case .wiredEthernet?: "Wired Ethernet link"
			case .other?: "VPN or other network link"
			case .loopback?, nil: "Connected"
			}
			return link + (roundTripMilliseconds.map { " · " + LinkLatencyTier(milliseconds: $0).label } ?? "")
		}
	}

	/// The measured latency and, for radios, why no signal bars are shown.
	public func signalStrengthDetail(roundTripMilliseconds: Int?) -> String? {
		guard state == .connected else { return nil }
		let latency = roundTripMilliseconds.map { "\($0) ms API latency" } ?? "No server response measured yet"
		let note: String? = switch linkTransports.first {
		case .wifi?: "iOS does not share Wi-Fi signal strength (dBm) with apps"
		case .cellular?: "iOS does not share cellular signal bars with apps"
		default: nil
		}
		return ([latency] + [note].compactMap { $0 }).joined(separator: " · ")
	}

	/// "Wi-Fi (Home) · also Cellular (5G)", or "None" without a usable interface.
	public var interfaceSummary: String {
		guard let primary = linkTransports.first else { return "None" }
		let others = linkTransports.dropFirst().map(label(for:))
		return label(for: primary) + (others.isEmpty ? "" : " · also " + others.joined(separator: ", "))
	}

	/// IP versions, DNS, Low Data Mode, and whether data is metered.
	public var capabilitySummary: String {
		let ip = switch (supportsIPv4, supportsIPv6) {
		case (true, true): "IPv4 + IPv6"
		case (true, false): "IPv4"
		case (false, true): "IPv6"
		case (false, false): "No IP route"
		}
		return [ip, supportsDNS ? "DNS ready" : "No DNS", isConstrained ? "Low Data Mode on" : "Low Data Mode off", isExpensive ? "Metered (cellular / hotspot)" : "Unmetered"].joined(separator: " · ")
	}
}

/// One reading of everything the System status screen shows.
public struct SystemStatusSnapshot: Sendable, Equatable {
	public var storage: AppStorageBreakdown
	public var memory: AppMemoryStatus
	public var thermal: ThermalLevel
	public var isLowPowerMode: Bool
	/// The latest finished request to the train feed, in milliseconds.
	public var roundTripMilliseconds: Int?
	public var measuredAt: TimeInterval

	public init(storage: AppStorageBreakdown, memory: AppMemoryStatus, thermal: ThermalLevel, isLowPowerMode: Bool, roundTripMilliseconds: Int?, measuredAt: TimeInterval) {
		self.storage = storage
		self.memory = memory
		self.thermal = thermal
		self.isLowPowerMode = isLowPowerMode
		self.roundTripMilliseconds = roundTripMilliseconds
		self.measuredAt = measuredAt
	}
}

/// File and volume sizes. Reads the disk, so callers keep it off the main actor.
public enum StorageMeasure {
	/// The logical size of a file, or of every regular file under a directory.
	/// Symbolic links are not followed, so nothing counts twice. Missing paths are 0.
	public static func bytes(at url: URL) -> Int64 {
		let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
		guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
		if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
		guard values.isDirectory == true, let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
		var total: Int64 = 0
		for case let file as URL in files {
			guard let item = try? file.resourceValues(forKeys: keys), item.isRegularFile == true else { continue }
			total += Int64(item.fileSize ?? 0)
		}
		return total
	}

	public static func bytes(at urls: [URL]) -> Int64 { urls.reduce(0) { $0 + bytes(at: $1) } }

	/// Free space counts what iOS would purge for an important write, like a fleet download.
	public static func volume(containing url: URL) -> (free: Int64?, total: Int64?) {
		let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
		let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
		return (important ?? values?.volumeAvailableCapacity.map(Int64.init), values?.volumeTotalCapacity.map(Int64.init))
	}
}

public enum ProcessMemory {
	/// The process's physical footprint, falling back to its resident size; nil if the kernel refuses.
	public static func footprintBytes() -> UInt64? {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
		}
		guard result == KERN_SUCCESS else { return nil }
		return info.phys_footprint > 0 ? info.phys_footprint : info.resident_size
	}
}
