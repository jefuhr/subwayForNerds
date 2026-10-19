package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.ui.fixture
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoardLogicTest {
	private val board = TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))

	@Test fun theDegradedNoticeShowsOnlyOnALiveBoardWithAProblemSource() {
		assertTrue(BoardLogic.degradedNoticeVisible(board, degraded = true, cached = false))
		assertFalse("Nothing is degraded", BoardLogic.degradedNoticeVisible(board, degraded = false, cached = false))
		assertFalse("No board to be degraded", BoardLogic.degradedNoticeVisible(null, degraded = true, cached = false))
	}

	@Test fun aSavedBoardNeverShowsTheDegradedNotice() {
		// Saved boards always have stale sources, so the offline estimate card speaks for them.
		assertFalse(BoardLogic.degradedNoticeVisible(board, degraded = true, cached = true))
	}
}
