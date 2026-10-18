import Foundation
import Testing
@testable import TransitCore

struct SystemStatusTests {
	private func storage(bundle: Int64 = 40, settings: Int64 = 2, transit: Int64 = 10, catalog: Int64 = 3, widget: Int64 = 1, urlCache: Int64 = 4, fleet: Int64 = 40, free: Int64? = 1_000, total: Int64? = 4_000) -> AppStorageBreakdown {
		AppStorageBreakdown(appBundleBytes: bundle, settingsBytes: settings, transitCacheBytes: transit, catalogBytes: catalog, widgetCacheBytes: widget, urlCacheBytes: urlCache, fleetBytes: fleet, deviceFreeBytes: free, deviceTotalBytes: total)
	}

	@Test func storageTotalsAddEveryCategory() {
		let value = storage()
		#expect(value.cacheBytes == 18)
		#expect(value.userDataBytes == 60)
		#expect(value.totalAppBytes == 100)
		#expect(AppStorageBreakdown.Category.allCases.map(value.bytes) == [40, 2, 18, 40])
	}

	@Test func storageFractionsShareTheTotalAndStayInRange() {
		let value = storage()
		#expect(value.fraction(.appBundle) == 0.4)
		#expect(value.fraction(.settings) == 0.02)
		#expect(value.fraction(.cache) == 0.18)
		#expect(value.fraction(.fleet) == 0.4)
		#expect(abs(AppStorageBreakdown.Category.allCases.map(value.fraction).reduce(0, +) - 1) < 0.000_001)
		#expect(value.deviceShare == 0.025)
		// Nothing measured yet divides by zero only in theory.
		let empty = AppStorageBreakdown()
		#expect(empty.totalAppBytes == 0)
		#expect(AppStorageBreakdown.Category.allCases.allSatisfy { empty.fraction($0) == 0 })
		#expect(empty.deviceShare == nil)
		// A failed measurement can come back negative; it never shows as a share outside 0...1.
		let negative = storage(bundle: -50, settings: 0, transit: 0, catalog: 0, widget: 0, urlCache: 0, fleet: 10)
		#expect(negative.fraction(.appBundle) == 0)
		#expect(negative.fraction(.fleet) == 1)
		#expect(storage(total: 50).deviceShare == 1)
	}

	@Test func storageLabelsNameEachCategory() {
		#expect(AppStorageBreakdown.Category.allCases.map(\.title) == ["App bundle", "Settings", "Cache", "Downloaded fleet"])
	}

