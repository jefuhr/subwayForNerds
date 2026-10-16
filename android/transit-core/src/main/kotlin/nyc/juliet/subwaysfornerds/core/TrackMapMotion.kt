package nyc.juliet.subwaysfornerds.core

import kotlin.math.atan2
import kotlin.math.hypot

/** A rail polyline measured by arc length, as the server measures motion progress. */
class TrackMapPolyline(val points: List<TrackMapPoint>) {
	private val lengths: DoubleArray = DoubleArray(points.size).also { lengths ->
		for (i in 1 until points.size) lengths[i] = lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
	}
	val length: Double get() = if (lengths.isEmpty()) 0.0 else lengths.last()

	fun pointAt(progress: Double): TrackMapPoint = pointAtDistance(progress.coerceIn(0.0, 1.0) * length)

	fun pointAtDistance(distance: Double): TrackMapPoint {
		val target = distance.coerceIn(0.0, length)
		for (i in 1 until points.size) if (lengths[i] >= target) {
			val span = lengths[i] - lengths[i - 1]
			val f = if (span > 0) (target - lengths[i - 1]) / span else 0.0
			return TrackMapPoint(points[i - 1].x + (points[i].x - points[i - 1].x) * f, points[i - 1].y + (points[i].y - points[i - 1].y) * f)
		}
		return points.last()
	}

	/**
	 * Direction of travel in radians (screen and page y grow downward), or null on zero-length rail. At a vertex
	 * this is the segment the train arrived on, the same rail its body trails along; at the start, the first.
	 */
	fun headingOrNull(progress: Double): Double? {
		if (length <= 0) return null
		val target = progress.coerceIn(0.0, 1.0) * length
		val index = (1 until points.size).firstOrNull { lengths[it] >= target && lengths[it] > lengths[it - 1] } ?: return null
		return atan2(points[index].y - points[index - 1].y, points[index].x - points[index - 1].x)
	}
	fun headingAt(progress: Double): Double = headingOrNull(progress) ?: 0.0

	/** The rail behind a head at [headDistance], [bodyLength] long, bending with the rail and never before its start. */
	fun trail(headDistance: Double, bodyLength: Double): List<TrackMapPoint> {
		val head = headDistance.coerceIn(0.0, length)
		val tail = (head - bodyLength).coerceAtLeast(0.0)
		val result = mutableListOf(pointAtDistance(tail))
		for (i in points.indices) if (lengths[i] > tail && lengths[i] < head) result += points[i]
		result += pointAtDistance(head)
		return result
	}
}

/**
 * Freshness re-evaluated on the device clock from the row's original evidence times and its source's health.
 * [holdSample] is set when the row's source reports an error: its motion is no longer trusted, so the server's
 * sampled point is shown instead of advancing.
 */
data class TrackMapEvidenceState(val freshness: TrackMapFreshness, val staleAt: Double?, val expiresAt: Double?, val holdSample: Boolean = false)

object TrackMapEvidence {
	/**
	 * The oldest of the vehicle observation, feed header and source clock decides, as on the server. A
	 * snapshot's generation or read time is never evidence, so a cached response ages normally. The
	 * server's verdict can be downgraded here but never upgraded. Evidence from beyond the device clock (past
	 * [TrackMapContract.CLOCK_SKEW_SECONDS]) or a non-finite clock is unavailable rather than live.
	 */
	fun evaluate(train: TrackMapTrain, sources: List<SourceState>, now: Double): TrackMapEvidenceState {
		val source = sources.firstOrNull { it.id == train.feed }
		val latest = now + TrackMapContract.CLOCK_SKEW_SECONDS
		fun trusted(time: Double?): Double? = time?.takeIf { it.isFinite() && it > 0 && it <= latest }
		val observed = trusted(train.observedAt)
		val sourceTime = trusted(source?.timestamp)
		val feedTime = trusted(train.feedTimestamp)
		if (!now.isFinite() || train.freshness == TrackMapFreshness.UNAVAILABLE || source == null || observed == null || sourceTime == null || feedTime == null) {
			return TrackMapEvidenceState(TrackMapFreshness.UNAVAILABLE, null, null)
		}
		val evidence = minOf(observed, sourceTime, feedTime)
		val staleAt = minOf(evidence + TrackMapContract.LIVE_SECONDS, train.staleAt ?: Double.POSITIVE_INFINITY)
		val expiresAt = minOf(evidence + TrackMapContract.EXPIRE_SECONDS, train.expiresAt ?: Double.POSITIVE_INFINITY)
		val freshness = when {
			train.staleAt == null || train.expiresAt == null || now >= expiresAt -> TrackMapFreshness.UNAVAILABLE
			now >= staleAt || source.error != null || train.freshness == TrackMapFreshness.STALE -> TrackMapFreshness.STALE
			else -> TrackMapFreshness.LIVE
		}
		return TrackMapEvidenceState(freshness, staleAt, expiresAt, holdSample = source.error != null)
	}
}

