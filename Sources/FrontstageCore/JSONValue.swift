import Foundation

/// Preserve unported fields instead of decoding a legacy project into a lossy subset.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Decimal.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }; return nil
    }
    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }; return nil
    }
    public var string: String? {
        if case .string(let value) = self { return value }; return nil
    }
    public var boolean: Bool? {
        if case .bool(let value) = self { return value }; return nil
    }

    /// Remove known legacy credential fields throughout an imported document.
    /// Unknown project fields otherwise remain intact. This is not a general secret scanner.
    public func removingLegacyCredentials() -> JSONValue {
        let names: Set<String> = [
            "geminiapikey", "openrouterkey", "openrouterapikey", "tokenrouterapikey",
            "apikey", "r2accesskeyid", "r2secretaccesskey", "vite_r2_access_key_id",
            "vite_r2_secret_access_key"
        ]
        switch self {
        case .object(let fields):
            return .object(fields.filter { !names.contains($0.key.lowercased()) }
                .mapValues { $0.removingLegacyCredentials() })
        case .array(let values): return .array(values.map { $0.removingLegacyCredentials() })
        default: return self
        }
    }
}
