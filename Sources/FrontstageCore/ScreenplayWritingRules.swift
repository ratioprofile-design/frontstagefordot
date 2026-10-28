import Foundation

public enum ScreenplayCommandPlacement: String, Codable, Sendable { case inPlace, afterParagraph, split, suggestions, body }
public struct ScreenplayCommand: Equatable, Sendable {
    public let element: ScreenplayElement
    public let placement: ScreenplayCommandPlacement
    public init(element: ScreenplayElement, placement: ScreenplayCommandPlacement) { self.element = element; self.placement = placement }
    public static func resolve(element: ScreenplayElement, key: String, empty: Bool, selection: Bool = false) -> Self {
        if key == "CmdEnter" || key == "CtrlEnter" {
            return Self(element: .action, placement: .afterParagraph)
        }
        if key == "Backtab" { return Self(element: element.cycled(backward: true), placement: .inPlace) }
        if element == .sceneHeading && key == "Enter" { return Self(element: .action, placement: .body) }
        if key == "Tab" {
            switch element {
            case .action:
                return Self(element: .character, placement: .inPlace)
            case .character:
                return Self(element: .transition, placement: .inPlace)
            case .transition:
                return Self(element: .action, placement: .inPlace)
            case .dialogue:
                return Self(element: .parenthetical, placement: .inPlace)
            case .parenthetical:
                return Self(element: .dialogue, placement: .inPlace)
            default:
                return Self(element: .character, placement: .inPlace)
            }
        }
        if key == "Enter" {
            switch element {
            case .sceneHeading:
                return Self(element: .action, placement: .body)
            case .action:
                return Self(element: .action, placement: .split)
            case .character:
                return Self(element: empty ? .action : .dialogue, placement: empty ? .inPlace : .afterParagraph)
            case .dialogue:
                return Self(element: empty ? .action : .character, placement: empty ? .inPlace : .afterParagraph)
            case .parenthetical:
                return Self(element: empty ? .action : .dialogue, placement: empty ? .inPlace : .afterParagraph)
            case .transition:
                return Self(element: .sceneHeading, placement: .afterParagraph)
            case .shot:
                return Self(element: .action, placement: .afterParagraph)
            case .lyrics:
                return Self(element: .lyrics, placement: .split)
            }
        }
        let next: ScreenplayElement = element == .character && empty ? .action : element.afterReturn(isEmpty: empty)
        let placement: ScreenplayCommandPlacement = empty && element != .action && element != .lyrics ? .inPlace : [.character, .parenthetical, .transition, .shot].contains(element) ? .afterParagraph : .split
        return Self(element: next, placement: placement)
    }
}

public struct CharacterCue: Equatable, Sendable {
    public let name: String
    public let extensions: [String]
    public var hasContinuation: Bool { extensions.contains { Self.isContinuation($0) } }
    public var withoutContinuation: String { ([name] + extensions.filter { !Self.isContinuation($0) }).joined(separator: " ") }
    public static let voiceExtensions = [
        "(V.O.)",
        "(O.S.)",
        "(O.C.)",
        "(CONT'D)",
        "(INTO PHONE)",
        "(OVER PHONE)",
        "(PRE-LAP)",
        "(FILTERED)"
    ]
    public static let deliveryNotes = ["(beat)", "(quietly)", "(over the phone)", "(whispering)", "(to himself)", "(to herself)", "(into phone)"]
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    private static func isContinuation(_ text: String) -> Bool { normalized(text).hasPrefix("(CONT") }
    public init(_ source: String) {
        var remaining = source.trimmingCharacters(in: .whitespacesAndNewlines), suffixes: [String] = []
        let regex = try! NSRegularExpression(pattern: #"\s*\((?:V\.?O\.?|O\.?S\.?|O\.?C\.?|CONT['’]?D|CONT\.?|CONTINUED|OVER THE PHONE|ON THE PHONE)\)\s*$"#, options: .caseInsensitive)
        while let match = regex.firstMatch(in: remaining, range: NSRange(location: 0, length: remaining.utf16.count)) {
            let value = remaining as NSString
            suffixes.insert(value.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines), at: 0)
            remaining = value.substring(to: match.range.location)
        }
        name = Self.normalized(remaining); extensions = suffixes
    }
}

