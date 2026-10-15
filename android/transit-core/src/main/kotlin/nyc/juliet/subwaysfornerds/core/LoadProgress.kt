package nyc.juliet.subwaysfornerds.core

import java.util.Locale

class LoadProgress(fraction: Double?, val detail: String, val estimated: Boolean = false) {
	val fraction: Double? = fraction?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
	val percent: Int? get() = fraction?.let { if (it >= 1) 100 else minOf(99, (it * 100).toInt()) }
	val percentLabel: String? get() = percent?.let { "${if (estimated) "~" else ""}$it%" }
	val spokenPercent: String? get() = percent?.let { "${if (estimated) "about " else ""}$it percent" }
	companion object {
		fun step(completed: Int, count: Int, detail: String): LoadProgress = LoadProgress(completed.toDouble() / maxOf(1, count), "Step ${minOf(completed + 1, count)} of $count · $detail", true)
	}
}
enum class TransferPhase { REQUESTING, RECEIVING, VALIDATED, DECODING, FINISHED }
data class TransferProgress(val phase: TransferPhase, val receivedBytes: Long = 0, val expectedBytes: Long? = null, val host: String) {
	val fraction: Double? get() = when (phase) { TransferPhase.REQUESTING -> 0.0; TransferPhase.RECEIVING -> expectedBytes?.takeIf { it > 0 }?.let { (receivedBytes.toDouble() / it).coerceIn(0.0, 1.0) }; else -> 1.0 }
	fun load(subject: String): LoadProgress = LoadProgress(fraction, when (phase) {
		TransferPhase.REQUESTING -> "Requesting $subject from $host…"
		TransferPhase.RECEIVING -> if (expectedBytes != null && expectedBytes > 0) {
			if (receivedBytes > expectedBytes) "Receiving $subject · ${bytes(receivedBytes)} so far, more than the ${bytes(expectedBytes)} announced" else "Receiving $subject · ${bytes(receivedBytes)} of ${bytes(expectedBytes)}"
		} else "Receiving $subject · ${bytes(receivedBytes)} so far"
		TransferPhase.VALIDATED -> "No changes since the last check · reusing the $subject already on this device"
		TransferPhase.DECODING -> "Decoding ${bytes(receivedBytes)} of $subject…"
		TransferPhase.FINISHED -> "Loaded $subject"
	})
	companion object { fun bytes(count: Long): String = if (count < 1000) "$count B" else if (count < 1_000_000) String.format(Locale.US, "%.1f KB", count / 1000.0) else String.format(Locale.US, "%.1f MB", count / 1_000_000.0) }
}
typealias TransferProgressHandler = suspend (TransferProgress) -> Unit
val FleetPackProgress.load: LoadProgress get() = LoadProgress(fraction, "Step $step of $steps · $label" + if (total > 0) " · ${minOf(done, total)} of $total" else "", true)
