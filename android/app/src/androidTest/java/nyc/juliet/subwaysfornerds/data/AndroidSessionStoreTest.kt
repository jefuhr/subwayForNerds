package nyc.juliet.subwaysfornerds.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import org.junit.Assert.*
import org.junit.Test

/** Unique key aliases and temporary directories keep real app credentials untouched. */
class AndroidSessionStoreTest {
	private class TestContext(base: Context, private val directory: File, private val namespace: String) : ContextWrapper(base) {
		override fun getApplicationContext(): Context = this
		override fun getNoBackupFilesDir(): File = directory
		override fun getPackageName(): String = namespace
	}
	private suspend fun fixture(block: suspend (Context, File) -> Unit) {
		val base = InstrumentationRegistry.getInstrumentation().targetContext
		val directory = File(base.cacheDir, "session-test-${UUID.randomUUID()}").apply { mkdirs() }
		val context = TestContext(base, directory, base.packageName + ".sessiontest." + UUID.randomUUID())
		try { block(context, File(directory, "session-v1")) }
		finally { AndroidSessionStore(context).clear(); directory.deleteRecursively() }
	}
	private fun pending() = AndroidAuthPending("google", "login", "synthetic-state", "synthetic-secret-verifier", "challenge-1",
		"https://example.test/api/v1/auth/android/start?challenge=challenge-1", System.currentTimeMillis() / 1000.0)

	@Test fun pendingAndSessionReopenEncryptedAndPendingClearKeepsCredential() = runBlocking { fixture { context, directory ->
		val token = "synthetic-session-token"
		val value = pending(); val store = AndroidSessionStore(context)
		store.saveToken(token); store.savePendingAuth(value)
		val originalCredential = File(directory, "credential").readBytes()
		val reopened = AndroidSessionStore(context)
		assertEquals(value, reopened.loadPendingAuth()); assertEquals(token, reopened.loadToken())
		val bytes = File(directory, "pending-auth").readBytes().decodeToString()
		assertFalse(bytes.contains(value.verifier)); assertFalse(bytes.contains(value.state))
		reopened.clearPendingAuth()
		assertNull(reopened.loadPendingAuth()); assertEquals(token, reopened.loadToken())
		assertArrayEquals(originalCredential, File(directory, "credential").readBytes())
	} }

	@Test fun tamperIsRejectedAndPreservedUntilExplicitPendingClear() = runBlocking { fixture { context, directory ->
		val store = AndroidSessionStore(context); store.saveToken("synthetic-session-token"); store.savePendingAuth(pending())
		val file = File(directory, "pending-auth")
		val damaged = file.readBytes().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }; file.writeBytes(damaged)
		try { store.loadPendingAuth(); fail("Tampered pending state accepted") } catch (_: IOException) { }
		try { store.savePendingAuth(pending()); fail("Unreadable pending state overwritten") } catch (_: IOException) { }
		assertArrayEquals(damaged, file.readBytes())
		store.clearPendingAuth(); val next = pending(); store.savePendingAuth(next)
		assertEquals(next, store.loadPendingAuth()); assertEquals("synthetic-session-token", store.loadToken())
	} }

	@Test fun ciphertextCannotBeSwappedAcrossPurposesAndOversizedPendingStateCannotReplaceValidState() = runBlocking { fixture { context, directory ->
		val store = AndroidSessionStore(context); val value = pending()
		store.saveToken("synthetic-session-token"); store.savePendingAuth(value)
		val pendingBytes = File(directory, "pending-auth").readBytes()
		try { store.savePendingAuth(value.copy(authorizationURL = "x".repeat(64 * 1024))); fail("Oversized pending state accepted") } catch (_: IllegalArgumentException) { }
		assertArrayEquals(pendingBytes, File(directory, "pending-auth").readBytes())
		File(directory, "credential").writeBytes(pendingBytes)
		try { store.loadToken(); fail("Pending ciphertext accepted as session token") } catch (_: IOException) { }
		assertArrayEquals(pendingBytes, File(directory, "credential").readBytes())
	} }
}
