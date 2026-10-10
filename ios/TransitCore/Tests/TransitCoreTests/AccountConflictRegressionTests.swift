import Testing
@testable import TransitCore

struct AccountConflictRegressionTests {
	@Test(arguments: ["", "unexpected", "LOCAL", "REMOTE"])
	func invalidChoicesLeaveConflictsUnresolved(choice: String) throws {
		let base = PortableSettings()
		var local = base; local.theme = "night"
		var remote = base; remote.theme = "paper"
		let result = try SettingsMerge.merge(base: base, local: local, remote: remote, choices: ["/theme": choice])
		#expect(result.conflicts.map(\.path) == ["/theme"])
		#expect(result.settings.theme == "night")
	}

	@Test(arguments: ["local", "remote"])
	func explicitChoicesResolveThePresentedConflict(choice: String) throws {
		let base = PortableSettings()
		var local = base; local.theme = "night"
		var remote = base; remote.theme = "paper"
		let result = try SettingsMerge.merge(base: base, local: local, remote: remote, choices: ["/theme": choice])
		#expect(result.conflicts.isEmpty)
		#expect(result.settings.theme == (choice == "remote" ? "paper" : "night"))
	}
}
