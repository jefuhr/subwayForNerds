package nyc.juliet.subwaysfornerds.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import nyc.juliet.subwaysfornerds.SubwaysApplication
import nyc.juliet.subwaysfornerds.ui.account.AccountModel

/** Owns the app and account models for the activity's lifetime, across rotation and resizing. */
class AppViewModel(container: AppContainer) : ViewModel() {
	val model = AppModel(viewModelScope, container.dependencies())
	val account = AccountModel(viewModelScope, container.accountService(), container.sessionVault())

	companion object {
		val Factory: ViewModelProvider.Factory = viewModelFactory {
			initializer {
				val application = this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as SubwaysApplication
				AppViewModel(application.container)
			}
		}
	}
}
