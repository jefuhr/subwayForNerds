package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Departure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The predecessor rule includes all earlier boardable rows, across services on the same boarding place. */
class DeparturePredecessorsTest {
	private fun row(key: String) = Departure(
		key = key, tripKey = "trip-$key", route = "A", destination = "Inwood", direction = "NORTH", stopId = "A27N", partId = "A27",
		area = "Uptown", time = 1_800_000_000.0, pattern = "Express", patternSource = "reported", location = "", feed = "gtfs-ace",
		timestamp = 1_799_999_990.0, scheduledTrack = "1",
	)

	@Test fun predecessorsRespectDirectionPlatformEffectiveTrackAndBoardability() {
		val first = row("first")
		val otherTrack = row("other-track").copy(scheduledTrack = "2")
		val otherPlatform = row("other-platform").copy(partId = "A28")
		val otherDirection = row("other-direction").copy(direction = "SOUTH")
		val skipped = row("skipped").copy(relationship = "SKIPPED")
		val canceled = row("canceled").copy(relationship = "CANCELED")
		val actualTrack = row("actual-track").copy(scheduledTrack = "2", actualTrack = "1", route = "C")
		val rows = listOf(first, otherTrack, otherPlatform, otherDirection, skipped, canceled, actualTrack, row("last"))
		val expected = listOf(null, null, null, null, first, first, first, actualTrack)
		assertEquals(expected, rows.indices.map { DepartureFormat.previous(rows, it) })
		assertEquals(expected, DepartureFormat.predecessors(rows))
	}

	@Test fun unknownTrackAndCombinedOriginsStaySeparate() {
		val first = row("first").copy(scheduledTrack = null, partId = "3:6023:A27")
		val second = row("second").copy(scheduledTrack = null, partId = "3:6103:A27")
		val rows = listOf(first, second, first.copy(key = "third"))
		assertNull(DepartureFormat.previous(rows, 1))
		assertEquals(first, DepartureFormat.previous(rows, 2))
		assertEquals(listOf(null, null, first), DepartureFormat.predecessors(rows))
	}

	@Test fun allNonBoardableStatusesAndTheExpandedPrefixMatchTheOriginalRule() {
		val rows = (0 until 120).map { index -> row("$index").copy(
			direction = if (index % 3 == 0) "SOUTH" else "NORTH",
			partId = "origin-${index % 4}",
			scheduledTrack = if (index % 5 == 0) null else "${index % 2}",
			actualTrack = if (index % 7 == 0) "3" else null,
			relationship = listOf(null, "SKIPPED", "CANCELED", "DELETED", "NO_DATA")[index % 5],
		) }
		val actual = DepartureFormat.predecessors(rows)
		assertEquals(rows.indices.map { DepartureFormat.previous(rows, it) }, actual)
		assertEquals(actual.take(5), DepartureFormat.predecessors(rows.take(5)))
		assertEquals(emptyList<Departure?>(), DepartureFormat.predecessors(emptyList()))
	}

	@Test fun expandedGroupsReadEachSourceRowOnlyOnce() {
		val values = (0 until 1_000).map { row("$it") }
		var reads = 0
		val counted = object : AbstractList<Departure>() {
			override val size: Int get() = values.size
			override fun get(index: Int): Departure { reads += 1; return values[index] }
		}
		val previous = DepartureFormat.predecessors(counted)
		assertEquals(values.size, previous.size)
		assertEquals(values[998], previous.last())
		assertTrue("The predecessor pass should not scan each earlier prefix: $reads source reads", reads <= values.size * 2)
	}
}
