import Foundation
import Testing
import TransitCore

@Suite struct OfflineManifestTests {
	@Test func legacyManifestKeepsLargeSQLiteSizeWithoutCompression() throws {
		let manifest = try decode()
		#expect(manifest.byteLength == 11_977_773_056)
		#expect(manifest.downloadByteLength == 11_977_773_056)
		#expect(manifest.compression == nil)
		#expect(manifest.compressedByteLength == nil)
		#expect(manifest.compressedSha256 == nil)
		#expect(try JSONDecoder().decode(FleetOfflineManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
	}

	@Test func gzipManifestSeparatesLargeTransferAndSavedSizes() throws {
		let manifest = try decode(compressionFields: """
		,"compression":"gzip","compressedByteLength":4294967296,"compressedSha256":"transport-hash"
		""")
		#expect(manifest.byteLength == 11_977_773_056)
		#expect(manifest.sha256 == "sqlite-hash")
		#expect(manifest.id == "sqlite-hash")
		#expect(manifest.compression == "gzip")
		#expect(manifest.compressedByteLength == 4_294_967_296)
		#expect(manifest.downloadByteLength == 4_294_967_296)
		#expect(manifest.compressedSha256 == "transport-hash")
		#expect(try JSONDecoder().decode(FleetOfflineManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
	}

	private func decode(compressionFields: String = "") throws -> FleetOfflineManifest {
		let json = """
		{
			"schemaVersion":1,"id":"sqlite-hash","generatedAt":1770000000,
			"historyStart":1767408000,"historyEnd":1770000000,
			"counts":{"cars":8442,"consists":1200,"events":5000000,"assertions":10000},
			"byteLength":11977773056,"sha256":"sqlite-hash",
			"downloadURL":"/subwaysForNerds/api/v1/fleet/offline/snapshots/sqlite-hash.sqlite\(compressionFields.isEmpty ? "" : ".gz")"
			\(compressionFields)
		}
		"""
		return try JSONDecoder().decode(FleetOfflineManifest.self, from: Data(json.utf8))
	}
}
