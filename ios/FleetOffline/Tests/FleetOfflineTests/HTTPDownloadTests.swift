import Foundation
import Testing
import TransitCore
@testable import FleetOffline

@Suite struct HTTPDownloadTests {
	/// Run against the recorded fixture server, never against a live upstream service.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["SFN_FIXTURE_API"] != nil))
	func realManifestDownloadAndOfflineQueries() async throws {
		let base = try #require(URL(string: ProcessInfo.processInfo.environment["SFN_FIXTURE_API"] ?? ""))
		#expect(["127.0.0.1", "localhost"].contains(base.host ?? ""))
		let api = TransitAPI(baseURL: base)
		let manifest = try await api.offlineManifest()
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sfn-http-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = try OfflineFleetStore(directory: directory)
		try await store.download(manifest: manifest, apiBaseURL: base)
		try await assertSavedSnapshot(store: store, manifest: manifest, directory: directory)
	}

	/// Exercises the real backend export even in environments that cannot bind a local HTTP port.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["SFN_FIXTURE_SNAPSHOT_DIRECTORY"] != nil))
	func backendGzipArtifactInstallsAndQueriesOffline() async throws {
		let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SFN_FIXTURE_SNAPSHOT_DIRECTORY"] ?? "")
		let manifest = try JSONDecoder().decode(FleetOfflineManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
		#expect(manifest.compression == "gzip")
		let fileName = try #require(URL(string: manifest.downloadURL)?.lastPathComponent)
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sfn-backend-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: source.appendingPathComponent(fileName), manifest: manifest)
		try await assertSavedSnapshot(store: store, manifest: manifest, directory: directory)
	}

	private func assertSavedSnapshot(store: OfflineFleetStore, manifest: FleetOfflineManifest, directory: URL) async throws {
		let installed = await store.manifest()
		#expect(installed?.sha256 == manifest.sha256)
		let page = try await store.page(query: ["view": "cars", "retired": "true"])
		#expect(page.total == manifest.counts.cars)
		#expect(page.rows.count == min(100, manifest.counts.cars))
		#expect(page.rows.allSatisfy { !$0.reporting })
		let searched = try await store.page(query: ["q": "4149", "view": "cars", "retired": "true"])
		#expect(searched.rows.contains { $0.id == "nyct:R211A:4149" })
		let detail = try await store.detail(id: "nyct:R211A:4149")
		#expect(!detail.history.isEmpty)
		#expect(detail.cars.allSatisfy { $0.reporting == false })
		let reopened = try OfflineFleetStore(directory: directory)
		let restored = try await reopened.detail(id: "nyct:R211A:4149")
		#expect(restored == detail)
	}
}
