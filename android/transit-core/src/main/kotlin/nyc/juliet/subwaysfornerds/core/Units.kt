package nyc.juliet.subwaysfornerds.core

import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale
import kotlin.math.roundToInt

object Units {
	private fun metersPerUnit(unit: String): Double = when (unit) { "mi" -> 1609.344; "ft", "auto" -> 0.3048; "km" -> 1000.0; else -> 1.0 }
	private fun decimal(value: Double, digits: Int): String = BigDecimal.valueOf(value).setScale(digits, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
	fun distanceLabel(meters: Double, unit: String = "auto"): String {
		if (!meters.isFinite() || meters < 0) return "—"
		if (unit == "auto") return if (meters < 1000) "${meters.roundToInt()} m" else String.format(Locale.US, "%.1f km", meters / 1000)
		val value = meters / metersPerUnit(unit)
		return if (unit in listOf("mi", "km")) "${if (value > 0 && value < 0.01) "<0.01" else decimal(value, 2)} $unit" else "${value.roundToInt()} $unit"
	}
	fun radiusInput(feet: Int, unit: String = "auto"): String = decimal(feet * 0.3048 / metersPerUnit(unit), 8)
	fun radiusFeet(text: String, unit: String = "auto"): Int? {
		val input = text.trim(); if (!Regex("(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)").matches(input)) return null
		val value = input.toDoubleOrNull() ?: return null; val feet = value * metersPerUnit(unit) / 0.3048
		val tolerance = metersPerUnit(unit) / 0.3048 * 0.000000005 + 0.000000001
		return if (feet.isFinite() && feet >= 1 - tolerance && feet <= 26400 + tolerance) feet.roundToInt() else null
	}
	fun radiusLabel(feet: Int, unit: String = "auto"): String = if (unit == "auto") "${String.format(Locale.US, "%,d", feet)} ft · ${decimal(feet / 5280.0, 4)} mi" else "${radiusInput(feet, unit)} $unit"
	fun spokenName(unit: String): String = when (unit) { "mi" -> "miles"; "m" -> "meters"; "km" -> "kilometers"; else -> "feet" }
	fun shortTitle(unit: String): String = if (unit == "auto") "Auto" else unit
	fun radiusRangeDescription(unit: String): String = "Enter a distance from ${radiusInput(1, unit)} to ${radiusInput(26400, unit)} ${spokenName(unit)}."
}
