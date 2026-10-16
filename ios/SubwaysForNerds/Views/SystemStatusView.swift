import SwiftUI
import TransitCore

/// Storage, network, memory, and device health in one screen, for diagnosing the app on a real phone.
struct SystemStatusView: View {
	@Environment(AppModel.self) private var app
	var body: some View {
		let status = app.systemStatus
		List {
			storageSection(status?.storage)
			networkSection(status)
			memorySection(status?.memory)
			deviceSection(status)
			Section {
				Button("Refresh status") { Task { await refresh() } }
					.actionStyle().frame(minHeight: 44).accessibilityIdentifier("refreshSystemStatus")
			} footer: {
				if let status { Text("Measured \(easternDate(status.measuredAt, timeFormat: app.units.time)).") }
			}
		}
		.themedList().navigationTitle("System status").navigationBarTitleDisplayMode(.inline)
		.task { await refresh() }
	}

	private func refresh() async {
		await app.reloadOfflineStatus()
		await app.refreshSystemStatus()
	}

	private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

	private func shade(_ category: AppStorageBreakdown.Category) -> Color {
		let opacity = switch category {
		case .appBundle: 1.0
		case .settings: 0.75
		case .cache: 0.5
		case .fleet: 0.28
		}
		return app.theme.accent.opacity(opacity)
	}

	@ViewBuilder private func storageSection(_ storage: AppStorageBreakdown?) -> some View {
		Section {
			if let storage {
				LabeledContent("Total app storage", value: bytes(storage.totalAppBytes)).font(.subheadline.weight(.semibold))
					.accessibilityIdentifier("systemStatusTotalStorage")
				storageBar(storage)
				storageRow(.appBundle, storage, identifier: "systemStatusAppBundleStorage", detail: "Installed app, widgets, and frameworks")
				storageRow(.settings, storage, identifier: "systemStatusSettingsStorage", detail: "Settings, preferences, and widget choices. Your account session is kept in the Keychain.")
				storageRow(.cache, storage, identifier: "systemStatusCacheStorage", detail: cacheDetail(storage))
				storageRow(.fleet, storage, identifier: "systemStatusFleetStorage", detail: fleetDetail)
				LabeledContent("Available on device", value: storage.deviceFreeBytes.map { free in
					bytes(free) + (storage.deviceTotalBytes.map { " of \(bytes($0))" } ?? "")
				} ?? "Unknown").font(.subheadline).accessibilityIdentifier("systemStatusDeviceFreeStorage")
			} else {
				LoadingBar(title: "Measuring storage", progress: LoadProgress(fraction: nil, detail: "Reading app files…")).accessibilityIdentifier("systemStatusStorageLoading")
			}
		} header: { ListHeader("App storage") }
	}

	/// Each category's share of the total, in the same order and shades as the rows below.
	private func storageBar(_ storage: AppStorageBreakdown) -> some View {
		GeometryReader { proxy in
			HStack(spacing: 1) {
				ForEach(AppStorageBreakdown.Category.allCases) { category in
					let fraction = storage.fraction(category)
					if fraction > 0 { shade(category).frame(width: max(2, (proxy.size.width - 3) * fraction)) }
				}
				Spacer(minLength: 0)
			}
		}
		.frame(height: 10).clipShape(Capsule())
		.background(app.theme.ink.opacity(0.08), in: Capsule())
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(AppStorageBreakdown.Category.allCases.map { "\($0.title) \(Int((storage.fraction($0) * 100).rounded())) percent" }.joined(separator: ", "))
	}

