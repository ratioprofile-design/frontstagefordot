#if os(macOS)
import AppKit
import FrontstageCore

extension NSAttributedString.Key {
    static let screenplayElement = NSAttributedString.Key("design.ratioprofile.frontstage.element")
    static let screenplayDualDialogue = NSAttributedString.Key("design.ratioprofile.frontstage.dualDialogue")
    static let screenplayRevisionMark = NSAttributedString.Key("design.ratioprofile.frontstage.revisionMark")
}

@MainActor
enum ScreenplayTypography {
    static func attributes(_ element: ScreenplayElement, width: CGFloat,
                           printing: Bool = false, settings: ScriptLayoutSettings = .init(),
                           dualSide: String? = nil, isRevised: Bool = false) -> [NSAttributedString.Key: Any] {
        let fontName = settings.effectiveFontName(for: element)
        let fontSize = settings.effectiveFontSize(for: element)
        let isBold = settings.isBold(for: element)
        let isItalic = settings.isItalic(for: element)
        let isUnderline = settings.isUnderline(for: element)

        let isTamil = settings.isTamil(for: element)
        var resolvedFontName = fontName
        if isTamil && (settings.elements[element.rawValue]?.fontName == nil || fontName == settings.fontName) {
            resolvedFontName = NSFont(name: "InaiMathi", size: fontSize) != nil ? "InaiMathi" : "Tamil Sangam MN"
        }

        let paragraph = NSMutableParagraphStyle()
        let elemLineHeight = max(settings.lineHeight, isTamil ? fontSize * 1.45 : fontSize * 1.25)
        paragraph.minimumLineHeight = elemLineHeight
        paragraph.maximumLineHeight = elemLineHeight
        paragraph.paragraphSpacing = settings.paragraphSpacing

        let halfColWidth = max(140, (width - 24) / 2)
        if dualSide == "left" {
            switch element {
            case .character:
                paragraph.headIndent = halfColWidth * 0.28
                paragraph.tailIndent = -halfColWidth - 24
                paragraph.paragraphSpacing = 0
            case .dialogue:
                paragraph.headIndent = 0
                paragraph.tailIndent = -halfColWidth - 24
            case .parenthetical:
                paragraph.headIndent = halfColWidth * 0.12
                paragraph.tailIndent = -halfColWidth - 24
                paragraph.paragraphSpacing = 0
            default: break
            }
        } else if dualSide == "right" {
            let rightStart = halfColWidth + 24
            switch element {
            case .character:
                paragraph.headIndent = rightStart + halfColWidth * 0.28
                paragraph.tailIndent = 0
                paragraph.paragraphSpacing = 0
            case .dialogue:
                paragraph.headIndent = rightStart
                paragraph.tailIndent = 0
            case .parenthetical:
                paragraph.headIndent = rightStart + halfColWidth * 0.12
                paragraph.tailIndent = 0
                paragraph.paragraphSpacing = 0
            default: break
            }
        } else {
            switch element {
            case .character:
                paragraph.headIndent = width * WorkspaceDesign.characterIndent / 100
                paragraph.tailIndent = 0
                paragraph.paragraphSpacing = 0
            case .dialogue:
                paragraph.headIndent = width * WorkspaceDesign.dialogueIndent / 100
                paragraph.tailIndent = -width * WorkspaceDesign.dialogueIndent / 100
            case .parenthetical:
                paragraph.headIndent = width * WorkspaceDesign.parentheticalIndent / 100
                paragraph.tailIndent = -width * WorkspaceDesign.parentheticalRight / 100
                paragraph.paragraphSpacing = 0
            case .transition:
                paragraph.headIndent = width * 0.55
                paragraph.alignment = .right
                paragraph.paragraphSpacingBefore = 10
            case .sceneHeading, .shot:
                paragraph.paragraphSpacingBefore = 10
            default: break
            }
        }
        paragraph.firstLineHeadIndent = paragraph.headIndent

        let base = NSFont(name: resolvedFontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        var font = base
        var traits: NSFontTraitMask = []
        if isBold { traits.insert(.boldFontMask) }
        if isItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(base, toHaveTrait: traits)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: printing ? NSColor.black : NSColor.textColor,
            .screenplayElement: element.rawValue
        ]
        if let dualSide { attrs[.screenplayDualDialogue] = dualSide }
        if isRevised { attrs[.screenplayRevisionMark] = true }
        if isUnderline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    static func apply(_ element: ScreenplayElement, to text: NSMutableAttributedString,
                      range: NSRange, width: CGFloat, printing: Bool = false, settings: ScriptLayoutSettings = .init(),
                      dualSide: String? = nil, isRevised: Bool = false) {
        guard range.length > 0 else { return }
        let currentDual = dualSide ?? (text.attribute(.screenplayDualDialogue, at: range.location, effectiveRange: nil) as? String)
        let currentRev = isRevised || (text.attribute(.screenplayRevisionMark, at: range.location, effectiveRange: nil) as? Bool ?? false)
        let attributes = attributes(element, width: width, printing: printing, settings: settings, dualSide: currentDual, isRevised: currentRev)
        var fonts: [(NSRange, NSFontTraitMask)] = []
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { fonts.append((run, NSFontManager.shared.traits(of: font))) }
        }
        text.addAttributes(attributes, range: range)
        let base = attributes[.font] as! NSFont
        for (run, traits) in fonts {
            let emphasis = traits.intersection([.boldFontMask, .italicFontMask])
            if !emphasis.isEmpty {
                text.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: emphasis), range: run)
            }
        }
    }
}

