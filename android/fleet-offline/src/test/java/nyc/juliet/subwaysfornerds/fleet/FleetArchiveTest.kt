package nyc.juliet.subwaysfornerds.fleet

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.CancellationException
import java.util.zip.GZIPOutputStream
import org.junit.Assert.*
import org.junit.Test

class FleetArchiveTest {
	private fun archive(bytes: ByteArray): ByteArray = ByteArrayOutputStream().apply {
		GZIPOutputStream(this).use { it.write(bytes) }
	}.toByteArray()

	@Test fun streamsExactPayloadWithoutRenewingOrInventingBytes() {
		val bytes = ByteArray(512_123) { (it % 251).toByte() }
		val output = ByteArrayOutputStream()
		FleetArchive.expand(ByteArrayInputStream(archive(bytes)), bytes.size.toLong()) { output.write(it) }
		assertArrayEquals(bytes, output.toByteArray())
	}

	@Test fun rejectsTruncationBadCRCExtraMembersAndTrailingBytes() {
		val gzip = archive("saved history".toByteArray())
		val damaged = gzip.clone().apply { this[size - 8] = (this[size - 8].toInt() xor 1).toByte() }
		for (input in listOf(gzip.copyOf(gzip.size - 1), damaged, gzip + byteArrayOf(0), gzip + gzip)) {
			assertThrows(FleetValidationException::class.java) {
				FleetArchive.expand(ByteArrayInputStream(input), 13) { }
			}
		}
	}

	@Test fun rejectsOversizedExpansionBeforeHandingItToImporter() {
		var accepted = 0
		assertThrows(FleetValidationException::class.java) {
			FleetArchive.expand(ByteArrayInputStream(archive(ByteArray(100_000))), 10) { accepted += it.size }
		}
		assertEquals(0, accepted)
	}

	@Test fun cancellationInterruptsStreaming() {
		var checks = 0
		assertThrows(CancellationException::class.java) {
			FleetArchive.expand(ByteArrayInputStream(archive(ByteArray(300_000))), 300_000,
				check = { if (++checks > 16) throw CancellationException() }) { }
		}
	}

	@Test fun spaceBudgetIncludesReserveAndRejectsOverflow() {
		val reserve = 256L * 1024 * 1024
		FleetArchive.requireSpace(100 + reserve, 100)
		assertThrows(FleetValidationException::class.java) { FleetArchive.requireSpace(99 + reserve, 100) }
		assertThrows(FleetValidationException::class.java) { FleetArchive.requireSpace(Long.MAX_VALUE, Long.MAX_VALUE) }
	}
}
