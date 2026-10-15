package nyc.juliet.subwaysfornerds.data

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Serializes app/worker instances and processes. Callers never suspend while holding this lock. */
internal class AtomicStorage(val directory: File) {
	private val lock = locks.computeIfAbsent(directory.canonicalPath) { ReentrantLock() }

	fun <T> locked(operation: () -> T): T = lock.withLock {
		if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) throw IOException("Local storage could not be opened.")
		RandomAccessFile(File(directory, ".lock"), "rw").use { file ->
			file.channel.lock().use {
				// A killed process cannot leave its temporary replacement authoritative.
				directory.listFiles().orEmpty().filter { it.name.startsWith('.') && it.name.endsWith(".staging") }.forEach { it.delete() }
				operation()
			}
		}
	}

	fun read(name: String, maximumBytes: Long = 32L * 1024 * 1024): ByteArray? {
		val file = path(name)
		if (!file.exists()) return null
		if (file.length() > maximumBytes) throw IOException("Saved data exceeds its supported size.")
		return file.inputStream().use { input ->
			val output = java.io.ByteArrayOutputStream()
			val buffer = ByteArray(64 * 1024)
			var total = 0L
			while (true) {
				val count = input.read(buffer)
				if (count < 0) break
				total += count
				if (total > maximumBytes) throw IOException("Saved data exceeds its supported size.")
				output.write(buffer, 0, count)
			}
			output.toByteArray()
		}
	}

	fun write(name: String, bytes: ByteArray, beforeActivate: () -> Unit = {}) {
		val destination = path(name)
		val candidate = File(directory, ".${destination.name}-${UUID.randomUUID()}.staging")
		try {
			FileOutputStream(candidate).use { output -> output.write(bytes); output.fd.sync() }
			beforeActivate()
			Files.move(candidate.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
		} finally { candidate.delete() }
	}

	fun delete(name: String) {
		val file = path(name)
		if (file.exists() && !file.delete()) throw IOException("Saved data could not be removed.")
	}

	private fun path(name: String): File {
		require(name.isNotEmpty() && File(name).name == name && !name.contains('\u0000'))
		return File(directory, name)
	}

	companion object { private val locks = ConcurrentHashMap<String, ReentrantLock>() }
}
