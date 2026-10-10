import Foundation
import TransitCore

@main
struct NativeAccountChoicesTests {
	static func main() throws {
		let base = PortableSettings()
		var local = base; local.theme = "night"
		var remote = base; remote.theme = "paper"
		let theme = try SettingsMerge.merge(base: base, local: local, remote: remote).conflicts[0]
		var choices = AccountConflictChoices()
		try expect(choices.resolved(for: [theme]) == nil, "A conflict requires an explicit selection")
		choices.select("remote", for: theme)
		try expect(choices.resolved(for: [theme]) == ["/theme": "remote"], "An explicit account choice must be preserved")
		choices.select("", for: theme)
		try expect(choices.resolved(for: [theme]) == nil, "Returning to the placeholder must disable resolution")
		try expect(!AccountConflictChoices.isExplicit("unexpected"), "Unknown choices must not silently mean local")
		print("PASS: conflict resolution requires an explicit local or account selection")

		choices.select("local", for: theme)
		var changedLocal = theme; changedLocal.local = .string("ocean")
		var changedRemote = theme; changedRemote.remote = .string("ocean")
		try expect(choices.selection(for: changedLocal).isEmpty, "A choice for a previous device value must expire")
		try expect(choices.resolved(for: [changedRemote]) == nil, "A choice for a previous account value must expire")
		var filter = theme; filter.path = "/stations/602/direction"; filter.local = .string("NORTH"); filter.remote = .string("SOUTH")
		try expect(choices.resolved(for: [theme, filter]) == nil, "Every conflict needs its own choice")
		choices.select("remote", for: filter)
		try expect(choices.resolved(for: [theme, filter]) == [theme.path: "local", filter.path: "remote"], "Independent choices must be retained")
		choices = AccountConflictChoices()
		try expect(choices.resolved(for: [theme]) == nil, "A later conflict round must require a fresh choice")
		print("PASS: selections expire when either value changes or a conflict round finishes")
	}

	private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
		if !condition() { throw NSError(domain: "NativeAccountChoicesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
	}
}