/// Last *spoken* cue, not the last name typed. Reset at each scene occurrence.
public struct DialogueContinuation: Sendable {
    public private(set) var lastSpeaker: String?
    private var cue: CharacterCue?
    public init(lastSpeaker: String? = nil) { self.lastSpeaker = lastSpeaker.map { CharacterCue($0).name } }
    @discardableResult public mutating func observe(_ element: ScreenplayElement, text: String) -> Bool {
        if element == .sceneHeading { lastSpeaker = nil; cue = nil; return false }
        if element == .character {
            let next = CharacterCue(text); cue = next
            return !next.name.isEmpty && next.name == lastSpeaker && !next.hasContinuation
        }
        if element == .dialogue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let cue, !cue.name.isEmpty { lastSpeaker = cue.name }
        if element != .dialogue && element != .parenthetical { cue = nil }
        return false
    }
}

public struct ScreenplayCompletion: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let values: [String]
    public init(start: Int, end: Int, values: [String]) { self.start = start; self.end = end; self.values = values }
}
public enum ScreenplayCompletionRules {
    private static func matches(_ choices: [String], _ typed: String) -> [String] {
        let prefix = CharacterCue.normalized(typed)
        var seen = Set<String>()
        return Array(choices.filter { value in
            let key = CharacterCue.normalized(value)
            return !key.isEmpty && key.hasPrefix(prefix) && key != prefix && seen.insert(key).inserted
        }.prefix(12))
    }
    public static func heading(_ source: String, caret: Int, headings: [SceneHeading]) -> ScreenplayCompletion {
        let text = source as NSString, offset = max(0, min(caret, text.length))
        let prefixRegex = try! NSRegularExpression(pattern: #"^(INT\./EXT\.|EXT\./INT\.|INT\.|EXT\.|I/E\.)(\s+)"#, options: .caseInsensitive)
        let prefix = prefixRegex.firstMatch(in: source, range: NSRange(location: 0, length: text.length))
        let separator = SceneHeading.finalSeparator(in: source).map { NSRange($0, in: source) }
        var start = 0, end = prefix?.range(at: 1).length ?? text.rangeOfCharacter(from: .whitespacesAndNewlines).location
        var choices = ["INT.", "EXT.", "INT./EXT.", "EXT./INT.", "I/E."]
        if let separator, offset >= NSMaxRange(separator) { start = NSMaxRange(separator); end = text.length; choices = SceneHeading.timeSuggestions }
        else if let prefix, offset >= NSMaxRange(prefix.range) { start = NSMaxRange(prefix.range); end = separator?.location ?? text.length; choices = headings.map { CharacterCue.normalized($0.location) } }
        if end == NSNotFound { end = text.length }
        let typed = text.substring(with: NSRange(location: start, length: max(0, offset - start)))
        return ScreenplayCompletion(start: start, end: max(start, end), values: matches(choices, typed))
    }
    public static func character(_ source: String, caret: Int, names: [String]) -> ScreenplayCompletion {
        let text = source as NSString, offset = max(0, min(caret, text.length)), before = text.substring(to: offset)
        if let open = before.range(of: "(", options: .backwards), !before[..<open.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            let start = NSRange(open, in: before).location
            let close = text.range(of: ")", range: NSRange(location: offset, length: text.length - offset))
            return ScreenplayCompletion(start: start, end: close.location == NSNotFound ? text.length : NSMaxRange(close), values: matches(CharacterCue.voiceExtensions, text.substring(with: NSRange(location: start, length: offset - start))))
        }
        let open = text.range(of: "(").location
        var end = open == NSNotFound ? text.length : open
        while end > 0, let scalar = UnicodeScalar(text.character(at: end - 1)), CharacterSet.whitespaces.contains(scalar) { end -= 1 }
        return ScreenplayCompletion(start: 0, end: end, values: matches(names.map { CharacterCue($0).name }, before))
    }
    public static func parenthetical(_ source: String) -> ScreenplayCompletion {
        ScreenplayCompletion(start: 0, end: source.utf16.count, values: matches(CharacterCue.deliveryNotes, source))
    }
}