	private func storageRow(_ category: AppStorageBreakdown.Category, _ storage: AppStorageBreakdown, identifier: String, detail: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 8) {
				Circle().fill(shade(category)).frame(width: 9, height: 9).accessibilityHidden(true)
				LabeledContent(category.title, value: "\(bytes(storage.bytes(category))) · \(Int((storage.fraction(category) * 100).rounded()))%")
			}.font(.subheadline)
			Text(detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 17)
		}
		.accessibilityElement(children: .combine)
		.accessibilityIdentifier(identifier)
	}

	private func cacheDetail(_ storage: AppStorageBreakdown) -> String {
		let usage = app.offlineUsage.map { " (\($0.boardCount) boards, \($0.tripCount) trips)" } ?? ""
		return "Offline boards and trips \(bytes(storage.transitCacheBytes))\(usage) · station catalog \(bytes(storage.catalogBytes)) · widget and HTTP cache \(bytes(storage.widgetCacheBytes + storage.urlCacheBytes))"
	}

	private var fleetDetail: String {
		guard let saved = app.offlineManifest else { return "Not downloaded" }
		return "\(saved.counts.cars.formatted()) cars · \(saved.counts.events.formatted()) movement events · saved \(easternDate(saved.generatedAt, timeFormat: app.units.time))"
	}

	private func networkSection(_ status: SystemStatusSnapshot?) -> some View {
		let network = app.deviceNetworkStatus
		let latency = status?.roundTripMilliseconds
		return Section {
			DeviceNetworkLabel(font: .subheadline)
			VStack(alignment: .leading, spacing: 2) {
				LabeledContent("Signal & link quality", value: network.signalStrengthLabel(roundTripMilliseconds: latency))
				if let detail = network.signalStrengthDetail(roundTripMilliseconds: latency) { Text(detail).font(.caption).foregroundStyle(.secondary) }
			}
			.font(.subheadline).accessibilityElement(children: .combine).accessibilityIdentifier("systemStatusNetworkStrength")
			LabeledContent("Interface", value: network.interfaceSummary).font(.subheadline).accessibilityIdentifier("systemStatusInterface")
			if let latency { LabeledContent("Server response time", value: "\(latency) ms").font(.subheadline).accessibilityIdentifier("systemStatusLatency") }
			LabeledContent("Path", value: network.capabilitySummary).font(.subheadline).accessibilityIdentifier("systemStatusPathCapabilities")
			Text(app.networkSyncSummary).font(.caption).accessibilityIdentifier("systemStatusBackgroundRefresh")
			LabeledContent("Server", value: app.baseURL.host() ?? app.endpoint).font(.subheadline)
			Toggle("Simulate no connection", isOn: Binding(get: { app.outageSimulated }, set: { value in Task { await app.setSimulatedOutage(value) } }))
				.font(.subheadline).accessibilityIdentifier("simulateOutage")
		} header: { ListHeader("Network") }
	}

	private func memorySection(_ memory: AppMemoryStatus?) -> some View {
		Section {
			if let memory {
				LabeledContent("App RAM used", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: memory.appFootprintBytes), countStyle: .memory))
					.font(.subheadline).accessibilityIdentifier("systemStatusRamUsed")
				LabeledContent("Device RAM", value: memory.percentLabel).font(.subheadline).accessibilityIdentifier("systemStatusDeviceRam")
				VStack(alignment: .leading, spacing: 2) {
					LabeledContent("In-memory cache", value: ByteCountFormatter.string(fromByteCount: memory.urlCacheMemoryBytes, countStyle: .memory))
					Text("\(app.stations.count.formatted()) stations · \(app.liveTrips.count) live trains loaded").font(.caption).foregroundStyle(.secondary)
				}
				.font(.subheadline).accessibilityElement(children: .combine).accessibilityIdentifier("systemStatusMemoryCache")
			} else {
				Text("Measuring memory…").font(.subheadline).foregroundStyle(.secondary)
			}
		} header: { ListHeader("Memory") } footer: { Text("App RAM is the footprint iOS counts against the app's memory limit.") }
	}

	private func deviceSection(_ status: SystemStatusSnapshot?) -> some View {
		Section {
			LabeledContent("Thermal state", value: status?.thermal.label ?? "Checking…").font(.subheadline).accessibilityIdentifier("systemStatusThermalState")
			LabeledContent("Low Power Mode", value: status.map { $0.isLowPowerMode ? "On" : "Off" } ?? "Checking…").font(.subheadline).accessibilityIdentifier("systemStatusLowPowerMode")
			LabeledContent("Station catalog", value: "\(app.stations.count.formatted()) stations").font(.subheadline).accessibilityIdentifier("systemStatusCatalog")
			LabeledContent("App version", value: appVersion).font(.subheadline).accessibilityIdentifier("systemStatusAppVersion")
			LabeledContent("iOS", value: ProcessInfo.processInfo.operatingSystemVersionString).font(.subheadline)
		} header: { ListHeader("Device") }
	}

	private var appVersion: String {
		let info = Bundle.main.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
		return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
	}
}
