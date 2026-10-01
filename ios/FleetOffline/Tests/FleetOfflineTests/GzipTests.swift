import Foundation
import Testing
import CryptoKit
import CSQLite
import TransitCore
@testable import FleetOffline

@Suite struct GzipTests {
	@Test func spaceBudgetIncludesUnpackedDataAndReserve() throws {
		#expect(throws: OfflineFleetError.self) { try SnapshotFiles.requireSpace(available: 300 * 1_024 * 1_024, bytes: 100 * 1_024 * 1_024) }
		try SnapshotFiles.requireSpace(available: 400 * 1_024 * 1_024, bytes: 100 * 1_024 * 1_024)
	}

	@Test func rawManifestRejectsUnexpectedCompressedSizeBeforeBudgetArithmetic() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		var manifest = fixture.manifest
		manifest.compressedByteLength = Int64.max
		#expect(manifest.downloadByteLength == manifest.byteLength)
		#expect(throws: OfflineFleetError.self) { try SnapshotFiles.validate(manifest) }
	}

	@Test func reopeningRemovesInterruptedCandidateAndKeepsActiveSnapshot() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let directory = fixture.directory.appendingPathComponent("installed")
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let interrupted = directory.appendingPathComponent("interrupted-\(UUID().uuidString).sqlite")
		try Data(repeating: 0, count: 1_024).write(to: interrupted)
		let reopened = try OfflineFleetStore(directory: directory)
		#expect(await reopened.manifest() == fixture.manifest)
		#expect(!FileManager.default.fileExists(atPath: interrupted.path))
		#expect(try await reopened.detail(id: "car:1").history.count == 2)
	}

	@Test func cancellationInterruptsLongSQLiteWork() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let task = Task.detached {
			let db = try SnapshotDatabase(file: fixture.file)
			return try db.rows("WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<10000000) SELECT SUM(n) FROM numbers")
		}
		try await Task.sleep(for: .milliseconds(30))
		task.cancel()
		do { _ = try await task.value; Issue.record("Long SQLite work ignored cancellation") }
		catch is CancellationError { }
	}

	@Test func inflationStreamsAcrossInputAndOutputChunks() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("large.gz")
		let output = directory.appendingPathComponent("large.bin")
		var state: UInt64 = 12345
		let bytes = Data((0..<3_000_000).map { _ -> UInt8 in
			state = state &* 6364136223846793005 &+ 1
			return UInt8(truncatingIfNeeded: state >> 32)
		})
		let handle = try #require(gzopen(file.path, "wb"))
		let written = bytes.withUnsafeBytes { gzwrite(handle, $0.baseAddress, UInt32($0.count)) }
		#expect(gzclose(handle) == Z_OK && written == bytes.count)
		try SnapshotFiles.inflateGzip(file, to: output, expectedBytes: Int64(bytes.count))
		#expect(try Data(contentsOf: output) == bytes)
	}

	@Test func compressedSnapshotInstallsAndReopensWithoutTransportFile() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let (file, manifest) = try gzip(fixture)
		let directory = fixture.directory.appendingPathComponent("installed")
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: file, manifest: manifest)
		try FileManager.default.removeItem(at: file)
		let reopened = try OfflineFleetStore(directory: directory)
		#expect(await reopened.manifest() == manifest)
		let detail = try await reopened.detail(id: "car:1")
		#expect(detail.history.count == 2)
		let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		#expect(files.filter { $0.hasSuffix(".sqlite") }.count == 1)
		#expect(!files.contains { $0.hasSuffix(".gz") })
	}

	@Test func corruptTransportUnknownCompressionAndInflationLimitPreservePrevious() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let (file, manifest) = try gzip(fixture)
		let directory = fixture.directory.appendingPathComponent("installed")
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		var checksum = manifest; checksum.compressedSha256 = String(repeating: "0", count: 64)
		var size = manifest; size.compressedByteLength! += 1
		var tooSmall = manifest; tooSmall.byteLength = 1024
		var unsupported = manifest; unsupported.compression = "br"
		var missing = manifest; missing.compressedSha256 = nil
		for invalid in [checksum, size, tooSmall, unsupported, missing] {
			do { try await store.install(file: file, manifest: invalid); Issue.record("Accepted invalid transport") }
			catch is OfflineFleetError { }
			#expect(await store.manifest() == fixture.manifest)
		}
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".sqlite") }.count == 1)
	}

	@Test func truncatedGzipAndTrailingBytesFailEvenWithMatchingTransportHash() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let (file, original) = try gzip(fixture)
		let compressed = try Data(contentsOf: file)
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		for bytes in [Data(compressed.dropLast(4)), compressed + Data([0, 1, 2])] {
			try bytes.write(to: file)
			var manifest = original
			manifest.compressedByteLength = Int64(bytes.count)
			manifest.compressedSha256 = hash(bytes)
			do { try await store.install(file: file, manifest: manifest); Issue.record("Accepted damaged gzip") }
			catch is OfflineFleetError { }
			#expect(await store.manifest() == fixture.manifest)
		}
	}

	@Test func cancellationDuringCompressedInstallPreservesPrevious() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let (file, manifest) = try gzip(fixture)
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			try await store.install(file: file, manifest: manifest)
		}
		do { try await task.value; Issue.record("Activated canceled gzip") } catch is CancellationError { }
		#expect(await store.manifest() == fixture.manifest)
	}

	private func gzip(_ fixture: IntegrityFixture) throws -> (URL, FleetOfflineManifest) {
		let file = fixture.directory.appendingPathComponent("fixture.sqlite.gz")
		let output = try #require(gzopen(file.path, "wb"))
		let bytes = try Data(contentsOf: fixture.file)
		let written = bytes.withUnsafeBytes { gzwrite(output, $0.baseAddress, UInt32($0.count)) }
		let closed = gzclose(output)
		#expect(written == bytes.count && closed == Z_OK)
		let compressed = try Data(contentsOf: file)
		var manifest = fixture.manifest
		manifest.compression = "gzip"
		manifest.compressedByteLength = Int64(compressed.count)
		manifest.compressedSha256 = hash(compressed)
		manifest.downloadURL += ".gz"
		return (file, manifest)
	}
	private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
