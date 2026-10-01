import Foundation

/// Flexible JSON shape for raw feed disclosure, including nested arrays and nulls.
public indirect enum JSONValue: Codable, Sendable, Equatable {
	case object([String: JSONValue])
	case array([JSONValue])
	case string(String)
	case number(Double)
	case bool(Bool)
	case null

	public init(from decoder: Decoder) throws {
		let value = try decoder.singleValueContainer()
		if value.decodeNil() { self = .null }
		else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
		else if let number = try? value.decode(Double.self) { self = .number(number) }
		else if let string = try? value.decode(String.self) { self = .string(string) }
		else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
		else { self = .object(try value.decode([String: JSONValue].self)) }
	}

	public func encode(to encoder: Encoder) throws {
		var value = encoder.singleValueContainer()
		switch self {
		case .object(let object): try value.encode(object)
		case .array(let array): try value.encode(array)
		case .string(let string): try value.encode(string)
		case .number(let number): try value.encode(number)
		case .bool(let bool): try value.encode(bool)
		case .null: try value.encodeNil()
		}
	}

	public var prettyPrinted: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
	}
}
