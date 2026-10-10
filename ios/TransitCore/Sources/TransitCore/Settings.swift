import Foundation

public struct PortableSettings: Codable, Sendable, Equatable {
	public var favorites: [String] = []
	public var theme = "subway"
	public var stations: [String: StationPreference] = [:]
	public var widgets = WidgetPreferences()
	public init() {}
	public static func == (lhs: PortableSettings, rhs: PortableSettings) -> Bool { (try? lhs.json()) == (try? rhs.json()) }
	public func validated() throws -> PortableSettings {
		let value = try json()
		guard try JSONEncoder().encode(value).count <= NerdsSettingsFile.maxBytes else { throw SettingsError.message("Settings files must be smaller than 1 MiB.") }
		try SettingsValidation.settings(value); return self
	}
	public func json() throws -> JSONValue {
		var normalized = self
		normalized.stations = stations.mapValues { var value = $0; value.routes.sort(); return value }
		normalized.widgets.stations = widgets.stations.mapValues { var value = $0; value.routes.sort(); return value }
		var value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(normalized))
		if case .object(var root) = value, case .object(var widgets) = root["widgets"], case .object(var display) = widgets["display"] {
			display["fields"] = .array(self.widgets.display.fields.map(\.rawValue).sorted().map(JSONValue.string))
			widgets["display"] = .object(display)
			if case .object(var lock) = widgets["lockScreen"], case .object(var lockDisplay) = lock["display"] {
				lockDisplay["fields"] = .array(self.widgets.lockScreen.display.fields.map(\.rawValue).sorted().map(JSONValue.string))
				lock["display"] = .object(lockDisplay); widgets["lockScreen"] = .object(lock)
			}
			root["widgets"] = .object(widgets); value = .object(root)
		}
		return value
	}
}
public struct NerdsSettingsFile: Codable, Sendable, Identifiable {
	public static let maxBytes = 1_048_576
	public var format = "subways-for-nerds"
	public var version = 1
	public var exportedAt: String
	public var lastStation: String
	public var settings: PortableSettings
	public var id: String { exportedAt }
	public init(settings: PortableSettings, lastStation: String) {
		self.settings = settings; self.lastStation = lastStation
		exportedAt = ISO8601DateFormatter().string(from: Date())
	}
	public static func decode(_ data: Data) throws -> NerdsSettingsFile {
		guard data.count <= maxBytes else { throw SettingsError.message("Settings files must be smaller than 1 MiB.") }
		guard String(data: data, encoding: .utf8) != nil else { throw SettingsError.invalid }
		let value = try JSONDecoder().decode(JSONValue.self, from: data)
		let root = try SettingsValidation.object(value, keys: ["format", "version", "exportedAt", "lastStation", "settings"])
		guard root["format"] == .string("subways-for-nerds") else { throw SettingsError.invalid }
		guard root["version"] == .number(1) else { throw SettingsError.message("This settings version is not supported. Update Subway Nerds and try again.") }
		let timestamp = try SettingsValidation.string(root["exportedAt"])
		let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
		guard formatter.date(from: timestamp) != nil || ISO8601DateFormatter().date(from: timestamp) != nil else { throw SettingsError.invalid }
		_ = try SettingsValidation.string(root["lastStation"])
		try SettingsValidation.settings(root["settings"])
		return try JSONDecoder().decode(Self.self, from: data)
	}
	public func data() throws -> Data {
		let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(self); _ = try Self.decode(data); return data
	}
}
public enum SettingsError: LocalizedError {
	case invalid, message(String)
	public var errorDescription: String? { switch self { case .invalid: "This is not a valid Subway Nerds settings file."; case .message(let message): message } }
}
private enum SettingsValidation {
	static func object(_ value: JSONValue?, keys: Set<String>? = nil) throws -> [String: JSONValue] {
		guard case .object(let result) = value, keys == nil || Set(result.keys) == keys else { throw SettingsError.invalid }; return result
	}
	static func string(_ value: JSONValue?) throws -> String {
		guard case .string(let result) = value, !result.isEmpty, result.utf16.count <= 128, !result.unicodeScalars.contains(where: { $0.value < 32 }) else { throw SettingsError.invalid }; return result
	}
	static func strings(_ value: JSONValue?, limit: Int = 2000) throws -> [String] {
		guard case .array(let values) = value, values.count <= limit else { throw SettingsError.invalid }
		let result = try values.map { try string($0) }; guard Set(result).count == result.count else { throw SettingsError.invalid }; return result
	}
	static func boolean(_ value: JSONValue?) throws { guard case .bool = value else { throw SettingsError.invalid } }
	static func stations(_ value: JSONValue?) throws {
		let map = try object(value); guard map.count <= 2000 else { throw SettingsError.invalid }
		for (key, value) in map {
			_ = try string(.string(key)); guard !["__proto__", "constructor", "prototype"].contains(key) else { throw SettingsError.invalid }
			let station = try object(value, keys: ["direction", "routes", "view"])
			guard ["ALL", "NORTH", "SOUTH", "TO_NY", "TO_NJ", "UNKNOWN"].contains(try string(station["direction"])), BoardSortOrder(rawValue: try string(station["view"])) != nil else { throw SettingsError.invalid }
			_ = try strings(station["routes"], limit: 128)
		}
	}
	static func settings(_ value: JSONValue?) throws {
		let root = try object(value, keys: ["favorites", "theme", "stations", "widgets"])
		_ = try strings(root["favorites"]); _ = try string(root["theme"]); try stations(root["stations"])
		let rawWidgets = try object(root["widgets"])
		let widgetKeys: Set<String> = rawWidgets["lockScreen"] == nil ? ["display", "matchAppFilters", "stations"] : ["display", "matchAppFilters", "stations", "lockScreen"]
		let widgets = try object(root["widgets"], keys: widgetKeys)
		try boolean(widgets["matchAppFilters"]); try stations(widgets["stations"])
		try display(widgets["display"])
		if let value = widgets["lockScreen"] {
			let lock = try object(value, keys: ["display", "directionOrder", "showService"])
			try display(lock["display"]); try boolean(lock["showService"])
			guard LockScreenDirectionOrder(rawValue: try string(lock["directionOrder"])) != nil else { throw SettingsError.invalid }
		}
	}
	static func display(_ value: JSONValue?) throws {
		let raw = try object(value)
		let keys: Set<String> = raw["refreshInterval"] == nil ? ["fields", "compact", "trainsPerDirection", "timeStyle"] : ["fields", "compact", "trainsPerDirection", "timeStyle", "refreshInterval"]
		let display = try object(value, keys: keys)
		if let interval = display["refreshInterval"] {
			guard case .number(let count) = interval, WidgetRefreshInterval.allCases.contains(where: { Double($0.rawValue) == count }) else { throw SettingsError.invalid }
		}
		try boolean(display["compact"])
		guard case .number(let count) = display["trainsPerDirection"], (0...8).contains(count), count.rounded() == count, WidgetTimeStyle(rawValue: try string(display["timeStyle"])) != nil else { throw SettingsError.invalid }
		guard try strings(display["fields"], limit: WidgetField.allCases.count).allSatisfy({ WidgetField(rawValue: $0) != nil }) else { throw SettingsError.invalid }
	}
}
public struct SettingsSyncState: Codable, Sendable {
	public var userID: String
	public var baseline: PortableSettings
	public var revision: Int
	public init(userID: String, baseline: PortableSettings, revision: Int) { self.userID = userID; self.baseline = baseline; self.revision = revision }
}
public struct DeviceSettings: Codable, Sendable {
	public var settings: PortableSettings
	public var lastStation: String
	public var recent: [String] = []
	public var endpoint: String?
	public var sync: SettingsSyncState?
	public init(settings: PortableSettings, lastStation: String) { self.settings = settings; self.lastStation = lastStation }
}
public struct DeviceSettingsStore: Sendable {
	public let fileURL: URL
	public init(fileURL: URL) { self.fileURL = fileURL }
	public func load() throws -> DeviceSettings? {
		guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
		let value = try JSONDecoder().decode(DeviceSettings.self, from: Data(contentsOf: fileURL))
		_ = try value.settings.validated(); return value
	}
	public func save(_ value: DeviceSettings) throws {
		_ = try value.settings.validated()
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
	}
}
public struct SettingsConflict: Identifiable, Sendable {
	public var path: String
	public var local: JSONValue?
	public var remote: JSONValue?
	public var id: String { path }
}
public struct SettingsMerge: Sendable {
	public var settings: PortableSettings
	public var conflicts: [SettingsConflict]
	public static func merge(base: PortableSettings, local: PortableSettings, remote: PortableSettings, choices: [String: String] = [:]) throws -> SettingsMerge {
		var conflicts: [SettingsConflict] = []
		func mergeValue(_ b: JSONValue?, _ l: JSONValue?, _ r: JSONValue?, _ path: String) -> JSONValue? {
			if l == r || b == r { return l }; if b == l { return r }
			if case .object(let left) = l, case .object(let right) = r {
				let prior: [String: JSONValue]?
				if case .object(let value) = b { prior = value } else { prior = b == nil ? [:] : nil }
				if let prior {
					var result: [String: JSONValue] = [:]
					for key in Set(prior.keys).union(left.keys).union(right.keys).sorted() {
						result[key] = mergeValue(prior[key], left[key], right[key], path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
					}; return .object(result)
				}
			}
			if let choice = choices[path] { return choice == "remote" ? r : l }
			conflicts.append(SettingsConflict(path: path, local: l, remote: r)); return l
		}
		var ids: [String] = []
		for id in remote.favorites + local.favorites + base.favorites where !ids.contains(id) { ids.append(id) }
		let favorites = ids.filter { mergeValue(.bool(base.favorites.contains($0)), .bool(local.favorites.contains($0)), .bool(remote.favorites.contains($0)), "/favorites/" + $0) == .bool(true) }
		var b = base, l = local, r = remote; b.favorites = []; l.favorites = []; r.favorites = []
		let merged = mergeValue(try b.json(), try l.json(), try r.json(), "")!
		var settings = try JSONDecoder().decode(PortableSettings.self, from: JSONEncoder().encode(merged)); settings.favorites = favorites
		return SettingsMerge(settings: try settings.validated(), conflicts: conflicts)
	}
	public static func changes(from: PortableSettings, to: PortableSettings) throws -> [SettingsConflict] {
		var changes: [SettingsConflict] = []
		func walk(_ a: JSONValue?, _ b: JSONValue?, _ path: String) {
			guard a != b else { return }
			if case .object(let left) = a, case .object(let right) = b {
				for key in Set(left.keys).union(right.keys).sorted() { walk(left[key], right[key], path.isEmpty ? key : path + " / " + key) }
			} else { changes.append(SettingsConflict(path: path, local: a, remote: b)) }
		}
		walk(try from.json(), try to.json(), ""); return changes
	}
}
