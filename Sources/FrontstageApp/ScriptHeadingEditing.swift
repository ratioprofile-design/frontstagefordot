#if os(macOS)
import AppKit
import FrontstageCore

/// Heading identity belongs to the paragraph, including a temporarily empty draft.
@MainActor
enum ScriptHeadingEditing {
    static let owner = NSAttributedString.Key("FrontstageBeatOwner")
    static let heading = NSAttributedString.Key("FrontstageSceneHeading")
    struct Context {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }
    struct Bookmark {
        let ownerID: String
        let isHeading: Bool
        let ordinal: Int
        let offset: Int
        let length: Int
        let affinity: NSSelectionAffinity
        let draft: String?
    }
    static func bookmark(_ text: NSTextView) -> Bookmark? {
        let source = text.attributedString(), selection = text.selectedRange()
        guard source.length > 0, selection.location <= source.length else { return nil }
        let pos = min(selection.location, max(0, source.length - 1))
        guard let id = source.attribute(owner, at: pos, effectiveRange: nil) as? String else { return nil }
        let isHeading = source.attribute(heading, at: pos, effectiveRange: nil) != nil
        var location = 0, ordinal = 0
        while location < source.length {
            let range = (source.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            if source.attribute(owner, at: location, effectiveRange: nil) as? String == id,
               (source.attribute(heading, at: location, effectiveRange: nil) != nil) == isHeading {
                if selection.location <= NSMaxRange(range) {
                    guard NSMaxRange(selection) <= NSMaxRange(range) else { return nil }
                    return Bookmark(ownerID: id, isHeading: isHeading, ordinal: ordinal, offset: selection.location - location, length: selection.length,
                                    affinity: text.selectionAffinity, draft: isHeading ? (source.string as NSString).substring(with: range) : nil)
                }
                ordinal += 1
            }
            location = NSMaxRange(range)
        }
        return nil
    }
    static func restore(_ bookmark: Bookmark, in text: NSMutableAttributedString, project: Project) -> NSRange? {
        var location = 0, ordinal = 0
        while location < text.length {
            let range = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            if text.attribute(owner, at: location, effectiveRange: nil) as? String == bookmark.ownerID,
               (text.attribute(heading, at: location, effectiveRange: nil) != nil) == bookmark.isHeading {
                if ordinal == bookmark.ordinal {
                    if let draft = bookmark.draft, let key = text.attribute(heading, at: location, effectiveRange: nil) as? String,
                       let id = Decimal(string: key), project.scenes.first(where: { $0.id == id })?.heading == SceneHeading(inline: draft) {
                        text.replaceCharacters(in: range, with: NSAttributedString(string: draft, attributes: text.attributes(at: location, effectiveRange: nil)))
                    }
                    let updated = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
                    let start = min(bookmark.offset, max(0, updated.length - 1))
                    return NSRange(location: location + start, length: min(bookmark.length, updated.length - start))
                }
                ordinal += 1
            }
            location = NSMaxRange(range)
        }
        return nil
    }
    static func context(in text: NSTextView, replacing selection: NSRange) -> Context? {
        let source = text.attributedString(), string = source.string as NSString
        guard source.length > 0, selection.location <= source.length, NSMaxRange(selection) <= source.length else { return nil }
        let pos = min(selection.location, max(0, source.length - 1))
        let range = string.paragraphRange(for: NSRange(location: pos, length: 0))
        guard NSMaxRange(selection) <= NSMaxRange(range), source.attribute(heading, at: range.location, effectiveRange: nil) != nil else { return nil }
        return Context(range: range, attributes: source.attributes(at: range.location, effectiveRange: nil))
    }
    static func repair(_ text: NSTextView, context: Context) {
        guard let storage = text.textStorage, context.range.location < storage.length else { return }
        let range = (storage.string as NSString).paragraphRange(for: NSRange(location: context.range.location, length: 0))
        var attributes: [NSAttributedString.Key: Any] = [.screenplayElement: ScreenplayElement.sceneHeading.rawValue]
        attributes[owner] = context.attributes[owner]; attributes[heading] = context.attributes[heading]
        storage.addAttributes(attributes, range: range)
    }
    /// Used by the hosted writing view so replacing all text keeps its paragraph
    /// attributes and deleting/selecting a heading newline cannot consume the body.
    static func replacement(_ value: Any, in text: NSTextView, range: NSRange) -> NSAttributedString? {
        guard !text.hasMarkedText(), let context = context(in: text, replacing: range) else { return nil }
        guard let raw = (value as? NSAttributedString)?.string ?? value as? String, raw != "\n" else { return nil }
        var string = raw.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
        if NSMaxRange(range) == NSMaxRange(context.range), (text.string as NSString).substring(with: context.range).hasSuffix("\n") { string += "\n" }
        return NSAttributedString(string: string, attributes: context.attributes)
    }
    static func synchronize(_ text: NSTextView, project: Project, excluding active: NSRange?) {
        guard !text.hasMarkedText(), let storage = text.textStorage else { return }
        var changes: [(NSRange, NSAttributedString)] = [], location = 0
        while location < storage.length {
            let range = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            if range != active, let key = storage.attribute(heading, at: location, effectiveRange: nil) as? String,
               let id = Decimal(string: key), let scene = project.scenes.first(where: { $0.id == id }) {
                let elem = storage.attribute(.screenplayElement, at: location, effectiveRange: nil) as? String
                let line = (storage.string as NSString).substring(with: range)
                if (elem != nil && elem != ScreenplayElement.sceneHeading.rawValue) || line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    storage.removeAttribute(heading, range: range)
                } else {
                    let value = scene.heading.inlineText + "\n"
                    if line != value {
                        changes.append((range, NSAttributedString(string: value, attributes: storage.attributes(at: location, effectiveRange: nil))))
                    }
                }
            }
            location = NSMaxRange(range)
        }
        guard !changes.isEmpty else { return }
        var selection = text.selectedRange()
        let affinity = text.selectionAffinity
        for (range, replacement) in changes.reversed() {
            func mapped(_ position: Int) -> Int {
                if position < range.location { return position }
                if position >= NSMaxRange(range) { return position + replacement.length - range.length }
                return range.location + min(position - range.location, max(0, replacement.length - 1))
            }
            let end = mapped(NSMaxRange(selection)), start = mapped(selection.location)
            storage.replaceCharacters(in: range, with: replacement)
            selection = NSRange(location: start, length: max(0, end - start))
        }
        text.setSelectedRange(selection, affinity: affinity, stillSelecting: false)
    }
}
#endif
