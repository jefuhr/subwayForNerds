import Foundation
import Testing
import TransitCore
@testable import FleetOffline

@Suite struct DownloadProgressTests {
	@Test func progressNamesTheStageAndItsExactByteCounts() {
		let downloading = FleetDownloadProgress(stage: .downloading, completedBytes: 512_000, totalBytes: 1_024_000)
		#expect(downloading.fraction == 0.3)
		#expect(downloading.load == LoadProgress(fraction: 0.3, detail: "Step 1 of 5 · Downloading the fleet pack · \(TransferProgress.bytes(512_000)) of \(TransferProgress.bytes(1_024_000))", estimated: true))
		#expect(FleetDownloadProgress(stage: .activating, completedBytes: 0, totalBytes: 0).load.detail == "Step 5 of 5 · Switching to the new fleet copy")
		// Counts beyond a stage's total never move the bar into the next stage.
		#expect(FleetDownloadProgress(stage: .importing, completedBytes: 10, totalBytes: 5).fraction == FleetDownloadProgress(stage: .checking, completedBytes: 0, totalBytes: 1).fraction)
		let ordered = FleetDownloadProgress.Stage.allCases.map { FleetDownloadProgress(stage: $0, completedBytes: 0, totalBytes: 1).fraction }
		#expect(ordered == ordered.sorted() && ordered.first == 0 && ordered.allSatisfy { $0 < 1 })
	}

	@Test func packInstallReportsEveryStageInOrderWithExactByteCounts() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		let log = ProgressRecorder()
		try await store.install(file: fixture.file, pack: fixture.manifest) { log.append($0) }
		let values = log.values
		#expect(Self.stages(values) == [.verifying, .importing, .checking, .activating])
		#expect(values.last { $0.stage == .verifying }?.completedBytes == fixture.manifest.archiveByteLength)
		#expect(values.last { $0.stage == .importing } == FleetDownloadProgress(stage: .importing, completedBytes: fixture.manifest.uncompressedByteLength, totalBytes: fixture.manifest.uncompressedByteLength))
		let saved = try #require(await store.manifest())
		#expect(values.last { $0.stage == .checking } == FleetDownloadProgress(stage: .checking, completedBytes: saved.byteLength, totalBytes: saved.byteLength))
		Self.expectBoundedAndMonotonic(values)
	}

	@Test func snapshotInstallReportsEveryStageInOrder() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		let log = ProgressRecorder()
		try await store.install(file: fixture.file, manifest: fixture.manifest) { log.append($0) }
		let values = log.values
		#expect(Self.stages(values) == [.verifying, .importing, .checking, .activating])
		#expect(values.last { $0.stage == .checking }?.completedBytes == fixture.manifest.byteLength)
		Self.expectBoundedAndMonotonic(values)
	}

	private static func stages(_ values: [FleetDownloadProgress]) -> [FleetDownloadProgress.Stage] {
		values.map(\.stage).reduce(into: []) { result, stage in if result.last != stage { result.append(stage) } }
	}

	private static func expectBoundedAndMonotonic(_ values: [FleetDownloadProgress]) {
		#expect(values.allSatisfy { $0.totalBytes == 0 || $0.completedBytes <= $0.totalBytes })
		#expect(zip(values, values.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
		#expect(values.allSatisfy { $0.fraction < 1 })
	}
}

final class ProgressRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var recorded: [FleetDownloadProgress] = []
	var values: [FleetDownloadProgress] { lock.withLock { recorded } }
	func append(_ value: FleetDownloadProgress) { lock.withLock { recorded.append(value) } }
}
