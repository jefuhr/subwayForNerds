import Foundation
import CryptoKit
import CSQLite
import TransitCore

private struct SnapshotResumeData: Codable {
	let url: String
	let data: Data
}

enum SnapshotFiles {
	static func saveResumeData(_ data: Data, at file: URL, for url: URL) throws {
		guard data.count <= 1_048_576 else { throw OfflineFleetError.invalid("The fleet resume information is too large. Retry the download.") }
		try JSONEncoder().encode(SnapshotResumeData(url: url.absoluteString, data: data)).write(to: file, options: .atomic)
	}
	static func resumeData(at file: URL, for url: URL) -> Data? {
		guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
			size <= 2 * 1_048_576,
			let bytes = try? Data(contentsOf: file),
			let resume = try? JSONDecoder().decode(SnapshotResumeData.self, from: bytes),
			resume.url == url.absoluteString, resume.data.count <= 1_048_576 else { return nil }
		return resume.data
	}

	static func databaseName(for fileName: String) -> String? {
		if fileName.hasSuffix(".sqlite") { return fileName }
		for suffix in ["-journal", "-wal", "-shm"] where fileName.hasSuffix(".sqlite" + suffix) {
			return String(fileName.dropLast(suffix.count))
		}
		return nil
	}
	static func removeDatabase(at file: URL) {
		for suffix in ["", "-journal", "-wal", "-shm"] {
			try? FileManager.default.removeItem(atPath: file.path + suffix)
		}
	}

	static func validate(_ pack: FleetPackManifest) throws {
		guard pack.isValid else {
			throw OfflineFleetError.invalid("The fleet pack information is incomplete or incompatible. Please prepare it again.")
		}
	}

	static func downloadURL(_ address: String, relativeTo base: URL) throws -> URL {
		guard let url = URL(string: address, relativeTo: base)?.absoluteURL,
			url.scheme == base.scheme, url.host == base.host, url.port == base.port,
			url.user == nil, url.password == nil, url.fragment == nil,
			url.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") else {
			throw OfflineFleetError.invalid("This fleet download address is unsupported.")
		}
		return url
	}

	static func validate(_ manifest: FleetOfflineManifest) throws {
		guard manifest.schemaVersion == 1, manifest.byteLength > 0,
			manifest.byteLength < Int64.max / 3 else {
			throw OfflineFleetError.invalid("This fleet snapshot needs a newer app version.")
		}
		guard manifest.compression == nil || manifest.compression == "gzip" else {
			throw OfflineFleetError.invalid("This fleet compression format needs a newer app version.")
		}
		if manifest.compression == "gzip" {
			guard let bytes = manifest.compressedByteLength, bytes > 0, bytes < Int64.max / 3,
				let hash = manifest.compressedSha256, hash.count == 64,
				hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
				throw OfflineFleetError.invalid("The fleet download information is incomplete. Please refresh it.")
			}
		} else if manifest.compressedByteLength != nil || manifest.compressedSha256 != nil {
			throw OfflineFleetError.invalid("The fleet download information has an unsupported transport format.")
		}
	}

	static func requireSpace(in directory: URL, bytes: Int64) throws {
		let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
		if let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value {
			try requireSpace(available: available, bytes: bytes)
		}
	}

	static func requireSpace(available: Int64, bytes: Int64) throws {
		let reserve: Int64 = 256 * 1_024 * 1_024
		guard bytes >= 0, bytes <= Int64.max - reserve else { throw OfflineFleetError.invalid("The fleet download size is unsupported.") }
		if available < bytes + reserve {
			let needed = ByteCountFormatter.string(fromByteCount: bytes + reserve, countStyle: .file)
			throw OfflineFleetError.invalid("Free at least \(needed) on your device to save this fleet download. Your previous download is still available.")
		}
	}

	static func verify(_ file: URL, bytes: Int64, sha256: String) throws {
		try Task.checkCancellation()
		let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
		guard size.map(Int64.init) == bytes else {
			throw OfflineFleetError.invalid("Fleet download is incomplete. Your previous download is still available.")
		}
		guard try digest(file) == sha256.lowercased() else {
			throw OfflineFleetError.invalid("Fleet download checksum failed. Please retry.")
		}
	}

	static func digest(_ file: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: file)
		defer { try? handle.close() }
		var digest = SHA256()
		while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
			try Task.checkCancellation()
			digest.update(data: block)
		}
		return digest.finalize().map({ String(format: "%02x", $0) }).joined()
	}

	/// Bounded streaming inflation: no database-sized allocation or second database copy.
	/// A gzip trailer, exact output size and no trailing bytes are required.
	static func inflateGzip(_ input: URL, to output: URL, expectedBytes: Int64) throws {
		guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
			throw OfflineFleetError.invalid("The fleet download could not be saved.")
		}
		let destination = try FileHandle(forWritingTo: output)
		defer { try? destination.close() }
		try inflateGzip(input, expectedBytes: expectedBytes) { try destination.write(contentsOf: $0) }
		try destination.synchronize()
	}

	static func inflateGzip(_ input: URL, expectedBytes: Int64, consume: (Data) throws -> Void) throws {
		let source = try FileHandle(forReadingFrom: input)
		defer { try? source.close() }
		var stream = z_stream()
		guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
			throw OfflineFleetError.invalid("The fleet download could not be expanded.")
		}
		defer { inflateEnd(&stream) }
		var buffer = [UInt8](repeating: 0, count: 1_048_576)
		var total: Int64 = 0
		var finished = false
		while let block = try source.read(upToCount: buffer.count), !block.isEmpty {
			try Task.checkCancellation()
			guard !finished else { throw damagedGzip }
			try block.withUnsafeBytes { inputBytes in
				stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: UInt8.self).baseAddress!)
				stream.avail_in = UInt32(inputBytes.count)
				defer { stream.next_in = nil }
				repeat {
					try Task.checkCancellation()
					let status = try buffer.withUnsafeMutableBytes { outputBytes -> Int32 in
						stream.next_out = outputBytes.bindMemory(to: UInt8.self).baseAddress!
						stream.avail_out = UInt32(outputBytes.count)
						defer { stream.next_out = nil }
						let status = inflate(&stream, Z_NO_FLUSH)
						guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw damagedGzip }
						let count = outputBytes.count - Int(stream.avail_out)
						guard Int64(count) <= expectedBytes - total else { throw damagedGzip }
						if count > 0 {
							try consume(Data(bytes: outputBytes.baseAddress!, count: count))
							total += Int64(count)
						}
						return status
					}
					if status == Z_STREAM_END {
						guard stream.avail_in == 0 else { throw damagedGzip }
						finished = true
						break
					}
					if status == Z_BUF_ERROR {
						guard stream.avail_in == 0 else { throw damagedGzip }
						break
					}
				} while stream.avail_in > 0 || stream.avail_out == 0
			}
		}
		guard finished, total == expectedBytes else { throw damagedGzip }
		try Task.checkCancellation()
	}

	private static var damagedGzip: OfflineFleetError {
		.invalid("The compressed fleet download is damaged or has an unexpected size. Please retry.")
	}
}
