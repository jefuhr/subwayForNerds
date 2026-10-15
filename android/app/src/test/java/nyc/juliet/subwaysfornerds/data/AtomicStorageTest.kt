package nyc.juliet.subwaysfornerds.data

import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import org.junit.Assert.*
import org.junit.Test

class AtomicStorageTest {
	@Test fun durableReopenAndFailedWritePreserveCurrentValue() {
		val root = Files.createTempDirectory("sfn-atomic").toFile()
		try {
			val store = AtomicStorage(root)
			store.locked { store.write("state.json", "first".toByteArray()) }
			assertEquals("first", AtomicStorage(root).locked { store.read("state.json")!!.decodeToString() })
			assertThrows(IllegalStateException::class.java) {
				store.locked { store.write("state.json", "second".toByteArray()) { throw IllegalStateException("interrupted") } }
			}
			assertEquals("first", store.locked { store.read("state.json")!!.decodeToString() })
			assertFalse(root.listFiles()!!.any { it.name.endsWith(".staging") })
		} finally { root.deleteRecursively() }
	}

	@Test fun independentInstancesSerializeReadModifyWrite() {
		val root = Files.createTempDirectory("sfn-lock").toFile()
		val threads = Executors.newFixedThreadPool(4)
		try {
			val futures = (1..4).map {
				threads.submit {
					val store = AtomicStorage(root)
					repeat(25) {
						store.locked {
							val value = store.read("counter")?.decodeToString()?.toInt() ?: 0
							store.write("counter", (value + 1).toString().toByteArray())
						}
					}
				}
			}
			futures.forEach { it.get() }
			assertEquals("100", File(root, "counter").readText())
		} finally { threads.shutdownNow(); root.deleteRecursively() }
	}
}
