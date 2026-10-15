package nyc.juliet.subwaysfornerds.fleet

import java.io.File
import java.io.InputStream
import java.io.PushbackInputStream
import java.security.MessageDigest
import java.util.zip.CRC32
import java.util.zip.DataFormatException
import java.util.zip.Inflater

class FleetValidationException(message: String, cause: Throwable? = null) : java.io.IOException(message, cause)
class FleetUnavailableException : java.io.IOException("Download a fleet snapshot while connected to browse it offline.")
class FleetPackExpiredException : java.io.IOException("This fleet pack expired. Prepare a fresh pack. Your previous download is still available.")

internal object FleetArchive {
	const val RESERVE_BYTES = 256L * 1024 * 1024
	private const val BLOCK = 64 * 1024

	fun requireSpace(available: Long, bytes: Long) {
		if (bytes < 0 || bytes > Long.MAX_VALUE - RESERVE_BYTES) throw FleetValidationException("The fleet download size is unsupported.")
		if (available < bytes + RESERVE_BYTES) throw FleetValidationException("Free at least ${bytes + RESERVE_BYTES} bytes to save this fleet download. Your previous download is still available.")
	}

	fun digest(file: File, check: () -> Unit = {}, progress: (Long) -> Unit = {}): String {
		val hash = MessageDigest.getInstance("SHA-256")
		var total = 0L
		file.inputStream().buffered(BLOCK).use { input ->
			val buffer = ByteArray(BLOCK)
			while (true) {
				check()
				val count = input.read(buffer)
				if (count < 0) break
				hash.update(buffer, 0, count)
				total += count
				progress(total)
			}
		}
		return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
	}

	fun verify(file: File, bytes: Long, sha256: String, check: () -> Unit = {}, progress: (Long) -> Unit = {}) {
		check()
		if (file.length() != bytes) throw FleetValidationException("Fleet download is incomplete. Your previous download is still available.")
		if (digest(file, check, progress) != sha256.lowercase()) throw FleetValidationException("Fleet download checksum failed. Please retry.")
	}

	/** One gzip member, verified trailer, exact output length, and no trailing bytes. */
	fun expand(input: InputStream, expectedBytes: Long, check: () -> Unit = {}, consume: (ByteArray) -> Unit) {
		if (expectedBytes <= 0) throw damaged()
		val source = PushbackInputStream(input, BLOCK)
		val headerCRC = CRC32()
		var headerBytes = 0
		fun headerByte(): Int {
			check()
			val byte = source.read()
			if (byte < 0 || ++headerBytes > 1_048_576) throw damaged()
			headerCRC.update(byte)
			return byte
		}
		if (headerByte() != 0x1f || headerByte() != 0x8b || headerByte() != 8) throw damaged()
		val flags = headerByte()
		if (flags and 0xe0 != 0) throw damaged()
		repeat(6) { headerByte() }
		if (flags and 4 != 0) {
			val count = headerByte() or (headerByte() shl 8)
			repeat(count) { headerByte() }
		}
		if (flags and 8 != 0) while (headerByte() != 0) { }
		if (flags and 16 != 0) while (headerByte() != 0) { }
		if (flags and 2 != 0) {
			val expected = source.read() or (source.read() shl 8)
			if (expected != (headerCRC.value.toInt() and 0xffff)) throw damaged()
		}
		val inflater = Inflater(true)
		val buffer = ByteArray(BLOCK)
		val output = ByteArray(BLOCK)
		val crc = CRC32()
		var total = 0L
		var supplied = 0
		try {
			while (!inflater.finished()) {
				check()
				if (inflater.needsInput()) {
					supplied = source.read(buffer)
					if (supplied < 0) throw damaged()
					inflater.setInput(buffer, 0, supplied)
				}
				val count = try { inflater.inflate(output) } catch (error: DataFormatException) { throw damaged(error) }
				if (count.toLong() > expectedBytes - total) throw damaged()
				if (count > 0) {
					check()
					crc.update(output, 0, count)
					consume(output.copyOf(count))
					total += count
				} else if (!inflater.finished() && !inflater.needsInput()) throw damaged()
			}
			if (inflater.remaining > 0) source.unread(buffer, supplied - inflater.remaining, inflater.remaining)
			fun uint32(): Long {
				var value = 0L
				repeat(4) { index ->
					val byte = source.read()
					if (byte < 0) throw damaged()
					value = value or (byte.toLong() shl (index * 8))
				}
				return value
			}
			if (uint32() != crc.value || uint32() != (total and 0xffffffffL) || total != expectedBytes || source.read() != -1) throw damaged()
			check()
		} finally { inflater.end() }
	}

	private fun damaged(cause: Throwable? = null) = FleetValidationException("The compressed fleet download is damaged or has an unexpected size. Please retry.", cause)
}
