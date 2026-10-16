package nyc.juliet.subwaysfornerds.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.ByteCounts
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.counted
import nyc.juliet.subwaysfornerds.ui.fleet.SwitchRow
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** App storage, network signal, memory and device health, read when the screen opens and on request. */
@Composable
fun SystemStatusScreen(model: AppModel, exit: ScreenExit, close: () -> Unit) {
	LaunchedEffect(Unit) { model.refreshSystemStatus() }
	val status = model.systemStatus
	val storage = status.storage
	val memory = status.memory
	val network = model.deviceNetworkStatus
	val manifest = model.fleet.offlineManifest
	val fleetBytes = maxOf(storage.fleetBytes, manifest?.byteLength ?: 0L)
	ListScreen("System status", exit = exit, onExit = close, tag = "systemStatusScreen") {
		section(
			"storage", header = "App storage",
			footer = "Settings include your account session and interface choices. Android may clear temporary cache when space runs low; offline boards and the fleet download stay until removed.",
		) {
			row { RowContainer { LabeledValue("Total app storage", ByteCounts.file(storage.totalAppBytes), Modifier.testTag("systemStatusTotalStorage")) } }
			val shares = listOf(storage.appFraction, storage.settingsFraction, storage.cacheFraction, storage.fraction(fleetBytes))
			if (storage.totalAppBytes > 0) row { RowContainer { StorageBar(shares) } }
			row { StorageRow("App (APK)", ByteCounts.file(storage.appApkBytes), StorageKind.APP, "systemStatusAppApkStorage") }
			row { StorageRow("Settings", ByteCounts.file(storage.settingsBytes), StorageKind.SETTINGS, "systemStatusSettingsStorage") }
			row {
				val usage = model.offlineUsage
				val offline = usage?.let { "${it.boardCount} boards · ${it.tripCount} trips · ${it.savedTripCount} saved" } ?: "Offline boards and trips"
				StorageRow(
					"Cache", ByteCounts.file(storage.cacheBytes), StorageKind.CACHE, "systemStatusCacheStorage",
					caption = "$offline: ${ByteCounts.file(storage.transitCacheBytes)} · Widgets: ${ByteCounts.file(storage.widgetCacheBytes)} · Temporary: ${ByteCounts.file(storage.httpCacheBytes)}",
				)
			}
			row {
				StorageRow(
					"Downloaded fleet", ByteCounts.file(fleetBytes), StorageKind.FLEET, "systemStatusFleetStorage",
					caption = manifest?.let { "${counted(it.counts.cars)} cars · ${counted(it.counts.events)} movement events" } ?: "Not downloaded",
				)
			}
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("Available on device", storage.deviceFreeBytes?.let(ByteCounts::file) ?: "Unknown", Modifier.testTag("systemStatusDeviceFreeStorage"))
						storage.deviceTotalBytes?.let { Text("of ${ByteCounts.file(it)} total", style = TextRoles.caption, color = palette.muted) }
					}
				}
			}
		}
		section("network", header = "Network", footer = "Signal and link speed are the system's own estimates, not a speed test. Response time is the last complete board, train or station list request.") {
			row {
				RowContainer {
					Column(Modifier.testTag("deviceNetworkStatus").semantics(mergeDescendants = true) {}) {
						Text(model.deviceNetworkHeadline, style = TextRoles.subheadline.copy(fontWeight = FontWeight.SemiBold))
						Text(network.linkFacts.joinToString(" · "), style = TextRoles.caption, color = palette.muted)
					}
				}
			}
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("Signal strength", network.signalStrengthLabel, Modifier.testTag("systemStatusNetworkStrength"))
						LabeledValue("Interface", network.transportLabel ?: "None")
						network.bandwidthLabel?.let { LabeledValue("Link speed", it, Modifier.testTag("systemStatusLinkSpeed")) }
						model.lastApiLatencyMs?.let { LabeledValue("Server response time", "${counted(it)} ms", Modifier.testTag("systemStatusLatency")) }
					}
				}
			}
			row {
				RowContainer {
					Column(Modifier.testTag("systemStatusRefreshActivity").semantics(mergeDescendants = true) {}) {
						val inFlight = model.fetchProgress.size
						LabeledValue("Automatic refreshes", if (model.connected) "Active" else "Paused")
						Text(
							"${model.plannedRequestCount} boards and trips tracked" + (if (inFlight > 0) " · $inFlight downloading" else "") + " · " + model.deviceNetworkDetail,
							style = TextRoles.caption, color = palette.muted,
						)
					}
				}
			}
			row { SwitchRow("Simulate no connection", model.outageSimulated, { model.setSimulatedOutage(it) }, Modifier.testTag("simulateOutage")) }
		}
		section("memory", header = "Memory", footer = "App RAM is the process's total footprint. Android updates it at most every few minutes.") {
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("App RAM used", ByteCounts.file(memory.appRamBytes), Modifier.testTag("systemStatusRamUsed"))
						Text(
							"Java heap ${ByteCounts.file(memory.jvmUsedBytes)} of ${ByteCounts.file(memory.jvmMaxBytes)} · Native heap ${ByteCounts.file(memory.nativeAllocatedBytes)}",
							style = TextRoles.caption, color = palette.muted,
						)
					}
				}
			}
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("Device RAM available", memory.deviceAvailableBytes?.let(ByteCounts::file) ?: "Unknown", Modifier.testTag("systemStatusDeviceRam"))
						val total = memory.deviceTotalBytes?.let { "of ${ByteCounts.file(it)} total" }
						Text(listOfNotNull(total, if (memory.lowMemory) "Low memory" else "Memory normal").joinToString(" · "), style = TextRoles.caption, color = if (memory.lowMemory) palette.danger else palette.muted)
					}
				}
			}
		}
		section("device", header = "Device") {
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("Thermal state", status.thermalStatus, Modifier.testTag("systemStatusThermalState"))
						LabeledValue("Battery Saver", if (status.powerSaveMode) "On" else "Off", Modifier.testTag("systemStatusPowerSave"))
						LabeledValue("Station catalog", "${counted(model.stations.size)} stations", Modifier.testTag("systemStatusStations"))
						LabeledValue("Server", model.endpoint)
						LabeledValue("App version", status.appVersion.ifEmpty { "—" }, Modifier.testTag("systemStatusAppVersion"))
						LabeledValue("Android version", status.androidVersion.ifEmpty { "—" })
					}
				}
			}
			row { ActionButton(if (model.refreshingSystemStatus) "Refreshing…" else "Refresh status", { model.launch { model.refreshSystemStatus() } }, Modifier.padding(start = 4.dp).testTag("refreshSystemStatus"), enabled = !model.refreshingSystemStatus) }
		}
	}
}

