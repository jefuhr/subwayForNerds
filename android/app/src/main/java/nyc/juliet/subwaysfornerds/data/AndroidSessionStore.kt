package nyc.juliet.subwaysfornerds.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.TransitJson

/** AndroidKeyStore AES/GCM; the ciphertext is in noBackupFilesDir, never settings/exports. */
class AndroidSessionStore(context: Context) {
	private val storage = AtomicStorage(File(context.applicationContext.noBackupFilesDir, "session-v1"))
	private val alias = "${context.applicationContext.packageName}.session.v1"

	suspend fun loadToken(): String? = withContext(Dispatchers.IO) {
		storage.locked { loadTokenLocked() }
	}
	suspend fun saveToken(token: String) = withContext(Dispatchers.IO) {
		require(token.isNotEmpty() && token.toByteArray().size <= 8192 && token.none { it.code < 32 })
		storage.locked {
			loadTokenLocked() // A routine write never silently replaces an unreadable credential.
			storage.write("credential", encrypt(token.toByteArray(), "credential"))
		}
	}
	suspend fun loadPendingAuth(): AndroidAuthPending? = withContext(Dispatchers.IO) { storage.locked { loadPendingLocked() } }
	suspend fun savePendingAuth(pending: AndroidAuthPending) = withContext(Dispatchers.IO) {
		val bytes = TransitJson.encodeToString(pending).toByteArray()
		require(bytes.size <= 64 * 1024) { "Pending sign-in data exceeds its supported size." }
		storage.locked {
			loadPendingLocked()
			storage.write("pending-auth", encrypt(bytes, "pending-auth"))
		}
	}
	suspend fun clearPendingAuth() = withContext(Dispatchers.IO) { storage.locked { storage.delete("pending-auth") } }
	suspend fun clear() = withContext(Dispatchers.IO) {
		storage.locked {
			storage.delete("credential")
			storage.delete("pending-auth")
			// Delete only this application's session key, after deleting its ciphertext.
			KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
		}
	}
	private fun loadTokenLocked(): String? = storage.read("credential", 16_384)?.let { bytes ->
		try { decrypt(bytes, "credential", allowLegacyToken = true).decodeToString(throwOnInvalidSequence = true) }
		catch (error: Exception) { throw IOException("The saved session could not be unlocked. It has been preserved.", error) }
	}
	private fun loadPendingLocked(): AndroidAuthPending? = storage.read("pending-auth", 64 * 1024L + 64)?.let { bytes ->
		try { TransitJson.decodeFromString<AndroidAuthPending>(decrypt(bytes, "pending-auth").decodeToString(throwOnInvalidSequence = true)) }
		catch (error: Exception) { throw IOException("Pending sign-in data could not be unlocked. It has been preserved.", error) }
	}
	private fun encrypt(bytes: ByteArray, purpose: String): ByteArray {
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
		cipher.updateAAD(aad(purpose))
		return byteArrayOf(2) + cipher.iv + cipher.doFinal(bytes)
	}
	private fun decrypt(bytes: ByteArray, purpose: String, allowLegacyToken: Boolean = false): ByteArray {
		if (bytes.size < 30 || bytes[0] != 2.toByte() && !(allowLegacyToken && bytes[0] == 1.toByte())) throw IOException("Unsupported encrypted record.")
		val cipher = Cipher.getInstance("AES/GCM/NoPadding")
		cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
		// Existing v1 tokens remain readable; all new records bind their distinct purpose.
		cipher.updateAAD(if (bytes[0] == 1.toByte()) alias.toByteArray() else aad(purpose))
		return cipher.doFinal(bytes.copyOfRange(13, bytes.size))
	}
	private fun aad(purpose: String): ByteArray = "$alias\u0000$purpose\u0000v2".toByteArray()
	private fun key(create: Boolean): SecretKey {
		val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
		(store.getKey(alias, null) as? SecretKey)?.let { return it }
		if (!create) throw IOException("Session key is unavailable.")
		return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
			init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
				.setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
				.setRandomizedEncryptionRequired(true).setUnlockedDeviceRequired(true).build())
		}.generateKey()
	}
}
