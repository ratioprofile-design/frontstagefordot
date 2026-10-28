#if os(macOS)
import AppKit
import FrontstageCore

@MainActor
enum ScreenplayDualDialogue {
    struct SpeechBlock {
        let range: NSRange
        let characterRange: NSRange
        let dialogueRanges: [NSRange]
        let side: String?
    }

    /// Finds the speech block containing or immediately preceding the given location.
    static func speechBlock(at location: Int, in text: NSAttributedString) -> SpeechBlock? {
        guard text.length > 0 else { return nil }
        let source = text.string as NSString
        let loc = min(max(0, location), text.length - 1)
        let curPara = source.paragraphRange(for: NSRange(location: loc, length: 0))
        let curElem = ScreenplayTextCodec.element(in: text, at: curPara.location)

        var charPara: NSRange?
        if curElem == .character {
            charPara = curPara
        } else if [.dialogue, .parenthetical, .lyrics].contains(curElem) {
            // Scan backwards to find the Character element
            var scan = curPara.location
            while scan > 0 {
                let prev = source.paragraphRange(for: NSRange(location: scan - 1, length: 0))
                let elem = ScreenplayTextCodec.element(in: text, at: prev.location)
                if elem == .character {
                    charPara = prev
                    break
                }
                if ![.dialogue, .parenthetical, .lyrics].contains(elem) { break }
                scan = prev.location
            }
        }
        guard let charRange = charPara else { return nil }

        // Scan forwards from character to collect all dialogue/parenthetical lines in this speech block
        var lines: [NSRange] = []
        var nextLoc = NSMaxRange(charRange)
        while nextLoc < text.length {
            let nextPara = source.paragraphRange(for: NSRange(location: nextLoc, length: 0))
            let elem = ScreenplayTextCodec.element(in: text, at: nextPara.location)
            if [.dialogue, .parenthetical, .lyrics].contains(elem) {
                lines.append(nextPara)
                nextLoc = NSMaxRange(nextPara)
            } else {
                break
            }
        }
        let totalEnd = lines.last.map { NSMaxRange($0) } ?? NSMaxRange(charRange)
        let totalRange = NSRange(location: charRange.location, length: totalEnd - charRange.location)
        let side = text.attribute(.screenplayDualDialogue, at: charRange.location, effectiveRange: nil) as? String

        return SpeechBlock(range: totalRange, characterRange: charRange, dialogueRanges: lines, side: side)
    }

    /// Finds the speech block immediately preceding the given block.
    static func previousSpeechBlock(before block: SpeechBlock, in text: NSAttributedString) -> SpeechBlock? {
        var scan = block.range.location
        while scan > 0 {
            let prev = (text.string as NSString).paragraphRange(for: NSRange(location: scan - 1, length: 0))
            let elem = ScreenplayTextCodec.element(in: text, at: prev.location)
            if elem == .character || [.dialogue, .parenthetical, .lyrics].contains(elem) {
                return speechBlock(at: prev.location, in: text)
            }
            if elem == .sceneHeading { break }
            scan = prev.location
        }
        return nil
    }

    /// Toggles Dual Dialogue for the speech block at selection.
    /// If already dual dialogue, removes dual dialogue from both speakers.
    /// If single, links current speaker (as Right) with preceding speaker (as Left).
    @discardableResult
    static func toggleDualDialogue(in textView: NSTextView, contentWidth: CGFloat, settings: ScriptLayoutSettings) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        let location = textView.selectedRange().location
        guard let currentBlock = speechBlock(at: location, in: storage) else { return false }

        if currentBlock.side != nil {
            // Currently Dual Dialogue: clear dual formatting on current and adjacent blocks
            let targetRange: NSRange
            if currentBlock.side == "right", let prev = previousSpeechBlock(before: currentBlock, in: storage), prev.side == "left" {
                targetRange = NSRange(location: prev.range.location, length: NSMaxRange(currentBlock.range) - prev.range.location)
            } else {
                targetRange = currentBlock.range
            }

            let sub = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: targetRange))
            var offset = 0
            let str = sub.string as NSString
            while offset < sub.length {
                let para = str.paragraphRange(for: NSRange(location: offset, length: 0))
                let elem = ScreenplayTextCodec.element(in: sub, at: offset)
                ScreenplayTypography.apply(elem, to: sub, range: para, width: contentWidth, settings: settings, dualSide: "")
                sub.removeAttribute(.screenplayDualDialogue, range: para)
                offset = NSMaxRange(para)
            }
            textView.insertText(sub, replacementRange: targetRange)
            return true
        } else {
            // Not dual dialogue: link with preceding block
            guard let prevBlock = previousSpeechBlock(before: currentBlock, in: storage) else { return false }

            let leftRange = prevBlock.range
            let rightRange = currentBlock.range
            let fullRange = NSRange(location: leftRange.location, length: NSMaxRange(rightRange) - leftRange.location)
            let sub = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: fullRange))
            let str = sub.string as NSString

            var offset = 0
            while offset < sub.length {
                let para = str.paragraphRange(for: NSRange(location: offset, length: 0))
                let elem = ScreenplayTextCodec.element(in: sub, at: offset)
                let side = (offset + fullRange.location < rightRange.location) ? "left" : "right"
                ScreenplayTypography.apply(elem, to: sub, range: para, width: contentWidth, settings: settings, dualSide: side)
                sub.addAttribute(.screenplayDualDialogue, value: side, range: para)
                offset = NSMaxRange(para)
            }
            textView.insertText(sub, replacementRange: fullRange)
            return true
        }
    }
}
#endif