/// AppKit renders HTML; temporary markers carry Backstage paragraph classes through its importer.
/// Mark only leaf blocks so a wrapper around multiple paragraphs never creates spurious blank lines.
@MainActor
enum ScreenplayTextCodec {
    struct BlockMeta {
        let type: ScreenplayElement
        let dual: String?
        let revised: Bool
    }

    static func decode(_ html: String, width: CGFloat = 432,
                       printing: Bool = false, settings: ScriptLayoutSettings = .init()) throws -> NSMutableAttributedString {
        let token = "FS\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_"
        let marked = markLeafBlocks(html, token: token)
        let text = try NSMutableAttributedString(data: Data(marked.html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
        let regex = try NSRegularExpression(pattern: "\(token)([0-9]+)END")
        let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        var events: [(Int, BlockMeta)] = []
        var removed = 0
        for match in matches {
            let key = (text.string as NSString).substring(with: match.range(at: 1))
            if let index = Int(key), marked.metas.indices.contains(index) {
                events.append((match.range.location - removed, marked.metas[index]))
            }
            removed += match.range.length
        }
        for match in matches.reversed() { text.deleteCharacters(in: match.range) }
        text.addAttribute(.screenplayElement, value: ScreenplayElement.action.rawValue,
                          range: NSRange(location: 0, length: text.length))
        for (index, event) in events.enumerated() {
            let end = index + 1 < events.count ? events[index + 1].0 : text.length
            if end > event.0 {
                let range = NSRange(location: event.0, length: end - event.0)
                text.addAttribute(.screenplayElement, value: event.1.type.rawValue, range: range)
                if let dual = event.1.dual { text.addAttribute(.screenplayDualDialogue, value: dual, range: range) }
                if event.1.revised { text.addAttribute(.screenplayRevisionMark, value: true, range: range) }
            }
        }
        var location = 0
        while location < text.length {
            let range = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            let element = element(in: text, at: location)
            let dual = text.attribute(.screenplayDualDialogue, at: location, effectiveRange: nil) as? String
            let rev = (text.attribute(.screenplayRevisionMark, at: location, effectiveRange: nil) as? Bool) == true
            ScreenplayTypography.apply(element, to: text, range: range, width: width, printing: printing, settings: settings, dualSide: dual, isRevised: rev)
            location = NSMaxRange(range)
        }
        return text
    }

    static func element(in text: NSAttributedString, at location: Int) -> ScreenplayElement {
        guard text.length > 0 else { return .action }
        return (text.attribute(.screenplayElement, at: min(max(0, location), text.length - 1),
                               effectiveRange: nil) as? String).flatMap(ScreenplayElement.init(rawValue:)) ?? .action
    }

    static func encode(_ text: NSAttributedString) -> String {
        guard text.length > 0 else { return "<div class=\"sc-line sc-action\"><br></div>" }
        let source = text.string as NSString
        var location = 0
        var blocks: [String] = []
        while location < text.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(paragraph)
            while end > paragraph.location && [10, 13, 0x2028, 0x2029].contains(source.character(at: end - 1)) { end -= 1 }
            let range = NSRange(location: paragraph.location, length: end - paragraph.location)
            var inner = ""
            text.enumerateAttributes(in: range) { attributes, run, _ in
                var value = escape(source.substring(with: run))
                if let font = attributes[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.boldFontMask) { value = "<b>\(value)</b>" }
                    if traits.contains(.italicFontMask) { value = "<i>\(value)</i>" }
                }
                if let underline = attributes[.underlineStyle] as? Int, underline != 0 { value = "<u>\(value)</u>" }
                inner += value
            }
            let type = element(in: text, at: paragraph.location)
            let dual = text.attribute(.screenplayDualDialogue, at: paragraph.location, effectiveRange: nil) as? String
            let dualClass = dual.map { " sc-dual-\($0)" } ?? ""
            let isRev = (text.attribute(.screenplayRevisionMark, at: paragraph.location, effectiveRange: nil) as? Bool) == true
            let revClass = isRev ? " sc-rev" : ""
            blocks.append("<div class=\"sc-line sc-\(type.rawValue)\(dualClass)\(revClass)\" style=\"white-space: pre-wrap;\">\(inner.isEmpty ? "<br>" : inner)</div>")
            location = NSMaxRange(paragraph)
        }
        return blocks.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }

