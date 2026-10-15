package nyc.juliet.subwaysfornerds

import android.app.Application
import nyc.juliet.subwaysfornerds.ui.AppContainer

/**
 * Widget refresh work is scheduled by the widget receiver when widgets are placed or removed,
 * and again when settings change, so an app without widgets never polls.
 */
class SubwaysApplication : Application() {
	val container: AppContainer by lazy { AppContainer(this) }
}