/** One storage category with the swatch that marks its share of the bar. */
@Composable
private fun StorageRow(title: String, value: String, kind: StorageKind, tag: String, caption: String? = null) {
	RowContainer {
		Row(Modifier.semantics(mergeDescendants = true) {}.testTag(tag), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
			Box(Modifier.size(10.dp).clip(CircleShape).background(kind.color))
			Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
				// Not LabeledValue: its own merged semantics would hide the value from this row's.
				Row(Modifier.fillMaxWidth()) {
					Text(title, style = TextRoles.subheadline, modifier = Modifier.weight(1f))
					Text(value, style = TextRoles.subheadline, color = palette.muted)
				}
				caption?.let { Text(it, style = TextRoles.caption, color = palette.muted) }
			}
		}
	}
}

/** Storage categories in bar order, each with the swatch color that marks it. */
private enum class StorageKind(val label: String) {
	APP("App"), SETTINGS("Settings"), CACHE("Cache"), FLEET("Downloaded fleet");

	val color: Color @Composable get() = when (this) {
		APP -> palette.muted
		SETTINGS -> palette.warning
		CACHE -> palette.selection
		FLEET -> palette.accent
	}
}

/** Each category's share of the app's storage, in [StorageKind] order; tiny shares still get a sliver. */
@Composable
private fun StorageBar(shares: List<Double>) {
	val shown = StorageKind.entries.zip(shares).filter { it.second > 0 }
	val spoken = shown.joinToString(", ") { (kind, share) -> "${kind.label} ${Math.round(share * 100)}%" }
	Row(
		Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp)).background(palette.line)
			.semantics { contentDescription = "Storage breakdown: $spoken" }.testTag("systemStatusStorageBar"),
		horizontalArrangement = Arrangement.spacedBy(2.dp),
	) {
		shown.forEach { (kind, share) -> Box(Modifier.weight(share.coerceAtLeast(0.01).toFloat()).fillMaxHeight().background(kind.color)) }
	}
}
