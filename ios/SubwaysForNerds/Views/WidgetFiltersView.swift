import SwiftUI
import TransitCore

struct WidgetFiltersView: View {
	@Environment(AppModel.self) private var app
	let station: Station
	private var preference: StationPreference { app.widgetPreferences.stations[station.id] ?? StationPreference(view: .direction) }
	var body: some View {
		List {
			Section {
				Button { app.clearWidgetRoutes(stationID: station.id) } label: {
					HStack { Text("All lines"); Spacer(); if preference.routes.isEmpty { Image(systemName: "checkmark") } }
				}.accessibilityIdentifier("widgetAllLines")
				ForEach(Array(Set(station.routes.map(Display.displayRoute))).sorted(), id: \.self) { route in
					Toggle(isOn: Binding(get: { preference.routes.contains(route) }, set: { app.setWidgetRoute(route, enabled: $0, stationID: station.id) })) {
						HStack { RouteBullet(route: route, small: true); Text("Line \(route)") }
					}.accessibilityIdentifier("widgetRoute_\(route)")
				}
			} header: { ListHeader("Widget lines") } footer: { Text("With no lines selected, all lines are shown. Both directions always stay visible.") }
			Section {
				Picker("Grouping", selection: Binding(get: { preference.view }, set: { app.setWidgetView($0, stationID: station.id) })) {
					ForEach(BoardSortOrder.allCases) { Text($0.title).tag($0) }
				}.accessibilityIdentifier("widgetGrouping")
			} footer: { Text("The smallest widgets show the next train in each direction. Larger widgets show more trains with your chosen grouping.") }
		}.themedList().navigationTitle(station.name).navigationBarTitleDisplayMode(.inline)
	}
}
