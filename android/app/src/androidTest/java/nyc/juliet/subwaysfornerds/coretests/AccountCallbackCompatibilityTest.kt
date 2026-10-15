package nyc.juliet.subwaysfornerds.coretests

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.AccountClient
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthCancelledException
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises Android's real URL decoder; the cancellation path never makes a request. */
@RunWith(AndroidJUnit4::class)
class AccountCallbackCompatibilityTest {
	@Test fun percentEncodedCancellationWorksOnTheMinimumAndroidVersion() = runBlocking {
		val now = 1_788_656_340.0
		val state = "a".repeat(43)
		val pending = AndroidAuthPending("google", "login", state, "v".repeat(43), "challenge",
			"https://example.test/api/v1/auth/android/start?challenge=challenge", now)
		val client = AccountClient("https://example.test/api/v1/", now = { now })
		try {
			client.exchangeAndroid("nyc.juliet.subwaysfornerds://auth/android?st%61te=%61${state.drop(1)}&error=cancell%65d", pending)
			fail("Cancellation callback was accepted as a completed sign-in")
		} catch (_: AuthCancelledException) {
			// Both encoded keys and values decoded without relying on API 33 methods.
		}
	}
}
