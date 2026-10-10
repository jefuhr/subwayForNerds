import TransitCore

/// A selection belongs to the exact pair of values presented to the user.
struct AccountConflictChoices {
	private struct Selection {
		let value: String
		let local: JSONValue?
		let remote: JSONValue?
	}
	private var selections: [String: Selection] = [:]

	static func isExplicit(_ value: String?) -> Bool { value == "local" || value == "remote" }

	func selection(for conflict: SettingsConflict) -> String {
		guard let selection = selections[conflict.path], selection.local == conflict.local, selection.remote == conflict.remote else { return "" }
		return selection.value
	}

	mutating func select(_ value: String, for conflict: SettingsConflict) {
		guard Self.isExplicit(value) else { selections.removeValue(forKey: conflict.path); return }
		selections[conflict.path] = Selection(value: value, local: conflict.local, remote: conflict.remote)
	}

	func resolved(for conflicts: [SettingsConflict]) -> [String: String]? {
		var result: [String: String] = [:]
		for conflict in conflicts {
			let value = selection(for: conflict)
			guard Self.isExplicit(value) else { return nil }
			result[conflict.path] = value
		}
		return result
	}
}
