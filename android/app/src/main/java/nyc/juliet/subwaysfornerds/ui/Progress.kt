package nyc.juliet.subwaysfornerds.ui

import nyc.juliet.subwaysfornerds.core.LoadProgress
import java.util.Locale

/** The bar before a request starts: named work, no percent, and whether a connection is missing. */
fun waitingLoad(subject: String, connected: Boolean): LoadProgress =
	LoadProgress(null, if (connected) "Waiting to request $subject…" else "Waiting for a connection to request $subject…")

/** Decimal file sizes in the style riders see in iOS: "512 bytes", "12 KB", "4.2 MB". */
object ByteCounts {
	fun file(bytes: Long): String = when {
		bytes == 1L -> "1 byte"
		bytes < 1_000 -> "$bytes bytes"
		bytes < 1_000_000 -> "${Math.round(bytes / 1_000.0)} KB"
		bytes < 1_000_000_000 -> String.format(Locale.US, "%.1f MB", bytes / 1_000_000.0)
		else -> String.format(Locale.US, "%.2f GB", bytes / 1_000_000_000.0)
	}
	fun file(bytes: Int): String = file(bytes.toLong())
}
