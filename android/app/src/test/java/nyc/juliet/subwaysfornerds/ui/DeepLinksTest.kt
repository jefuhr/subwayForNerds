package nyc.juliet.subwaysfornerds.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeepLinksTest {
	@Test fun acceptsTheExactWidgetAndAuthLinks() {
		assertEquals(DeepLink.Station("602"), DeepLinks.parse("subwaynerds://board?station=602"))
		assertEquals(DeepLink.Station("combined:6d9542db-9ab7-422e-9548-fd66c1d4a384"), DeepLinks.parse("subwaynerds://board?station=combined%3A6d9542db-9ab7-422e-9548-fd66c1d4a384"))
		assertEquals(DeepLink.Ride("gtfs-l|20260905|122300_L..N|"), DeepLinks.parse("subwaynerds://ride?key=gtfs-l%7C20260905%7C122300_L..N%7C"))
		val callback = "nyc.juliet.subwaysfornerds://auth/android?state=s&handoff=h"
		assertEquals(DeepLink.AuthCallback(callback), DeepLinks.parse(callback))
	}

	@Test fun rejectsAnythingAmbiguousOrUnbounded() {
		listOf(
			null, "", "https://board?station=602", "subwaynerds://other?station=602",
			"subwaynerds://board", "subwaynerds://board?station=", "subwaynerds://board?station=602&station=603",
			"subwaynerds://board?station=602&x=1", "subwaynerds://board?id=602", "subwaynerds://board/extra?station=602",
			"subwaynerds://user@board?station=602", "subwaynerds://board:8080?station=602", "subwaynerds://board?station=602#top",
			"subwaynerds://board?station=%20602", "subwaynerds://board?station=60%0A2", "subwaynerds://board?station=" + "1".repeat(129),
			"subwaynerds://ride?key=" + "k".repeat(513), "subwaynerds://ride?key=a b",
			"nyc.juliet.subwaysfornerds://auth/other?state=s", "nyc.juliet.subwaysfornerds://auth/android",
			"subwaynerds://board?station=602" + "&".repeat(3000),
		).forEach { link -> assertNull("$link should be ignored", DeepLinks.parse(link)) }
	}
}
