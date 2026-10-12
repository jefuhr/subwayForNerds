import Foundation
import Testing
@testable import FleetOffline

@Suite struct FleetPackTransportTests {
	@Test func downloadAddressAndResumeDataStayBoundToTheExactOrigin() throws {
		let base = URL(string: "https://fleet.example/api/v1/")!
		let archive = try SnapshotFiles.downloadURL("/archive.gz", relativeTo: base)
		#expect(archive.absoluteString == "https://fleet.example/archive.gz")
		for invalid in ["https://other.example/archive.gz", "http://fleet.example/archive.gz", "https://fleet.example:444/archive.gz", "https://user:password@fleet.example/archive.gz"] {
			#expect(throws: OfflineFleetError.self) { try SnapshotFiles.downloadURL(invalid, relativeTo: base) }
		}
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("resume.json")
		let resume = Data([1, 2, 3])
		try SnapshotFiles.saveResumeData(resume, at: file, for: archive)
		#expect(SnapshotFiles.resumeData(at: file, for: archive) == resume)
		#expect(SnapshotFiles.resumeData(at: file, for: URL(string: "https://other.example/archive.gz")!) == nil)
		#expect(SnapshotFiles.resumeData(at: file, for: URL(string: "https://fleet.example/new.gz")!) == nil)
		try Data("bad JSON".utf8).write(to: file)
		#expect(SnapshotFiles.resumeData(at: file, for: archive) == nil)
	}

	@Test func resumeDataIsBoundedAndCanceledInflationStopsBeforeActivation() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let file = fixture.directory.appendingPathComponent("resume.json"), url = URL(string: "https://fleet.example/archive.gz")!
		#expect(throws: OfflineFleetError.self) {
			try SnapshotFiles.saveResumeData(Data(repeating: 0, count: 1_048_577), at: file, for: url)
		}
		let task = Task {
			try SnapshotFiles.inflateGzip(fixture.file, expectedBytes: fixture.manifest.uncompressedByteLength) { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
		}
		do { try await task.value; Issue.record("Inflation ignored cancellation") }
		catch is CancellationError {}
	}
}
