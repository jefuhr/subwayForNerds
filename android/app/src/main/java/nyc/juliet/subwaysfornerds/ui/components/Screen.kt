package nyc.juliet.subwaysfornerds.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** How a pushed screen leaves: back arrow for pushed details, close for full-screen tasks. */
enum class ScreenExit { NONE, BACK, CLOSE }

/**
 * A screen with a compact top bar and a lazily built grouped list. Pull to refresh is
 * offered only where the screen can actually request newer data.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListScreen(
	title: String,
	modifier: Modifier = Modifier,
	exit: ScreenExit = ScreenExit.NONE,
	onExit: () -> Unit = {},
	actions: @Composable RowScope.() -> Unit = {},
	onRefresh: (suspend () -> Unit)? = null,
	listState: LazyListState = rememberLazyListState(),
	tag: String? = null,
	windowInsets: WindowInsets = TopAppBarDefaults.windowInsets,
	content: LazyListScope.() -> Unit,
) {
	Scaffold(
		modifier = modifier,
		containerColor = palette.background,
		contentWindowInsets = WindowInsets(0, 0, 0, 0),
		topBar = {
			TopAppBar(
				title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.semantics { heading() }) },
				navigationIcon = {
					when (exit) {
						ScreenExit.BACK -> IconButton(onClick = onExit, modifier = Modifier.testTag("navigateBack")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
						ScreenExit.CLOSE -> IconButton(onClick = onExit, modifier = Modifier.testTag("closeScreen")) { Icon(Icons.Filled.Close, contentDescription = "Close") }
						ScreenExit.NONE -> {}
					}
				},
				actions = actions,
				windowInsets = windowInsets,
				colors = TopAppBarDefaults.topAppBarColors(
					containerColor = palette.background,
					scrolledContainerColor = palette.card,
					titleContentColor = palette.ink,
					navigationIconContentColor = palette.action,
					actionIconContentColor = palette.action,
				),
			)
		},
	) { padding ->
		val list = @Composable {
			// The tag names the scrolling list, so tests can scroll the screen to any row.
			LazyColumn(
				state = listState,
				modifier = if (tag != null) Modifier.fillMaxSize().testTag(tag) else Modifier.fillMaxSize(),
				contentPadding = PaddingValues(bottom = 24.dp),
				content = content,
			)
		}
		Box(Modifier.padding(padding).fillMaxSize()) {
			if (onRefresh != null) {
				val scope = rememberCoroutineScope()
				var refreshing by remember { mutableStateOf(false) }
				PullToRefreshBox(
					isRefreshing = refreshing,
					onRefresh = { scope.launch { refreshing = true; try { onRefresh() } finally { refreshing = false } } },
					modifier = Modifier.fillMaxSize(),
				) { list() }
			} else list()
		}
	}
}

/** A centered message for an empty list, like iOS ContentUnavailableView. */
@Composable
fun EmptyState(title: String, description: String?, modifier: Modifier = Modifier, extra: @Composable ColumnScope.() -> Unit = {}) {
	androidx.compose.foundation.layout.Column(
		modifier.padding(vertical = 12.dp).semantics(mergeDescendants = true) {},
		horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
		verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp),
	) {
		Text(title, style = nyc.juliet.subwaysfornerds.ui.theme.TextRoles.headline, color = palette.ink)
		description?.let { Text(it, style = nyc.juliet.subwaysfornerds.ui.theme.TextRoles.footnote, color = palette.muted, textAlign = androidx.compose.ui.text.style.TextAlign.Center) }
		extra()
	}
}
