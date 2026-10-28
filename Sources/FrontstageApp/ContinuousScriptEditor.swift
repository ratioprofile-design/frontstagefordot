#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore
private let ownerKey = NSAttributedString.Key("FrontstageBeatOwner")
private let headingKey = NSAttributedString.Key("FrontstageSceneHeading")
enum WritingPaperTheme: String, CaseIterable {
    case white = "White", warm = "Warm", dark = "Dark", red = "Red"
    var paper: NSColor { switch self { case .white: .white; case .warm: NSColor(srgbRed: 0.98, green: 0.94, blue: 0.85, alpha: 1); case .dark: NSColor(white: 0.13, alpha: 1); case .red: NSColor(srgbRed: 0.13, green: 0.04, blue: 0.04, alpha: 1) } }
    var ink: NSColor { switch self { case .white, .warm: .black; case .dark: NSColor(white: 0.92, alpha: 1); case .red: NSColor(srgbRed: 0.91, green: 0.65, blue: 0.65, alpha: 1) } }
}
final class WritingCanvasView: NSView {
    weak var paperView: WritingTextView?
    var paperWidth: CGFloat = 595.2756
    var minimumPaperHeight: CGFloat = 841.8898
    private var arranging = false
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPaper() }
    override func layout() { super.layout(); layoutPaper() }
    func layoutPaper() {
        guard !arranging, let text = paperView else { return }
        arranging = true; defer { arranging = false }
        var height = minimumPaperHeight
        if let manager = text.layoutManager, let container = text.textContainer {
            manager.ensureLayout(for: container)
            height = max(height, ceil(manager.usedRect(for: container).height + text.textContainerInset.height * 2 + 8))
        }
        let size = NSSize(width: paperWidth, height: height)
        if text.frame.size != size { text.setFrameSize(size) }
        let viewport = enclosingScrollView?.contentSize ?? .zero
        let canvas = NSSize(width: max(viewport.width, paperWidth + 48), height: max(viewport.height, height + 48))
        if frame.size != canvas { super.setFrameSize(canvas) }
        text.setFrameOrigin(NSPoint(x: (canvas.width - paperWidth) / 2, y: 24))
    }
}
final class WritingTextView: ScreenplayTextView {
    var pageHeight: CGFloat = 842
    var revealBeat: ((String) -> Void)?
    var compositionFinished: (() -> Void)?
    private(set) var activeHeadingRange: NSRange?
    func highlightHeading(for id: String?) {
        guard !hasMarkedText(), let manager = layoutManager else { return }
        let source = attributedString(); var location = 0, heading: NSRange?
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: source.length)); activeHeadingRange = nil
        while location < source.length {
            let range = (source.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            if source.attribute(headingKey, at: location, effectiveRange: nil) != nil { heading = range }
            if let id, source.attribute(ownerKey, at: location, effectiveRange: nil) as? String == id { activeHeadingRange = heading; break }
            location = NSMaxRange(range)
        }
        needsDisplay = true
    }
    override func unmarkText() {
        super.unmarkText()
        DispatchQueue.main.async { [weak self] in if let self, !self.hasMarkedText() { self.compositionFinished?() } }
    }
    private func prepareBodyTyping(at range: NSRange) {
        let source = attributedString()
        guard !hasMarkedText(), source.length > 0, range.location <= source.length,
              typingAttributes[headingKey] != nil else { return }
        let index = min(range.location, max(0, source.length - 1))
        let paragraph = (source.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
        if source.attribute(headingKey, at: paragraph.location, effectiveRange: nil) == nil {
            typingAttributes = source.attributes(at: index, effectiveRange: nil)
            typingAttributes.removeValue(forKey: headingKey)
        }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        prepareBodyTyping(at: replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if let replacement = ScriptHeadingEditing.replacement(insertString, in: self, range: range) {
            super.insertText(replacement, replacementRange: replacementRange)
        } else {
            // TextKit can retain a heading's typing attributes after moving into
            // an empty body paragraph. Its scene identity must never follow text
            // into the body and make that text replace the real slugline.
            let source = attributedString()
            let destination = min(range.location, max(0, source.length - 1))
            let paragraph = (source.string as NSString).paragraphRange(for: NSRange(location: destination, length: 0))
            let bodyDestination = source.length > 0 && range.location <= source.length && source.attribute(headingKey, at: destination, effectiveRange: nil) == nil
            prepareBodyTyping(at: range)
            if let attributed = insertString as? NSAttributedString {
                let elem = attributed.attribute(.screenplayElement, at: 0, effectiveRange: nil) as? String
                if elem != ScreenplayElement.sceneHeading.rawValue {
                    let body = NSMutableAttributedString(attributedString: attributed)
                    body.removeAttribute(headingKey, range: NSRange(location: 0, length: body.length))
                    typingAttributes.removeValue(forKey: headingKey)
                    super.insertText(body, replacementRange: replacementRange)
                    return
                }
            }
            if let attributed = insertString as? NSAttributedString, bodyDestination, NSMaxRange(range) <= NSMaxRange(paragraph) {
                let body = NSMutableAttributedString(attributedString: attributed)
                body.removeAttribute(headingKey, range: NSRange(location: 0, length: body.length))
                super.insertText(body, replacementRange: replacementRange)
            } else { super.insertText(insertString, replacementRange: replacementRange) }
        }
    }
    @discardableResult func centerBeat(_ id: String) -> Bool {
        guard !hasMarkedText(), let canvas = superview as? WritingCanvasView, let scroll = enclosingScrollView,
              let manager = layoutManager, let container = textContainer else { return false }
        canvas.layoutPaper()
        let source = attributedString()
        var target: NSRange?
        source.enumerateAttribute(ownerKey, in: NSRange(location: 0, length: source.length)) { value, range, stop in
            if value as? String == id { target = (source.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0)); stop.pointee = true }
        }
        guard let target else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: target.location, length: 0))
        let glyphs = manager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
        let heading = canvas.convert(rect, from: self), clip = scroll.contentView
        let y = max(0, min(canvas.bounds.height - clip.bounds.height, heading.midY - clip.bounds.height / 2))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y)); scroll.reflectScrolledClipView(clip)
        highlightHeading(for: id)
        return true
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let range = activeHeadingRange, let manager = layoutManager, let container = textContainer, NSMaxRange(range) <= attributedString().length {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            NSColor.controlAccentColor.setFill()
            NSRect(x: textContainerOrigin.x - 8, y: textContainerOrigin.y + bounds.minY, width: 3, height: bounds.height).fill()
        }
        guard pageHeight > 0 else { return }
        let first = max(1, Int(rect.minY / pageHeight)), last = Int(rect.maxY / pageHeight)
        if first <= last { for page in first...last {
            let y = CGFloat(page) * pageHeight
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSRect(x: 0, y: y, width: 24, height: 1).fill()
            NSRect(x: bounds.width - 24, y: y, width: 24, height: 1).fill()
        } }
    }
}
struct ContinuousScriptEditor: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: ScreenplayEditorController
    var width: CGFloat
    var zoom: Double
    var theme = WritingPaperTheme.white
    func makeCoordinator() -> Coordinator { Coordinator(workspace, controller) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), text = WritingTextView(), canvas = WritingCanvasView()
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(white: 0.3, alpha: 1)
        canvas.paperView = text; canvas.addSubview(text); canvas.autoresizingMask = [.width]
        scroll.documentView = canvas; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        text.isRichText = true; text.importsGraphics = false; text.allowsUndo = true; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.backgroundColor = .white; text.textColor = .black; text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = []
        text.textContainerInset = NSSize(width: 60, height: 60); text.textContainer?.widthTracksTextView = false
        text.screenplayController = controller; text.delegate = context.coordinator; controller.textView = text
        text.splitScene = { [weak coordinator = context.coordinator, weak text] in if let text { coordinator?.splitAtCaret(text) } }
        text.revealBeat = { [weak coordinator = context.coordinator, weak text] id in if let text { coordinator?.reveal(id, in: text) } }
        controller.completionRequest = { [weak coordinator = context.coordinator, weak text] in if let text { coordinator?.showSuggestions(text) } }
        text.compositionFinished = { [weak coordinator = context.coordinator, weak text] in
            if let coordinator, coordinator.pendingReveal != nil, let text { coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: text)) }
        }
        configure(text); context.coordinator.load(text); canvas.layoutPaper(); applyAppearance(text); return scroll
    }
    private func configure(_ text: NSTextView) {
        controller.contentWidth = width * zoom
        var typography = workspace.project.scriptLayout; typography.fontSize *= zoom; typography.lineHeight *= zoom; typography.paragraphSpacing *= zoom; controller.typography = typography
        text.textContainer?.containerSize = NSSize(width: width * zoom, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: workspace.paper.leftMargin * zoom, height: workspace.paper.topMargin * zoom)
        text.minSize = NSSize(width: workspace.paper.width * zoom, height: workspace.paper.height * zoom)
        text.maxSize = NSSize(width: workspace.paper.width * zoom, height: .greatestFiniteMagnitude)
        text.setFrameSize(NSSize(width: workspace.paper.width * zoom, height: max(text.frame.height, workspace.paper.height * zoom)))
        (text as? WritingTextView)?.pageHeight = workspace.paper.height * zoom
        if let canvas = text.superview as? WritingCanvasView { canvas.paperWidth = workspace.paper.width * zoom; canvas.minimumPaperHeight = workspace.paper.height * zoom }
        text.isSelectable = true
        text.isEditable = workspace.sharedProjects.linked?.access != "reader"
    }
    private func applyAppearance(_ text: NSTextView) {
        guard !text.hasMarkedText() else { return }
        text.backgroundColor = theme.paper; text.textColor = theme.ink; text.insertionPointColor = theme.ink
        text.typingAttributes[.foregroundColor] = theme.ink
        if let writing = text as? WritingTextView { DialoguePresentation.refresh(writing); writing.highlightHeading(for: workspace.selectedBoardBeatID) }
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let canvas = view.documentView as? WritingCanvasView, let text = canvas.paperView else { return }
        configure(text)
        let signature = context.coordinator.signature()
        if !context.coordinator.committing && !text.hasMarkedText() && signature != context.coordinator.lastSignature {
            if text.window?.firstResponder !== text {
                context.coordinator.load(text)
            }
        }
        canvas.layoutPaper()
        applyAppearance(text)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let workspace: Workspace; let controller: ScreenplayEditorController
        var committing = false, loading = false, completing = false, lastSignature = ""
        var visible = Set<String>()
        var headingScenes = Set<Decimal>()
        var pendingPullouts = Set<String>()
        var pendingHeading: ScriptHeadingEditing.Context?
        var pendingReveal: String?
        var offerCompletions = false
        let headingSuggestions = HeadingSuggestionPanel()
        var registeredNames = Set<String>()
        var registeredHeadings = [SceneHeading]()
        var dialogueCache = [String: DialoguePresentation.CachedBeat]()
        func refreshDialogue(_ text: NSTextView) {
            if let text = text as? ScreenplayTextView {
                // The live attributed paragraphs are already decoded. AppKit's
                // HTML importer runs a nested event loop; using it per keystroke
                // can process a second edit before the first one has committed.
                let source = text.attributedString(), string = source.string as NSString
                var lines = [String: [(ScreenplayElement, String)]](), location = 0
                while location < source.length {
                    let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                    if source.attribute(headingKey, at: location, effectiveRange: nil) == nil,
                       let id = source.attribute(ownerKey, at: location, effectiveRange: nil) as? String {
                        lines[id, default: []].append((ScreenplayTextCodec.element(in: source, at: location), string.substring(with: range)))
                    }
                    location = NSMaxRange(range)
                }
                for beat in workspace.whiteboard.beats where visible.contains(beat.id) {
                    dialogueCache[beat.id] = DialoguePresentation.CachedBeat(html: beat.html, lines: lines[beat.id] ?? [])
                }
                text.continuationFlags = DialoguePresentation.projectFlags(workspace.project, cache: &dialogueCache); DialoguePresentation.refresh(text)
            }
        }
        init(_ workspace: Workspace, _ controller: ScreenplayEditorController) { self.workspace = workspace; self.controller = controller }
        func showSuggestions(_ text: NSTextView) {
            guard !text.hasMarkedText(), text.attributedString().length > 0 else { headingSuggestions.close(); return }
            let location = min(text.selectedRange().location, text.attributedString().length - 1)
            let range = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            registeredNames.formUnion(ScriptCueNames.committed(in: text.attributedString(), excluding: range))
            let names = registeredNames.union(workspace.project.characters.map(\.name)).union(workspace.whiteboard.beats.flatMap(\.characters)).sorted()
            headingSuggestions.show(in: text, headings: registeredHeadings + workspace.project.scenes.map(\.heading), names: names, choices: completionChoices)
        }
        func reveal(_ id: String, in text: WritingTextView) {
            if text.hasMarkedText() { pendingReveal = id; return }
            headingSuggestions.close()
            synchronizeHeadings(text, excluding: nil)
            if text.centerBeat(id) { workspace.selectBoardBeat(id) }
        }
        func synchronizeHeadings(_ text: NSTextView, excluding range: NSRange?) {
            let prior = loading; loading = true
            ScriptHeadingEditing.synchronize(text, project: workspace.project, excluding: range)
            loading = prior
            (text.superview as? WritingCanvasView)?.layoutPaper()
        }
        func splitAtCaret(_ text: NSTextView) {
            guard text.isEditable, !text.hasMarkedText(), text.selectedRange().length == 0 else { return }
            let source = text.attributedString(), caret = text.selectedRange().location
            guard caret < source.length, source.attribute(headingKey, at: caret, effectiveRange: nil) == nil,
                  let id = source.attribute(ownerKey, at: caret, effectiveRange: nil) as? String,
                  let beat = workspace.whiteboard.beats.first(where: { $0.id == id }),
                  let scene = workspace.project.scenes.first(where: { $0.id == beat.sceneID }) else { workspace.errorMessage = "Place the cursor inside screenplay text to split the scene."; return }
            let before = NSMutableAttributedString(string: ""), after = NSMutableAttributedString(string: "")
            source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                guard attributes[ownerKey] as? String == id, attributes[headingKey] == nil else { return }
                let end = NSMaxRange(range)
                if range.location < caret { before.append(source.attributedSubstring(from: NSRange(location: range.location, length: min(end, caret) - range.location))) }
                if end > caret { after.append(source.attributedSubstring(from: NSRange(location: max(range.location, caret), length: end - max(range.location, caret)))) }
            }
            guard !before.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !after.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { workspace.errorMessage = "Place the cursor between screenplay text before splitting."; return }
            var created: String?
            workspace.edit("Split Scene") { created = try $0.insertScriptScene(afterSplitting: id, beforeHTML: ScreenplayTextCodec.encode(before), afterHTML: ScreenplayTextCodec.encode(after), heading: scene.heading.inlineText) }
            if let created {
                workspace.selectBoardBeat(created); load(text)
                text.attributedString().enumerateAttribute(ownerKey, in: NSRange(location: 0, length: text.attributedString().length)) { value, range, stop in
                    if value as? String == created { text.setSelectedRange(NSRange(location: range.location, length: 0)); text.scrollRangeToVisible(range); stop.pointee = true }
                }
                text.window?.makeFirstResponder(text)
            }
        }
        func signature() -> String {
            String(describing: controller.typography) + String(describing: controller.contentWidth) + workspace.whiteboard.orderedBeats.filter { !$0.omitted && !workspace.whiteboard.isUnused($0) && workspace.reader.filters.matches($0, board: workspace.whiteboard, scenes: workspace.project.scenes) }.map { beat in beat.id + beat.html + (workspace.project.scenes.first { $0.id == beat.sceneID }?.heading.inlineText ?? "") }.joined(separator: "\u{1f}")
        }
        func load(_ text: NSTextView) {
            loading = true; defer { loading = false }; visible.removeAll(); headingScenes.removeAll()
            let bookmark = ScriptHeadingEditing.bookmark(text)
            if lastSignature.isEmpty { registeredNames.formUnion(workspace.screenplayCompletions[.character] ?? []) }
            if registeredHeadings.isEmpty { registeredHeadings = workspace.project.scenes.map(\.heading) }
            let result = NSMutableAttributedString(string: "")
            for segment in (try? workspace.project.orderedScript()) ?? [] {
                let beats = segment.beatIDs.compactMap { id in workspace.whiteboard.beats.first { $0.id == id } }.filter { workspace.reader.filters.matches($0, board: workspace.whiteboard, scenes: workspace.project.scenes) }
                guard let first = beats.first else { continue }
                headingScenes.insert(segment.scene.id)
                var attributes = ScreenplayTypography.attributes(.sceneHeading, width: controller.contentWidth, settings: controller.typography)
                attributes[ownerKey] = first.id; attributes[headingKey] = NSDecimalNumber(decimal: segment.scene.id).stringValue; attributes[.foregroundColor] = NSColor.black
                result.append(NSAttributedString(string: segment.scene.heading.inlineText + "\n", attributes: attributes))
                for beat in beats {
                    visible.insert(beat.id)
                    let body = (try? ScreenplayTextCodec.decode(beat.html.isEmpty ? "<p class='sc-action'><br></p>" : beat.html, width: controller.contentWidth, printing: true, settings: controller.typography)) ?? NSMutableAttributedString(string: "\n")
                    if !body.string.hasSuffix("\n") { body.append(NSAttributedString(string: "\n", attributes: ScreenplayTypography.attributes(.action, width: controller.contentWidth, settings: controller.typography))) }
                    body.addAttribute(ownerKey, value: beat.id, range: NSRange(location: 0, length: body.length)); result.append(body)
                }
            }
            let selection = bookmark.flatMap { ScriptHeadingEditing.restore($0, in: result, project: workspace.project) } ?? NSRange(location: min(text.selectedRange().location, result.length), length: 0)
            text.textStorage?.setAttributedString(result)
            refreshDialogue(text)
            (text.superview as? WritingCanvasView)?.layoutPaper()
            text.setSelectedRange(selection, affinity: bookmark?.affinity ?? .downstream, stillSelecting: false); lastSignature = signature()
        }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, !loading, !committing, !text.hasMarkedText() else { return }
            committing = true; defer { committing = false }
            loading = true
            let changedHeading = pendingHeading?.range.location
            if let context = pendingHeading { ScriptHeadingEditing.repair(text, context: context); pendingHeading = nil }
            if let storage = text.textStorage, storage.length > 0 {
                let position = min(text.selectedRange().location, storage.length - 1)
                let range = (text.string as NSString).paragraphRange(for: NSRange(location: position, length: 0))
                let line = (text.string as NSString).substring(with: range)
                if storage.attribute(.screenplayElement, at: position, effectiveRange: nil) as? String == "action",
                   line.range(of: #"^(INT\.|EXT\.|INT\./EXT\.|EXT\./INT\.)\s"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    ScreenplayTypography.apply(.sceneHeading, to: storage, range: range, width: controller.contentWidth, settings: controller.typography)
                }
            }
            ScriptCueNames.capitalize(in: text); loading = false
            let source = text.attributedString(), string = source.string as NSString
            var assignments = [(NSRange, String)](), created = [(NSRange, String, Decimal)](), succeeded = false, missingHeading = false
            let selection = text.selectedRange()
            let editing = source.length > 0 ? string.paragraphRange(for: NSRange(location: min(selection.location, source.length - 1), length: 0)) : nil
            workspace.edit("Screenplay", key: "continuous-script") { project in
                var html = Dictionary(uniqueKeysWithValues: visible.filter { !pendingPullouts.contains($0) }.map { ($0, "") })
                var headings = [ScriptHeadingEdit](), owner: String?, redirects = [String: String]()
                var location = 0
                while location < source.length {
                    let range = string.paragraphRange(for: NSRange(location: location, length: 0)), attributes = source.attributes(at: location, effectiveRange: nil)
                    let original = attributes[ownerKey] as? String ?? owner
                    owner = original.flatMap { redirects[$0] ?? $0 }
                    guard let id = owner, !pendingPullouts.contains(id) else { location = NSMaxRange(range); continue }
                    let line = string.substring(with: range).trimmingCharacters(in: .newlines)
                    let kind = ScreenplayElement(rawValue: attributes[.screenplayElement] as? String ?? "action") ?? .action
                    // Any paragraph that carries headingKey is a real scene heading — never encode it as body HTML.
                    let isRealHeading = attributes[headingKey] != nil
                    if isRealHeading, let scene = attributes[headingKey] as? String, let sceneID = Decimal(string: scene) {
                        if let existing = headings.firstIndex(where: { $0.sceneID == sceneID }) {
                            if range.location == changedHeading || (changedHeading == nil && range == editing) { headings[existing] = ScriptHeadingEdit(sceneID: sceneID, text: line) }
                        } else { headings.append(ScriptHeadingEdit(sceneID: sceneID, text: line)) }
                    } else if isRealHeading {
                        // headingKey present but Decimal parse failed — skip silently; the heading
                        // will be corrected on the next full load.
                    } else if kind == .sceneHeading && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        if let currentSceneID = workspace.whiteboard.beats.first(where: { $0.id == id })?.sceneID,
                           let currentScene = project.scenes.first(where: { $0.id == currentSceneID }),
                           (html[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           (currentScene.heading.location.isEmpty || currentScene.heading.inlineText == "INT. - DAY") {
                            try project.updateScene(id: currentSceneID, heading: SceneHeading(inline: line))
                            headings.removeAll { $0.sceneID == currentSceneID }
                            headings.append(ScriptHeadingEdit(sceneID: currentSceneID, text: line))
                            created.append((range, id, currentSceneID))
                        } else {
                            let newID = try project.insertScriptScene(afterSplitting: id, beforeHTML: html[id] ?? "", afterHTML: "", heading: line)
                            guard let newBeat = try project.whiteboard().beats.first(where: { $0.id == newID }) else { throw ProjectError.sceneNotFound }
                            if let original { redirects[original] = newID }; redirects[id] = newID
                            owner = newID; html[newID] = ""; created.append((range, newID, newBeat.sceneID))
                            headings.removeAll { $0.sceneID == newBeat.sceneID }
                            headings.append(ScriptHeadingEdit(sceneID: newBeat.sceneID, text: line))
                        }
                    } else {
                        html[id, default: ""] += ScreenplayTextCodec.encode(source.attributedSubstring(from: range))
                        assignments.append((range, id))
                    }
                    location = NSMaxRange(range)
                }
                for sceneID in headingScenes where !headings.contains(where: { $0.sceneID == sceneID }) {
                    if try project.whiteboard().beats.contains(where: { $0.sceneID == sceneID && html[$0.id] != nil }) {
                        headings.append(ScriptHeadingEdit(sceneID: sceneID, text: "")); missingHeading = true
                    }
                }
                try project.applyScriptDocument(beatHTML: html, headings: headings)
                if !pendingPullouts.isEmpty { try project.pullOutBeats(pendingPullouts) }
                succeeded = true
            }
            guard succeeded else { pendingPullouts.removeAll(); load(text); return }
            for (range, id) in assignments { text.textStorage?.addAttribute(ownerKey, value: id, range: range) }
            for (range, id, sceneID) in created {
                text.textStorage?.addAttributes([ownerKey: id, headingKey: NSDecimalNumber(decimal: sceneID).stringValue], range: range)
                visible.insert(id); headingScenes.insert(sceneID)
            }
            visible.subtract(pendingPullouts); pendingPullouts.removeAll()
            if missingHeading { load(text) }
            synchronizeHeadings(text, excluding: editing)
            refreshDialogue(text)
            (text.superview as? WritingCanvasView)?.layoutPaper()
            lastSignature = signature(); controller.selectionChanged(); text.scrollRangeToVisible(text.selectedRange())
            if let id = pendingReveal, let writing = text as? WritingTextView { pendingReveal = nil; reveal(id, in: writing) }
            if offerCompletions, !completing {
                showSuggestions(text)
            } else { headingSuggestions.close() }
            offerCompletions = false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !loading, let text = notification.object as? NSTextView, !text.hasMarkedText() else { return }
            headingSuggestions.close()
            controller.selectionChanged()
            let index = min(text.selectedRange().location, max(0, text.attributedString().length - 1))
            let active = text.attributedString().length > 0 ? (text.string as NSString).paragraphRange(for: NSRange(location: index, length: 0)) : nil
            if text.attributedString().length > 0, text.attributedString().attribute(headingKey, at: index, effectiveRange: nil) == nil {
                for heading in workspace.project.scenes.map(\.heading) where !registeredHeadings.contains(heading) { registeredHeadings.append(heading) }
            }
            // Selection can move into the body before a heading replacement's
            // didChange notification. Commit that draft before normalizing it.
            if pendingHeading == nil { synchronizeHeadings(text, excluding: active) }
            let position = min(text.selectedRange().location, max(0, text.attributedString().length - 1))
            if text.attributedString().length > 0, text.attributedString().attribute(headingKey, at: position, effectiveRange: nil) != nil {
                let range = (text.string as NSString).paragraphRange(for: NSRange(location: position, length: 0))
                if text.selectedRange().location < NSMaxRange(range) || !(text.string as NSString).substring(with: range).hasSuffix("\n") {
                    text.typingAttributes = text.attributedString().attributes(at: position, effectiveRange: nil)
                }
            }
            if text.attributedString().length > 0, let id = text.attributedString().attribute(ownerKey, at: position, effectiveRange: nil) as? String {
                workspace.selectBoardBeat(id)
                if text.selectedRange().length > 0, let beat = workspace.whiteboard.beats.first(where: { $0.id == id }) { workspace.writingSelectedQuote = (beat.sceneID, (text.string as NSString).substring(with: text.selectedRange())) }
            }
        }
        func textDidEndEditing(_ notification: Notification) {
            headingSuggestions.close()
            TamilInputManager.restoreStandardInput()
            if let text = notification.object as? NSTextView { synchronizeHeadings(text, excluding: nil) }
        }
        var completionChoices: [ScreenplayElement: [String]] {
            var choices = Workspace.screenplayFixedCompletions
            choices[.character] = registeredNames.union(workspace.project.characters.map(\.name)).union(workspace.whiteboard.beats.flatMap(\.characters)).sorted()
            choices[.sceneHeading] = Array(Set(workspace.project.scenes.map { $0.heading.text } + ["INT.", "EXT.", "INT./EXT."])).sorted()
            return choices
        }
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let source = textView.string as NSString, paragraph = source.paragraphRange(for: range)
            let prefix = source.substring(with: NSRange(location: paragraph.location, length: NSMaxRange(range) - paragraph.location))
            let before = source.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
            index?.pointee = -1
            guard !prefix.isEmpty else { return [] }
            let choices = controller.activeElement == .sceneHeading
                ? SceneHeading.completions(for: prefix, headings: workspace.project.scenes.map(\.heading))
                : (completionChoices[controller.activeElement] ?? []).filter { $0.lowercased().hasPrefix(prefix.lowercased()) && $0.lowercased() != prefix.lowercased() }
            if controller.activeElement == .sceneHeading, !choices.isEmpty { index?.pointee = 0 }
            return choices.map { String($0.dropFirst(before.count)) }
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if headingSuggestions.handle(commandSelector) { return true }
            let sel = textView.selectedRange()
            let source = textView.attributedString()
            let str = source.string as NSString
            let pos = min(sel.location, max(0, source.length - 1))
            let curRange = source.length > 0 ? str.paragraphRange(for: NSRange(location: pos, length: 0)) : NSRange(location: 0, length: 0)
            let isHeading = source.length > 0 && (
                source.attribute(headingKey, at: curRange.location, effectiveRange: nil) != nil ||
                source.attribute(.screenplayElement, at: curRange.location, effectiveRange: nil) as? String == ScreenplayElement.sceneHeading.rawValue ||
                controller.activeElement == .sceneHeading
            )
            if isHeading && (commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:))) {
                synchronizeHeadings(textView, excluding: nil)
                let currentStr = textView.string as NSString
                let heading = currentStr.paragraphRange(for: NSRange(location: min(sel.location, max(0, currentStr.length - 1)), length: 0))
                let headingText = currentStr.substring(with: heading)
                let hasNewline = headingText.hasSuffix("\n")
                if !hasNewline {
                    let headingAttrs = textView.attributedString().attributes(at: heading.location, effectiveRange: nil)
                    textView.insertText(NSAttributedString(string: "\n", attributes: headingAttrs), replacementRange: NSRange(location: NSMaxRange(heading), length: 0))
                }
                let updatedStr = textView.string as NSString
                let updatedHeading = updatedStr.paragraphRange(for: NSRange(location: heading.location, length: 0))
                let next = NSMaxRange(updatedHeading)
                var actionAttrs = ScreenplayTypography.attributes(.action, width: controller.contentWidth, settings: controller.typography)
                if let owner = textView.attributedString().attribute(ownerKey, at: heading.location, effectiveRange: nil) {
                    actionAttrs[ownerKey] = owner
                }
                actionAttrs.removeValue(forKey: headingKey)

                if next < textView.attributedString().length {
                    let nextElem = textView.attributedString().attribute(.screenplayElement, at: next, effectiveRange: nil) as? String
                    let nextHasHeadingKey = textView.attributedString().attribute(headingKey, at: next, effectiveRange: nil) != nil
                    if nextHasHeadingKey || nextElem == ScreenplayElement.sceneHeading.rawValue {
                        textView.insertText(NSAttributedString(string: "\n", attributes: actionAttrs), replacementRange: NSRange(location: next, length: 0))
                    }
                    textView.setSelectedRange(NSRange(location: next, length: 0))
                } else {
                    textView.insertText(NSAttributedString(string: "\n", attributes: actionAttrs), replacementRange: NSRange(location: next, length: 0))
                    textView.setSelectedRange(NSRange(location: next, length: 0))
                }
                var cleanTyping = ScreenplayTypography.attributes(.action, width: controller.contentWidth, settings: controller.typography)
                cleanTyping.removeValue(forKey: headingKey)
                if let owner = textView.attributedString().attribute(ownerKey, at: heading.location, effectiveRange: nil) {
                    cleanTyping[ownerKey] = owner
                }
                textView.typingAttributes = cleanTyping
                controller.activeElement = .action
                controller.selectionChanged()
                textView.scrollRangeToVisible(textView.selectedRange())
                if let storage = textView.textStorage, storage.length > 0, next < storage.length {
                    let bodyRange = (storage.string as NSString).paragraphRange(for: NSRange(location: next, length: 0))
                    if storage.attribute(.screenplayElement, at: next, effectiveRange: nil) as? String == ScreenplayElement.sceneHeading.rawValue {
                        ScreenplayTypography.apply(.action, to: storage, range: bodyRange, width: controller.contentWidth, settings: controller.typography)
                    }
                    storage.removeAttribute(headingKey, range: bodyRange)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return controller.handleCommand(commandSelector, in: textView)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if controller.activeElement == .action {
                    controller.format(.character)
                    offerCompletions = true
                    showSuggestions(textView)
                    return true
                }
                if controller.activeElement == .character {
                    let string = textView.string as NSString
                    let para = string.paragraphRange(for: textView.selectedRange())
                    textView.insertText("", replacementRange: para)
                    headingSuggestions.close()
                    controller.format(.transition)
                    return true
                }
                if controller.activeElement == .transition {
                    controller.format(.action)
                    return true
                }
                if controller.activeElement == .dialogue {
                    controller.format(.parenthetical)
                    return true
                }
                if controller.activeElement == .parenthetical {
                    controller.format(.dialogue)
                    return true
                }
            }
            if controller.activeElement == .transition && commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let str = textView.string as NSString
                let para = str.paragraphRange(for: textView.selectedRange())
                let end = NSMaxRange(para)
                let terminated = para.length > 0 && str.substring(with: para).hasSuffix("\n")
                if !terminated {
                    textView.insertText("\n", replacementRange: NSRange(location: end, length: 0))
                }
                let insertPos = !terminated ? end + 1 : end
                var headingAttrs = ScreenplayTypography.attributes(.sceneHeading, width: controller.contentWidth, settings: controller.typography)
                if let owner = textView.attributedString().attribute(ownerKey, at: min(para.location, max(0, textView.attributedString().length - 1)), effectiveRange: nil) {
                    headingAttrs[ownerKey] = owner
                }
                textView.insertText(NSAttributedString(string: "\n", attributes: headingAttrs), replacementRange: NSRange(location: insertPos, length: 0))
                textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                textView.typingAttributes = headingAttrs
                controller.activeElement = .sceneHeading
                controller.selectionChanged()
                return true
            }
            if controller.activeElement == .dialogue && commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let str = textView.string as NSString
                let para = str.paragraphRange(for: textView.selectedRange())
                let line = str.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    controller.format(.action)
                    return true
                }
                let end = NSMaxRange(para)
                let terminated = para.length > 0 && str.substring(with: para).hasSuffix("\n")
                if !terminated {
                    textView.insertText("\n", replacementRange: NSRange(location: end, length: 0))
                }
                let insertPos = !terminated ? end + 1 : end
                var charAttrs = ScreenplayTypography.attributes(.character, width: controller.contentWidth, settings: controller.typography)
                if let owner = textView.attributedString().attribute(ownerKey, at: min(para.location, max(0, textView.attributedString().length - 1)), effectiveRange: nil) {
                    charAttrs[ownerKey] = owner
                }
                charAttrs.removeValue(forKey: headingKey)
                textView.insertText(NSAttributedString(string: "\n", attributes: charAttrs), replacementRange: NSRange(location: insertPos, length: 0))
                textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                textView.typingAttributes = charAttrs
                controller.activeElement = .character
                controller.selectionChanged()
                offerCompletions = true
                showSuggestions(textView)
                return true
            }
            if controller.activeElement == .character && commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let str = textView.string as NSString
                let para = str.paragraphRange(for: textView.selectedRange())
                let line = str.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    controller.format(.action)
                    return true
                }
                let cueName = CharacterCue(line).name
                if !cueName.isEmpty && !workspace.project.characters.contains(where: { $0.name.caseInsensitiveCompare(cueName) == .orderedSame }) {
                    workspace.edit("Register Character") { try $0.createCharacter(name: cueName) }
                }
                let end = NSMaxRange(para)
                let terminated = para.length > 0 && str.substring(with: para).hasSuffix("\n")
                if !terminated {
                    textView.insertText("\n", replacementRange: NSRange(location: end, length: 0))
                }
                let insertPos = !terminated ? end + 1 : end
                let dual = textView.attributedString().attribute(.screenplayDualDialogue, at: para.location, effectiveRange: nil) as? String
                var dialAttrs = ScreenplayTypography.attributes(.dialogue, width: controller.contentWidth, settings: controller.typography, dualSide: dual)
                if let owner = textView.attributedString().attribute(ownerKey, at: min(para.location, max(0, textView.attributedString().length - 1)), effectiveRange: nil) {
                    dialAttrs[ownerKey] = owner
                }
                dialAttrs.removeValue(forKey: headingKey)
                if let dual { dialAttrs[.screenplayDualDialogue] = dual }
                textView.insertText(NSAttributedString(string: "\n", attributes: dialAttrs), replacementRange: NSRange(location: insertPos, length: 0))
                textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                textView.typingAttributes = dialAttrs
                controller.activeElement = .dialogue
                controller.selectionChanged()
                return true
            }
            if controller.activeElement == .parenthetical && commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let str = textView.string as NSString
                let para = str.paragraphRange(for: textView.selectedRange())
                let line = str.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    controller.format(.action)
                    return true
                }
                let end = NSMaxRange(para)
                let terminated = para.length > 0 && str.substring(with: para).hasSuffix("\n")
                if !terminated {
                    textView.insertText("\n", replacementRange: NSRange(location: end, length: 0))
                }
                let insertPos = !terminated ? end + 1 : end
                let dual = textView.attributedString().attribute(.screenplayDualDialogue, at: para.location, effectiveRange: nil) as? String
                var dialAttrs = ScreenplayTypography.attributes(.dialogue, width: controller.contentWidth, settings: controller.typography, dualSide: dual)
                if let owner = textView.attributedString().attribute(ownerKey, at: min(para.location, max(0, textView.attributedString().length - 1)), effectiveRange: nil) {
                    dialAttrs[ownerKey] = owner
                }
                dialAttrs.removeValue(forKey: headingKey)
                if let dual { dialAttrs[.screenplayDualDialogue] = dual }
                textView.insertText(NSAttributedString(string: "\n", attributes: dialAttrs), replacementRange: NSRange(location: insertPos, length: 0))
                textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                textView.typingAttributes = dialAttrs
                controller.activeElement = .dialogue
                controller.selectionChanged()
                return true
            }
            if let context = ScriptHeadingEditing.context(in: textView, replacing: textView.selectedRange()) {
                if commandSelector == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange() == NSRange(location: context.range.location, length: 0) { return true }
                if [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:))].contains(commandSelector),
                   textView.selectedRange().length > 0, NSMaxRange(textView.selectedRange()) == NSMaxRange(context.range),
                   (textView.string as NSString).substring(with: context.range).hasSuffix("\n") {
                    textView.insertText("", replacementRange: textView.selectedRange()); return true
                }
            }
            return controller.handleCommand(commandSelector, in: textView)
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            pendingPullouts.removeAll()
            let source = textView.attributedString(); guard source.length > 0 else { return true }
            if replacementString == "", range.length == 1, range.location < source.length,
               (source.string as NSString).character(at: range.location) == 10,
               source.attribute(headingKey, at: range.location, effectiveRange: nil) != nil { return false }
            pendingHeading = (replacementString == "\n" && range.length == 0) ? nil : ScriptHeadingEditing.context(in: textView, replacing: range)
            offerCompletions = replacementString?.isEmpty == false && replacementString?.contains("\n") != true
            if let rep = replacementString, rep.contains("(") {
                let string = textView.string as NSString
                let lineRange = string.paragraphRange(for: range)
                let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if controller.activeElement == .dialogue && line.isEmpty {
                    controller.format(.parenthetical)
                }
            }
            var allowed = true
            let checked = NSRange(location: min(range.location, source.length - 1), length: max(1, min(range.length, source.length - min(range.location, source.length - 1))))
            source.enumerateAttribute(ownerKey, in: checked) { value, _, _ in
                if let id = value as? String, let beat = workspace.whiteboard.beats.first(where: { $0.id == id }), workspace.whiteboard.isLocked(beat) || workspace.project.scenes.first(where: { $0.id == beat.sceneID })?.isTextLocked == true { allowed = false }
            }
            if allowed, replacementString == "", range.length > 0, pendingHeading == nil {
                var sceneRanges = [Decimal: NSRange]()
                source.enumerateAttribute(ownerKey, in: NSRange(location: 0, length: source.length)) { value, run, _ in
                    guard let id = value as? String, let beat = workspace.whiteboard.beats.first(where: { $0.id == id }) else { return }
                    sceneRanges[beat.sceneID] = sceneRanges[beat.sceneID].map { NSUnionRange($0, run) } ?? run
                }
                for (sceneID, sceneRange) in sceneRanges where range.location <= sceneRange.location && NSMaxRange(range) >= NSMaxRange(sceneRange) {
                    let owned = workspace.whiteboard.beats.filter { $0.sceneID == sceneID && !$0.omitted && !workspace.whiteboard.isUnused($0) }
                    if owned.allSatisfy({ visible.contains($0.id) }) { pendingPullouts.formUnion(owned.map(\.id)) }
                }
            }
            if !allowed { workspace.errorMessage = "This selection contains locked text." }; return allowed
        }
    }
}
#endif