/** Where to draw one train now. `heading` is null when the rail direction is not known. */
data class TrackMapDisplay(val point: TrackMapPoint, val heading: Double?, val animating: Boolean, val path: TrackMapPolyline?, val distance: Double?)

object TrackMapMotionMath {
	/** Linear progress inside the server's window, clamped to its bounds. */
	fun progress(motion: TrackMapMotion, time: Double): Double {
		if (time <= motion.startTime || motion.endTime <= motion.startTime) return motion.fromProgress
		if (time >= motion.endTime) return motion.toProgress
		return motion.fromProgress + (motion.toProgress - motion.fromProgress) * ((time - motion.startTime) / (motion.endTime - motion.startTime))
	}

	/**
	 * Unavailable or unplaced rows are not drawn. With reduced motion, or while the row's source reports an
	 * error, the server's sampled point is shown as is.
	 * Otherwise motion advances on [now], but never past [motionClock] (the moment the connection dropped),
	 * the row's stale time or the server's end time.
	 */
	fun display(train: TrackMapTrain, evidence: TrackMapEvidenceState, now: Double, motionClock: Double, reducedMotion: Boolean): TrackMapDisplay? {
		if (evidence.freshness == TrackMapFreshness.UNAVAILABLE || train.placement == TrackMapPlacement.UNPLACED) return null
		val point = train.point ?: return null
		// Motion that runs backwards along its own rail has no meaningful direction; only the sampled point is shown.
		val motion = train.motion?.takeIf { it.toProgress >= it.fromProgress }
		if (motion == null || train.placement != TrackMapPlacement.TRACK) return TrackMapDisplay(point, null, false, null, null)
		val path = TrackMapPolyline(motion.points)
		if (reducedMotion || evidence.holdSample) return TrackMapDisplay(point, path.headingOrNull(motion.fromProgress), false, path, motion.fromProgress * path.length)
		val sample = minOf(now, motionClock, evidence.staleAt ?: now)
		val progress = progress(motion, sample)
		val animating = evidence.freshness == TrackMapFreshness.LIVE && sample == now && now < motion.endTime
		return TrackMapDisplay(path.pointAt(progress), path.headingOrNull(progress), animating, path, progress * path.length)
	}
}

/** Separate, distinct wording for which rail is known and where on it the train is. */
object TrackMapCertainty {
	fun track(train: TrackMapTrain): String {
		val code = train.trackCode?.takeIf { it.isNotBlank() }
		return when (train.trackBasis) {
			TrackMapTrackBasis.REPORTED -> if (code != null) "Track $code reported" else "Track reported"
			TrackMapTrackBasis.SCHEDULED -> if (code != null) "Track $code from schedule" else "Track from schedule"
			TrackMapTrackBasis.INFERRED -> if (code != null) "Track $code inferred" else "Track inferred"
			TrackMapTrackBasis.UNKNOWN -> "Track unknown"
		}
	}
	fun position(train: TrackMapTrain): String {
		val base = when (train.positionBasis) {
			TrackMapPositionBasis.REPORTED -> "Position reported"
			TrackMapPositionBasis.ESTIMATED -> "Position estimated"
			TrackMapPositionBasis.UNKNOWN -> "Position unknown"
		}
		return when (train.placement) {
			TrackMapPlacement.NEAR_STOP -> "$base · shown near station"
			TrackMapPlacement.UNPLACED -> "$base · not on map"
			TrackMapPlacement.TRACK -> base
		}
	}
	fun freshness(state: TrackMapEvidenceState): String = when (state.freshness) {
		TrackMapFreshness.LIVE -> "Live"
		TrackMapFreshness.STALE -> "Stale · motion stopped"
		TrackMapFreshness.UNAVAILABLE -> "Position unavailable"
	}
}
