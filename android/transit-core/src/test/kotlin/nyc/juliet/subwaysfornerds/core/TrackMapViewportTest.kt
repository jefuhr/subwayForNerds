package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.*
import org.junit.Test

class TrackMapViewportTest {
	private val page = TrackMapPage(7344.0, 11540.6)

	@Test fun fitShowsTheWholePageCentredInsideThePadding() {
		val camera = TrackMapCamera.fit(page, 1080.0, 1500.0, padding = 20.0)
		assertEquals((1500.0 - 40) / 11540.6, camera.scale, 1e-12)
		assertEquals(page.width / 2, camera.centerX, 1e-9); assertEquals(page.height / 2, camera.centerY, 1e-9)
		val view = camera.viewport(1080.0, 1500.0)
		assertEquals(20.0, view.toScreen(TrackMapPoint(0.0, 0.0)).y, 1e-9)
		assertEquals(1480.0, view.toScreen(TrackMapPoint(0.0, page.height)).y, 1e-9)
		assertEquals(540.0, view.toScreen(TrackMapPoint(page.width / 2, 0.0)).x, 1e-9)
	}

	@Test fun topLeftPdfPointsRoundTripThroughScreenSpace() {
		val view = TrackMapCamera(1279.5367, 5997.2525, 2.0).viewport(400.0, 800.0)
		val screen = view.toScreen(TrackMapPoint(1279.5367, 5997.2525))
		assertEquals(200.0, screen.x, 1e-9); assertEquals(400.0, screen.y, 1e-9)
		// y grows downward on screen, exactly like the contract; no flip is applied.
		assertEquals(420.0, view.toScreen(TrackMapPoint(1279.5367, 6007.2525)).y, 1e-9)
		val back = view.toPage(37.0, 91.0)
		val again = view.toScreen(back); assertEquals(37.0, again.x, 1e-9); assertEquals(91.0, again.y, 1e-9)
	}

	@Test fun pinchZoomKeepsThePointUnderTheFingersFixed() {
		val start = TrackMapCamera(3000.0, 6000.0, 0.5)
		val focus = start.viewport(1000.0, 1000.0).toPage(250.0, 700.0)
		val zoomed = start.zoomed(3.0, 250.0, 700.0, 1000.0, 1000.0, page)
		assertEquals(1.5, zoomed.scale, 1e-12)
		val after = zoomed.viewport(1000.0, 1000.0).toScreen(focus)
		assertEquals(250.0, after.x, 1e-6); assertEquals(700.0, after.y, 1e-6)
	}

	@Test fun zoomAndPanStayWithinTheArtwork() {
		val fit = TrackMapCamera.fit(page, 1000.0, 1000.0)
		val out = fit.zoomed(0.01, 500.0, 500.0, 1000.0, 1000.0, page)
		assertEquals(TrackMapCamera.minScale(page, 1000.0, 1000.0), out.scale, 1e-12)
		val deep = fit.zoomed(1e6, 500.0, 500.0, 1000.0, 1000.0, page)
		assertEquals(TrackMapCamera.MAX_SCALE, deep.scale, 1e-12)
		val flung = TrackMapCamera(10.0, 10.0, 1.0).panned(50_000.0, 50_000.0, page)
		assertEquals(0.0, flung.centerX, 0.0); assertEquals(0.0, flung.centerY, 0.0)
		val other = TrackMapCamera(10.0, 10.0, 1.0).panned(-50_000.0, -50_000.0, page)
		assertEquals(page.width, other.centerX, 0.0); assertEquals(page.height, other.centerY, 0.0)
	}

	@Test fun rotationKeepsTheSameCentreAndScale() {
		val camera = TrackMapCamera(2349.6, 6691.8, 1.25)
		val portrait = camera.viewport(1080.0, 2200.0); val landscape = camera.viewport(2200.0, 1080.0)
		assertEquals(540.0, portrait.toScreen(TrackMapPoint(2349.6, 6691.8)).x, 1e-9)
		assertEquals(1100.0, landscape.toScreen(TrackMapPoint(2349.6, 6691.8)).x, 1e-9)
	}

	@Test fun tilesCoverOnlyTheVisibleAreaAndStayWithinTheMemoryBudget() {
		val camera = TrackMapCamera(3000.0, 6000.0, 2.0)
		val level = TrackMapTiles.level(camera.scale)
		assertTrue(TrackMapTiles.levelScale(level) >= camera.scale)
		val tiles = TrackMapTiles.visible(camera, 1080.0, 2200.0, page, level)
		assertTrue(tiles.isNotEmpty())
		val tilePoints = TrackMapTiles.TILE_PIXELS / TrackMapTiles.levelScale(level)
		val view = camera.viewport(1080.0, 2200.0)
		val topLeft = view.toPage(0.0, 0.0); val bottomRight = view.toPage(1080.0, 2200.0)
		for (tile in tiles) {
			assertTrue(tile.col * tilePoints < bottomRight.x && (tile.col + 1) * tilePoints > topLeft.x)
			assertTrue(tile.row * tilePoints < bottomRight.y && (tile.row + 1) * tilePoints > topLeft.y)
		}
		// The nearest tile to the centre renders first.
		val centre = tiles.first(); assertEquals((3000.0 / tilePoints).toInt(), centre.col); assertEquals((6000.0 / tilePoints).toInt(), centre.row)
		// A whole-page view never asks for more tiles than fit in the cache: it drops to a coarser level.
		val wide = TrackMapCamera.fit(page, 2560.0, 1600.0)
		val budget = TrackMapTiles.maxTiles(TrackMapTiles.cacheBytes(512L * 1_048_576L))
		val chosen = TrackMapTiles.levelWithin(wide, 2560.0, 1600.0, page, budget)
		assertTrue(TrackMapTiles.visible(wide, 2560.0, 1600.0, page, chosen).size <= budget)
		// The full 7344 x 11540 page is never one bitmap.
		assertTrue(TrackMapTiles.OVERVIEW_PIXELS < page.width)
	}

	@Test fun cacheBudgetIsBoundedForSmallAndLargeHeaps() {
		assertEquals(16L * 1_048_576L, TrackMapTiles.cacheBytes(64L * 1_048_576L))
		assertEquals(48L * 1_048_576L, TrackMapTiles.cacheBytes(4096L * 1_048_576L))
		assertEquals(48, TrackMapTiles.maxTiles(48L * 1_048_576L))
	}

	@Test fun tapsHitEveryMarkerWithinReachNearestFirst() {
		val hits = TrackMapHitTest.within(listOf("far" to TrackMapPoint(100.0, 100.0), "b" to TrackMapPoint(12.0, 0.0), "a" to TrackMapPoint(3.0, 4.0)), 0.0, 0.0, 24.0)
		assertEquals(listOf("a", "b"), hits)
	}

	@Test fun viewportSummaryIsRoundedSoGesturesAndRedrawsDoNotJitterIt() {
		val summary = TrackMapCamera(1279.5367, 5997.2525, 1.23456).summary()
		assertEquals(TrackMapViewportSummary(1280, 5997, 123), summary)
		assertEquals("Centre 1280, 5997 · zoom 123%", summary.description)
		assertEquals(summary, TrackMapCamera(1279.6, 5997.4, 1.2349).summary())
	}
}
