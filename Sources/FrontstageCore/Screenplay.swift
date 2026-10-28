import Foundation

public enum ScreenplayElement: String, CaseIterable, Codable, Sendable {
    case action, character, dialogue, parenthetical, transition, shot, lyrics
    case sceneHeading = "slugline"

    public static let ordered: [Self] = [.sceneHeading, .action, .character, .dialogue, .parenthetical, .transition, .shot, .lyrics]
    public static let editable: [Self] = ordered
    public var label: String { self == .sceneHeading ? "Scene Heading" : rawValue.capitalized }
    public var keepsWithNext: Bool { [.sceneHeading, .character, .parenthetical].contains(self) }

    public func afterReturn(isEmpty: Bool) -> Self {
        switch self {
        case .character, .parenthetical: return .dialogue
        case .dialogue: return isEmpty ? .action : .character
        case .transition: return .sceneHeading
        case .lyrics: return .lyrics
        default: return .action
        }
    }

    public func cycled(backward: Bool = false) -> Self {
        let index = Self.editable.firstIndex(of: self) ?? 0
        return Self.editable[(index + (backward ? Self.editable.count - 1 : 1)) % Self.editable.count]
    }
}

public struct SceneHeading: Equatable, Sendable {
    public var prefix: String
    public var location: String
    public var time: String

    public init(prefix: String = "INT.", location: String = "", time: String = "DAY") {
        self.prefix = prefix
        self.location = location
        self.time = time
    }

    public var text: String {
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix) \(place.isEmpty ? "UNTITLED SCENE" : place) - \(time)".uppercased()
    }
}

public enum ScreenplayPaper: String, CaseIterable, Sendable {
    case letter, a4
    public var label: String { self == .letter ? "US Letter" : "A4" }
    public var width: Double { self == .letter ? 612 : 595.2756 }
    public var height: Double { self == .letter ? 792 : 841.8898 }
    public var leftMargin: Double { 108 }
    public var rightMargin: Double { 72 }
    public var topMargin: Double { 72 }
    public var bottomMargin: Double { 72 }
    public var contentWidth: Double { width - leftMargin - rightMargin }
    public var contentHeight: Double { height - topMargin - bottomMargin }
}
