package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CombinedBoardWarningsTest {
	private val now = 1_800_000_000.0
	private fun station(id: String, departureMode: String? = null) = Station(id, id.replaceFirstChar { it.uppercase() }, "M", listOf("A"), 40.7, -74.0, departureMode = departureMode)
	private fun board(station: Station) = Board(station, now, listOf(SourceState("feed", now - 10, now, null)))
	private val one = station("one")
	private val two = station("two")
	private val three = station("three")
	private val tools = station("tools", departureMode = "external")
	private val combined = CombinedBoards.station("combined:test", "All", listOf("one", "two", "three", "tools"), listOf(one, two, three, tools))!!

	@Test fun savedMembersWarnByDefaultAndCanBeLeftOut() {
		val merged = CombinedBoards.merge(combined, listOf(MemberBoardSnapshot(one, board(one), cached = true), MemberBoardSnapshot(two, board(two), cached = true)))
		// The widget wording uses the full list, so it must not change.
		assertEquals(listOf("One: Saved departures · offline estimates", "Two: Saved departures · offline estimates"), merged.warnings)
		assertTrue("A fully cached combined board has nothing left to warn about", merged.warnings(includeSaved = false).isEmpty())
	}

	@Test fun leavingOutSavedKeepsMembersWithoutABoardAndOfficialToolsMembers() {
		val merged = CombinedBoards.merge(combined, listOf(
			MemberBoardSnapshot(one, board(one), cached = true),
			MemberBoardSnapshot(two, null, error = "No saved board"),
			MemberBoardSnapshot(three, null),
			MemberBoardSnapshot(tools, board(tools), cached = true),
		))
		assertEquals(
			listOf("Two: No saved board", "Three: Departures unavailable", "Tools: Use official departure tools"),
			merged.warnings(includeSaved = false),
		)
	}

	@Test fun aCachedMemberWithABoardIsSilentEvenAfterAFailedRefresh() {
		// The combined equivalent of a failed refresh over a saved board: the saved board speaks for itself.
		val merged = CombinedBoards.merge(combined, listOf(MemberBoardSnapshot(one, board(one), cached = true, error = "Feed unavailable"), MemberBoardSnapshot(two, board(two))))
		assertTrue(merged.warnings(includeSaved = false).isEmpty())
		// Widgets and other full wording still report it.
		assertEquals(listOf("One: Feed unavailable"), merged.warnings)
		assertEquals(merged.warnings, merged.warnings(includeSaved = true))
	}

	@Test fun aFailedLiveMemberStillWarns() {
		val merged = CombinedBoards.merge(combined, listOf(MemberBoardSnapshot(one, board(one), cached = false, error = "Feed unavailable")))
		assertEquals(listOf("One: Feed unavailable"), merged.warnings(includeSaved = false))
	}

	@Test fun liveMembersNeverWarnEitherWay() {
		val merged = CombinedBoards.merge(combined, listOf(MemberBoardSnapshot(one, board(one)), MemberBoardSnapshot(two, board(two))))
		assertTrue(merged.warnings.isEmpty())
		assertTrue(merged.warnings(includeSaved = false).isEmpty())
	}
}