	@Test func directoryMeasurementCountsRegularFilesRecursively() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("SystemStatusTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let nested = root.appendingPathComponent("a/b", isDirectory: true)
		try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
		try Data(count: 100).write(to: root.appendingPathComponent("one.json"))
		try Data(count: 250).write(to: nested.appendingPathComponent("two.bin"))
		try Data(count: 7).write(to: root.appendingPathComponent(".hidden"))
		// A link to a counted file must not count it twice.
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: nested.appendingPathComponent("two.bin"))
		#expect(StorageMeasure.bytes(at: root) == 357)
		#expect(StorageMeasure.bytes(at: root.appendingPathComponent("one.json")) == 100)
		#expect(StorageMeasure.bytes(at: [root.appendingPathComponent("one.json"), nested, root.appendingPathComponent("missing.json")]) == 350)
		#expect(StorageMeasure.bytes(at: root.appendingPathComponent("missing", isDirectory: true)) == 0)
		let volume = StorageMeasure.volume(containing: root)
		#expect((volume.free ?? 0) > 0)
		#expect((volume.total ?? 0) >= (volume.free ?? 0))
	}

	@Test func memoryShareIsAPercentOfPhysicalMemory() {
		let gib: UInt64 = 1 << 30
		let memory = AppMemoryStatus(appFootprintBytes: 64 << 20, devicePhysicalMemoryBytes: 8 * gib, urlCacheMemoryBytes: 512_000)
		#expect(memory.footprintFraction == 0.0078125)
		#expect(memory.percentLabel == "0.8% of 8 GB")
		#expect(AppMemoryStatus(appFootprintBytes: 3 * gib, devicePhysicalMemoryBytes: 6 * gib, urlCacheMemoryBytes: 0).percentLabel == "50.0% of 6 GB")
		// An unknown device size reports the footprint alone, never a division by zero.
		let unknown = AppMemoryStatus(appFootprintBytes: 10, devicePhysicalMemoryBytes: 0, urlCacheMemoryBytes: 0)
		#expect(unknown.footprintFraction == 1)
		#expect(unknown.percentLabel == "Device memory unknown")
	}

	@Test func processFootprintIsMeasured() {
		let footprint = ProcessMemory.footprintBytes()
		#expect((footprint ?? 0) > 1_000_000)
		#expect((footprint ?? 0) < ProcessInfo.processInfo.physicalMemory)
	}

	@Test func thermalLevelsMapAndLabelEachState() {
		#expect(ThermalLevel(.nominal) == .nominal)
		#expect(ThermalLevel(.fair) == .fair)
		#expect(ThermalLevel(.serious) == .serious)
		#expect(ThermalLevel(.critical) == .critical)
		#expect([ThermalLevel.nominal, .fair, .serious, .critical, .unknown].map(\.label) == ["Nominal", "Fair (warm)", "Serious (throttling)", "Critical", "Unknown"])
		#expect(ThermalLevel(rawValue: "serious") == .serious)
	}

	@Test func latencyTiersSplitAtOneAndThreeHundredMilliseconds() {
		#expect(LinkLatencyTier(milliseconds: 0) == .strong)
		#expect(LinkLatencyTier(milliseconds: 99) == .strong)
		#expect(LinkLatencyTier(milliseconds: 100) == .good)
		#expect(LinkLatencyTier(milliseconds: 300) == .good)
		#expect(LinkLatencyTier(milliseconds: 301) == .slow)
		#expect([LinkLatencyTier.strong, .good, .slow].map(\.label) == ["Strong (<100 ms)", "Good (100–300 ms)", "Slow (>300 ms)"])
	}

	@Test func signalSummaryDescribesTheLinkWithoutClaimingRawSignalBars() {
		let wifi = DeviceNetworkStatus(state: .connected, transports: [.wifi, .cellular], networkName: "NYCSubway", radioTechnology: "5G", supportsIPv4: true, supportsDNS: true)
		#expect(wifi.signalStrengthLabel(roundTripMilliseconds: nil) == "Wi-Fi link active (NYCSubway)")
		#expect(wifi.signalStrengthLabel(roundTripMilliseconds: 28) == "Wi-Fi link active (NYCSubway) · Strong (<100 ms)")
		#expect(wifi.signalStrengthDetail(roundTripMilliseconds: 28) == "28 ms API latency")
		#expect(wifi.signalStrengthDetail(roundTripMilliseconds: nil) == "No server response measured yet")

		let cellular = DeviceNetworkStatus(state: .connected, transports: [.cellular], radioTechnology: "LTE", isExpensive: true)
		#expect(cellular.signalStrengthLabel(roundTripMilliseconds: 450) == "Cellular (LTE) · Slow (>300 ms)")
		#expect(cellular.signalStrengthDetail(roundTripMilliseconds: 450) == "450 ms API latency")
		#expect(DeviceNetworkStatus(state: .connected, transports: [.cellular]).signalStrengthLabel(roundTripMilliseconds: 150) == "Cellular (active) · Good (100–300 ms)")
		#expect(DeviceNetworkStatus(state: .connected, transports: [.wiredEthernet]).signalStrengthLabel(roundTripMilliseconds: nil) == "Wired Ethernet link")
		#expect(DeviceNetworkStatus(state: .connected, transports: [.other]).signalStrengthLabel(roundTripMilliseconds: nil) == "VPN or other network link")
		#expect(DeviceNetworkStatus(state: .connected).signalStrengthLabel(roundTripMilliseconds: nil) == "Connected")
		#expect(DeviceNetworkStatus(state: .connected, transports: [.wiredEthernet]).signalStrengthDetail(roundTripMilliseconds: nil) == "No server response measured yet")

		// Without a usable link an old latency would describe a network that is gone.
		#expect(DeviceNetworkStatus(state: .offline).signalStrengthLabel(roundTripMilliseconds: 28) == "No signal")
		#expect(DeviceNetworkStatus(state: .offline).signalStrengthDetail(roundTripMilliseconds: 28) == nil)
		#expect(DeviceNetworkStatus(state: .simulatedOutage, transports: [.wifi]).signalStrengthLabel(roundTripMilliseconds: 28) == "Simulated outage")
		#expect(DeviceNetworkStatus(state: .searching, transports: [.wifi]).signalStrengthLabel(roundTripMilliseconds: nil) == "Searching for signal…")
		#expect(DeviceNetworkStatus(state: .connecting, transports: [.wifi]).signalStrengthLabel(roundTripMilliseconds: 28) == "Connecting…")
	}

	@Test func interfaceAndCapabilitySummariesListEveryPathFact() {
		let both = DeviceNetworkStatus(state: .connected, transports: [.wifi, .cellular, .loopback], networkName: "Home", radioTechnology: "5G", isExpensive: false, isConstrained: true, supportsIPv4: true, supportsIPv6: true, supportsDNS: true)
		#expect(both.interfaceSummary == "Wi-Fi (Home) · also Cellular (5G)")
		#expect(both.capabilitySummary == "IPv4 + IPv6 · DNS ready · Low Data Mode on · Unmetered")
		let cellular = DeviceNetworkStatus(state: .connected, transports: [.cellular], isExpensive: true, supportsIPv6: true)
		#expect(cellular.interfaceSummary == "Cellular")
		#expect(cellular.capabilitySummary == "IPv6 · No DNS · Low Data Mode off · Metered (cellular / hotspot)")
		#expect(DeviceNetworkStatus(state: .offline, transports: [.loopback]).interfaceSummary == "None")
		#expect(DeviceNetworkStatus(state: .offline).capabilitySummary == "No IP route · No DNS · Low Data Mode off · Unmetered")
	}

	@Test func transitAPIRecordsTheLatestRoundTrip() async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LatencyProtocol.self]
		let api = TransitAPI(baseURL: URL(string: "https://latency.test/api/v1/")!, session: URLSession(configuration: configuration))
		#expect(await api.lastRoundTripMilliseconds == nil)
		_ = try await api.stations()
		let measured = try #require(await api.lastRoundTripMilliseconds)
		#expect(measured >= 20)
		#expect(measured < 5_000)
	}
}

/// Answers every request with an empty station list after a short delay.
private final class LatencyProtocol: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
			client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: Data("[]".utf8))
			client?.urlProtocolDidFinishLoading(self)
		}
	}
	override func stopLoading() {}
}