    private static func markLeafBlocks(_ html: String, token: String) -> (html: String, metas: [BlockMeta]) {
        guard let tags = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:"[^"]*"|'[^']*'|[^'">])*>"#),
              let names = try? NSRegularExpression(pattern: #"^<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)"#),
              let classes = try? NSRegularExpression(pattern: #"\sclass\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                                                    options: .caseInsensitive) else { return (html, []) }
        let source = html as NSString
        let blockTags: Set<String> = ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"]
        let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "wbr", "source", "area", "base", "embed", "param", "col", "track"]
        var stack: [(name: String, meta: BlockMeta, block: Int?)] = []
        var blocks: [(position: Int, meta: BlockMeta, hasChild: Bool)] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range) as NSString
            guard let nameMatch = names.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) else { continue }
            let name = tag.substring(with: nameMatch.range(at: 2)).lowercased()
            if nameMatch.range(at: 1).length > 0 {
                if let index = stack.lastIndex(where: { $0.name == name }) { stack.removeSubrange(index...) }
                continue
            }
            var type = stack.last?.meta.type ?? .action
            var dual: String? = stack.last?.meta.dual
            var rev: Bool = stack.last?.meta.revised ?? false
            if let classMatch = classes.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let classText = (1...3).filter { classMatch.range(at: $0).location != NSNotFound }
                    .map { tag.substring(with: classMatch.range(at: $0)) }.joined()
                for word in classText.split(whereSeparator: { $0.isWhitespace }) {
                    if word.hasPrefix("sc-") {
                        if word == "sc-dual-left" { dual = "left" }
                        else if word == "sc-dual-right" { dual = "right" }
                        else if word == "sc-rev" { rev = true }
                        else if let explicit = ScreenplayElement(rawValue: String(word.dropFirst(3))) { type = explicit }
                    }
                }
            }
            var block: Int?
            let currentMeta = BlockMeta(type: type, dual: dual, revised: rev)
            if blockTags.contains(name), !stack.contains(where: { ["head", "style", "script"].contains($0.name) }) {
                if let parent = stack.last(where: { $0.block != nil })?.block { blocks[parent].hasChild = true }
                block = blocks.count
                blocks.append((NSMaxRange(match.range), currentMeta, false))
            }
            if !voidTags.contains(name), !((tag as String).hasSuffix("/>")) { stack.append((name, currentMeta, block)) }
        }
        let leaves = blocks.filter { !$0.hasChild }
        let output = NSMutableString(string: html)
        for (index, block) in leaves.enumerated().reversed() {
            output.insert("\(token)\(index)END", at: block.position)
        }
        return (output as String, leaves.map(\.meta))
    }
}
#endif
