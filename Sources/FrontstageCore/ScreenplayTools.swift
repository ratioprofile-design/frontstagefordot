import Foundation

public enum TamilTranscoder {
    /// Explicit conversion only: Bamini ASCII is indistinguishable from ordinary English.
    public static func baminiToUnicode(_ source: String) -> String {
        var result = source
        for (key, value) in BaminiMapping.pairs { result = result.replacingOccurrences(of: key, with: value) }
        return result.precomposedStringWithCanonicalMapping
    }
}

public struct ElementTypography: Codable, Equatable, Sendable {
    public var fontName: String?
    public var fontSize: Double?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isUppercase: Bool
    public var isTamil: Bool

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, isBold, isItalic, isUnderline, isUppercase, isTamil
    }

    public init(
        fontName: String? = nil,
        fontSize: Double? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isUppercase: Bool = false,
        isTamil: Bool = false
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isUppercase = isUppercase
        self.isTamil = isTamil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        self.fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        self.isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        self.isItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        self.isUnderline = try container.decodeIfPresent(Bool.self, forKey: .isUnderline) ?? false
        self.isUppercase = try container.decodeIfPresent(Bool.self, forKey: .isUppercase) ?? false
        self.isTamil = try container.decodeIfPresent(Bool.self, forKey: .isTamil) ?? false
    }
}

public struct ScriptLayoutSettings: Codable, Equatable, Sendable {
    public var fontName = "Courier"
    public var fontSize = 12.0
    public var lineHeight = 14.0
    public var paragraphSpacing = 10.0
    public var elements: [String: ElementTypography] = [:]

    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, lineHeight, paragraphSpacing, elements
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? "Courier"
        self.fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12.0
        self.lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 14.0
        self.paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 10.0
        self.elements = try container.decodeIfPresent([String: ElementTypography].self, forKey: .elements) ?? [:]
    }

    public func validate() throws {
        guard !fontName.isEmpty, fontName.count <= 120, fontSize.isFinite, (8...36).contains(fontSize),
              lineHeight.isFinite, (fontSize...60).contains(lineHeight), paragraphSpacing.isFinite, (0...48).contains(paragraphSpacing) else {
            throw ProjectError.invalidProject("invalid screenplay typography")
        }
        for (_, elem) in elements {
            if let f = elem.fontName {
                guard f.count <= 120 else { throw ProjectError.invalidProject("invalid element font name") }
            }
            if let s = elem.fontSize {
                guard s.isFinite, (8...36).contains(s) else { throw ProjectError.invalidProject("invalid element font size") }
            }
        }
    }

    public func effectiveFontName(for element: ScreenplayElement) -> String {
        if let name = elements[element.rawValue]?.fontName, !name.isEmpty { return name }
        return fontName
    }

    public func effectiveFontSize(for element: ScreenplayElement) -> Double {
        if let size = elements[element.rawValue]?.fontSize { return size }
        return fontSize
    }

    public func isBold(for element: ScreenplayElement) -> Bool {
        if let override = elements[element.rawValue]?.isBold { return override }
        return [.sceneHeading, .transition, .shot].contains(element)
    }

    public func isItalic(for element: ScreenplayElement) -> Bool {
        return elements[element.rawValue]?.isItalic ?? false
    }

    public func isUnderline(for element: ScreenplayElement) -> Bool {
        return elements[element.rawValue]?.isUnderline ?? false
    }

    public func isUppercase(for element: ScreenplayElement) -> Bool {
        if let override = elements[element.rawValue]?.isUppercase { return override }
        return [.sceneHeading, .character, .transition, .shot].contains(element)
    }

    public func isTamil(for element: ScreenplayElement) -> Bool {
        return elements[element.rawValue]?.isTamil ?? false
    }
}

public struct ParallelScriptRow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var left: String
    public var right: String
    public init(left: String = "", right: String = "") { id = UUID().uuidString; self.left = left; self.right = right }
}

extension Project {
    public mutating func setSceneTextLocked(_ id: Decimal, locked: Bool) throws { try editBeat(id) { $0["frontstageTextLocked"] = .bool(locked) } }
    public mutating func setScenePageStart(_ id: Decimal, newPage: Bool) throws { try editBeat(id) { $0["frontstagePageStart"] = .bool(newPage) } }
    public var scriptLayout: ScriptLayoutSettings {
        guard let value = state["frontstageScriptLayout"], let data = try? JSONEncoder().encode(value),
              let result = try? JSONDecoder().decode(ScriptLayoutSettings.self, from: data), (try? result.validate()) != nil else { return ScriptLayoutSettings() }
        return result
    }
    public mutating func setScriptLayout(_ layout: ScriptLayoutSettings) throws {
        try layout.validate()
        state["frontstageScriptLayout"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(layout))
    }
    public func parallelScript(sceneID: Decimal) -> [ParallelScriptRow] {
        guard let value = state["beats"]?.array?.first(where: { $0.object?["id"]?.decimal == sceneID })?.object?["frontstageParallel"],
              let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([ParallelScriptRow].self, from: data)) ?? []
    }
    public mutating func setParallelScript(sceneID: Decimal, rows: [ParallelScriptRow]) throws {
        guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ !$0.id.isEmpty }) else { throw ProjectError.invalidProject("duplicate parallel script rows") }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rows))
        try editBeat(sceneID) { $0["frontstageParallel"] = value }
    }
}
