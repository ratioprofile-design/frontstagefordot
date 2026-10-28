#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore

struct WritePagePanels<Content: View>: View {
    @ObservedObject var workspace: Workspace
    let navigate: (Decimal, String?) -> Void
    @ViewBuilder let content: () -> Content
    @AppStorage("write-left-width") private var leftWidth = 280.0
    @AppStorage("write-right-width") private var rightWidth = 320.0
    @State private var drawer: String?
    @State private var dragLeft: Double?
    @State private var dragRight: Double?
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    WriteScenePanel(workspace: workspace, navigate: navigate)
                        .frame(width: leftWidth).frame(width: geometry.size.width >= 900 && workspace.writeCardsVisible ? leftWidth : 0).clipped()
                    if geometry.size.width >= 900 && workspace.writeCardsVisible { divider(left: true) }
                    content().frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 1180 && workspace.writeInspectorVisible { divider(left: false) }
                    WriteInspector(workspace: workspace)
                        .frame(width: rightWidth).frame(width: geometry.size.width >= 1180 && workspace.writeInspectorVisible ? rightWidth : 0).clipped()
                }
                .overlay(alignment: .leading) { if geometry.size.width < 900 && drawer == "left" { WriteScenePanel(workspace: workspace, navigate: navigate).frame(width: min(leftWidth, geometry.size.width * 0.85)).background(.background).shadow(radius: 8) } }
                .overlay(alignment: .trailing) { if geometry.size.width < 1180 && drawer == "right" { WriteInspector(workspace: workspace).frame(width: min(rightWidth, geometry.size.width * 0.85)).background(.background).shadow(radius: 8) } }
            }
            .onChange(of: workspace.writeCardsToggle) { _, _ in if geometry.size.width < 900 { drawer = drawer == "left" ? nil : "left" } else { workspace.writeCardsVisible.toggle() } }
            .onChange(of: workspace.writeInspectorToggle) { _, _ in if geometry.size.width < 1180 { drawer = drawer == "right" ? nil : "right" } else { workspace.writeInspectorVisible.toggle() } }
        }
    }
    private func divider(left: Bool) -> some View {
        Rectangle().fill(.secondary.opacity(0.4)).frame(width: 5)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture().onChanged { value in
                if left { if dragLeft == nil { dragLeft = leftWidth }; leftWidth = min(480, max(220, (dragLeft ?? 280) + value.translation.width)) }
                else { if dragRight == nil { dragRight = rightWidth }; rightWidth = min(480, max(260, (dragRight ?? 320) - value.translation.width)) }
            }.onEnded { _ in dragLeft = nil; dragRight = nil })
            .accessibilityLabel(left ? "Resize left panel" : "Resize right panel")
    }
}

struct WriteScenePanel: View {
    @ObservedObject var workspace: Workspace
    let navigate: (Decimal, String?) -> Void
    @AppStorage("write-left-tab") private var tab = "Scenes"
    @State private var search = ""
    @State private var conversion = false
    private var cards: [SceneCard] { ((try? workspace.project.sceneCards()) ?? []).filter { search.isEmpty || [$0.number, $0.scene.heading.text] .joined(separator: " ").localizedCaseInsensitiveContains(search) || $0.beats.contains { ($0.title + " " + $0.synopsis).localizedCaseInsensitiveContains(search) } } }
    var body: some View {
        VStack {
            Picker("Navigation", selection: $tab) { Text("Scenes").tag("Scenes"); Text("Locations").tag("Locations") }.pickerStyle(.segmented)
            TextField("Search scenes", text: $search)
            if !workspace.project.usesOneBeatPerScene { Button("Review Converted Copy") { conversion = true } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tab == "Locations" {
                        let groups = Dictionary(grouping: cards) { $0.scene.heading.location.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                        ForEach(groups.keys.sorted(), id: \.self) { key in
                            DisclosureGroup(key.isEmpty ? "Unspecified" : key) { ForEach(groups[key] ?? []) { card in beatCards(card) } }
                        }
                    } else { ForEach(cards) { card in beatCards(card) } }
                }
            }
        }.padding(10).frame(maxHeight: .infinity)
            .sheet(isPresented: $conversion) { SceneConversionReview(workspace: workspace) }
    }
    @ViewBuilder private func beatCards(_ card: SceneCard) -> some View {
        ForEach(card.beats.filter { !$0.omitted && !workspace.whiteboard.isUnused($0) }) { beat in
            SimpleWriteBeatCard(workspace: workspace, beat: beat, scene: card.scene, number: card.number, navigate: navigate)
        }
    }
}
struct SimpleWriteBeatCard: View {
    @ObservedObject var workspace: Workspace
    let beat: BoardBeat
    let scene: FrontstageCore.Scene
    let number: String
    let navigate: (Decimal, String?) -> Void
    @State private var editing: String?
    @State private var draft = ""
    @State private var expanded = false
    @State private var dropBefore = false
    @State private var dropAfter = false
    @FocusState private var focused: Bool
    private var locked: Bool { workspace.whiteboard.isLocked(beat) || scene.isTextLocked || workspace.sharedProjects.linked?.access == "reader" }
    var body: some View {
        content
            .background(Color.secondary.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(workspace.selectedBoardBeatID == beat.id ? Color.accentColor : Color.gray.opacity(0.35)))
            .overlay(alignment: .top) { if dropBefore { Rectangle().fill(Color.accentColor).frame(height: 3) } }
            .simultaneousGesture(TapGesture().onEnded { if editing == nil { navigate(scene.id, beat.id) } })
            .contextMenu { actions }
            .onDrag { NSItemProvider(object: "frontstage-card:\(beat.id)" as NSString) }
            .dropDestination(for: String.self) { values, _ in move(values, after: false) } isTargeted: { dropBefore = $0 }
            .onExitCommand { finish(false) }
            .onChange(of: focused) { _, value in if !value { finish(true) } }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            synopsis
            Rectangle().fill(dropAfter ? Color.accentColor : Color.clear).frame(height: 12)
                .dropDestination(for: String.self) { values, _ in move(values, after: true) } isTargeted: { dropAfter = $0 }
        }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number) ·")
            if editing == "title" {
                TextField("Beat title", text: $draft).focused($focused).onSubmit { finish(true) }
            } else {
                Text(beat.title.isEmpty ? "Untitled Beat" : beat.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { begin("title") }
            }
            Spacer(minLength: 0)
        }.padding(8).background(Color.secondary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4)).padding(10)
    }
    @ViewBuilder private var synopsis: some View {
        if editing == "synopsis" {
            TextEditor(text: $draft).frame(minHeight: 130).focused($focused).accessibilityLabel("Beat summary")
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.command) || press.modifiers.contains(.control) { finish(true); return .handled }
                    return .ignored
                }
        } else {
            Text(beat.synopsis.isEmpty ? "Double-click to add a summary…" : beat.synopsis)
                .font(.callout).foregroundStyle(beat.synopsis.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true).padding(10)
                .onTapGesture(count: 2) { begin("synopsis") }
            if beat.synopsis.count > 220 { Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.caption).padding(.horizontal, 10) }
        }
    }
    @ViewBuilder private var actions: some View {
        Button("Edit title") { begin("title") }.disabled(locked)
        Button("Edit summary") { begin("synopsis") }.disabled(locked)
        Button("Pull Out Scene") { workspace.edit("Pull Out Scene") { try $0.pullOutBeats([beat.id]) } }.disabled(locked)
    }
    private func begin(_ field: String) { guard !locked else { return }; editing = field; draft = field == "title" ? beat.title : beat.synopsis; focused = true }
    private func finish(_ save: Bool) {
        guard let field = editing else { return }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.hasMarkedText() { return }
        editing = nil
        if save { workspace.edit("Beat Card", key: "card-\(beat.id)-\(field)") { try $0.updateBeatCard(beat.id, title: field == "title" ? draft : nil, synopsis: field == "synopsis" ? draft : nil) } }
    }
    private func move(_ values: [String], after: Bool) -> Bool {
        guard let value = values.first, value.hasPrefix("frontstage-card:") else { return false }
        let id = String(value.dropFirst("frontstage-card:".count)); guard id != beat.id else { return false }
        let ordered = workspace.whiteboard.orderedBeats.filter { $0.id != id }, index = ordered.firstIndex { $0.id == beat.id }!
        let target = after ? (index + 1 < ordered.count ? ordered[index + 1].id : nil) : beat.id
        workspace.edit("Reorder Scene") { project in
            let board = try project.whiteboard()
            guard !project.scenes.contains(where: { scene in scene.isTextLocked && board.beats.contains { ($0.id == id || $0.id == target) && $0.sceneID == scene.id } }) else { throw ProjectError.invalidProject("Unlock the scene before reordering") }
            try project.reorderTimelineBeats([id], before: target)
        }; return true
    }
}
struct SceneConversionReview: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [Decimal: [String: Set<String>]] = [:]
    @State private var original: Project?
    private var source: Project { original ?? workspace.project }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Review Converted Copy").font(.title2)
            Text("The original stays unchanged. Select destinations for shared data; selecting more than one explicitly copies it. Original history and unknown fields remain in legacy reference.")
            ScrollView {
                ForEach((try? source.sceneConversionGroups()) ?? []) { group in
                    VStack(alignment: .leading) {
                        Text(group.scene.title).font(.headline)
                        if group.conflict { Text("Titles or summaries differ. The converted scenes use each whiteboard beat's title and synopsis.").foregroundStyle(.orange) }
                        ForEach(group.beats) { beat in Text(beat.title + " — " + (beat.synopsis.isEmpty ? "No summary" : beat.synopsis)) }
                        ForEach(["notes", "breakdown", "attachments", "production"], id: \.self) { category in
                            DisclosureGroup(category.capitalized) {
                                ForEach(group.beats) { beat in
                                    Toggle(beat.title, isOn: Binding(get: { (choices[group.id]?[category] ?? Set(group.beats.prefix(1).map(\.id))).contains(beat.id) }, set: { included in
                                        var selected = choices[group.id]?[category] ?? Set(group.beats.prefix(1).map(\.id))
                                        if included { selected.insert(beat.id) } else { selected.remove(beat.id) }
                                        choices[group.id, default: [:]][category] = selected
                                    }))
                                }
                            }
                        }
                    }.padding(10)
                }
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Create Converted Copy") {
                do { let copy = try source.convertedSceneCopy(choices: choices); try workspace.acceptConvertedCopy(copy); dismiss() }
                catch { workspace.errorMessage = error.localizedDescription }
            }.disabled(workspace.sharedProjects.linked?.access == "reader") }
        }.padding(20).frame(width: 660, height: 600).onAppear { original = workspace.project }
    }
}

struct WriteInspector: View {
    @ObservedObject var workspace: Workspace
    @AppStorage("write-right-tab") private var tab = "Notes"
    @AppStorage("write-note-scope") private var scope = "Scene"
    private var scene: FrontstageCore.Scene? { workspace.project.scenes.first { $0.id == workspace.selectedSceneID } }
    private var targetTitle: String {
        if let beat = workspace.selectedBoardBeat, beat.sceneID == scene?.id { return beat.title }
        return scene?.title ?? "Select a scene"
    }
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Inspector", selection: $tab) { ForEach(["Notes", "Breakdown", "History"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if tab == "Notes" {
                Picker("Note scope", selection: $scope) { Text("Scene").tag("Scene"); Text("Project").tag("Project"); Text("Both").tag("Both") }.pickerStyle(.segmented)
                if scope == "Scene" || scope == "Both", let scene { WriteNotesPanel(workspace: workspace, sceneID: scene.id, title: "Scene notes · " + targetTitle).id("scene-notes-\(scene.id)") }
                if scope == "Project" || scope == "Both" { WriteNotesPanel(workspace: workspace, sceneID: nil, title: "Project notes").id("project-notes") }
            } else if let scene {
                if tab == "Breakdown" { WriteBreakdownPanel(workspace: workspace, sceneID: scene.id).id(scene.id) }
                else { WriteHistoryPanel(workspace: workspace, sceneID: scene.id).id(scene.id) }
            } else { Text("Select a scene") }
        }.padding(10).frame(maxHeight: .infinity, alignment: .top)
    }
}
struct WriteNotesPanel: View {
    @ObservedObject var workspace: Workspace
    let sceneID: Decimal?
    let title: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Button("Add Note") { workspace.edit("Add Note") { try $0.addWritingNote(sceneID: sceneID) } }
                if let scratchpad = workspace.project.legacyScratchpad(sceneID: sceneID) { DisclosureGroup("Legacy scratchpad (preserved)") { Text(scratchpad).textSelection(.enabled) } }
                ForEach(workspace.project.writingNotes(sceneID: sceneID)) { note in
                    WriteNoteCard(workspace: workspace, sceneID: sceneID, note: note)
                }
            }
        }
    }
}
struct WriteNoteCard: View {
    @ObservedObject var workspace: Workspace
    let sceneID: Decimal?
    let note: WritingNote
    @State private var editorHeight: CGFloat = 80
    var body: some View {
        VStack(alignment: .leading) {
            if note.editable {
                NoteRichEditor(
                    html: Binding(get: { workspace.project.writingNotes(sceneID: sceneID).first { $0.id == note.id }?.content ?? note.content },
                                  set: { value in workspace.edit("Note Text", key: "note-\(note.id)") { try $0.updateWritingNote(sceneID: sceneID, id: note.id, content: value) } }),
                    color: note.color,
                    onHeightChange: { height in
                        editorHeight = height
                    }
                )
                .frame(height: max(70, editorHeight))
                .accessibilityLabel("Note text")
                Picker("Note color", selection: Binding(get: { note.color }, set: { color in workspace.edit("Note Color") { try $0.updateWritingNote(sceneID: sceneID, id: note.id, color: color) } })) {
                    ForEach(Array(zip(["#fff4bc", "#d9edff", "#e1f4dc", "#f8dce7", "#ffffff"], ["Yellow", "Blue", "Green", "Pink", "White"])), id: \.0) { color, name in
                        Label { Text(name) } icon: { Circle().fill(Color(boardHex: color)).frame(width: 12, height: 12).overlay(Circle().stroke(.gray)) }.tag(color)
                    }
                }
                HStack {
                    Button("↑") { workspace.edit("Move Note") { try $0.moveWritingNote(sceneID: sceneID, id: note.id, offset: -1) } }.accessibilityLabel("Move Note Up")
                    Button("↓") { workspace.edit("Move Note") { try $0.moveWritingNote(sceneID: sceneID, id: note.id, offset: 1) } }.accessibilityLabel("Move Note Down")
                    Button("Delete Note") { workspace.edit("Delete Note") { try $0.removeWritingNote(sceneID: sceneID, id: note.id) } }
                }
            } else { Text("Imported note · preserved read-only"); Text(note.content.localizedCaseInsensitiveContains("<audio") ? "Audio recording retained in the project" : note.content).textSelection(.enabled) }
        }.foregroundStyle(Color(white: 0.13)).disabled(workspace.sharedProjects.linked?.access == "reader" || (sceneID != nil && workspace.project.scenes.first { $0.id == sceneID }?.isTextLocked == true)).padding(8).background(Color(boardHex: note.color)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
final class NoteTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if isEditable, index < string.utf16.count {
            let value = (string as NSString).substring(with: NSRange(location: index, length: 1))
            if value == "☐" || value == "☑" {
                insertText(value == "☐" ? "☑" : "☐", replacementRange: NSRange(location: index, length: 1)); return
            }
        }
        super.mouseDown(with: event)
    }
}
// A separate rich text view keeps note formatting and input focus independent of screenplay controllers.
struct NoteRichEditor: NSViewRepresentable {
    @Binding var html: String
    var color = "#fff4bc"
    var onHeightChange: ((CGFloat) -> Void)? = nil
    static let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    func configure(_ scroll: NSScrollView, _ text: NSTextView) {
        let background = NSColor(Color(boardHex: color))
        scroll.drawsBackground = true; scroll.backgroundColor = background
        text.drawsBackground = true; text.backgroundColor = background; text.textColor = Self.ink; text.insertionPointColor = Self.ink
        text.typingAttributes[.foregroundColor] = Self.ink
        if let storage = text.textStorage, storage.length > 0 { storage.addAttribute(.foregroundColor, value: Self.ink, range: NSRange(location: 0, length: storage.length)) }
    }
    func makeCoordinator() -> Coordinator { Coordinator($html, onHeightChange: onHeightChange) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), text = NoteTextView()
        text.isRichText = true; text.isEditable = context.environment.isEnabled; text.allowsUndo = true; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator; scroll.documentView = text; scroll.hasVerticalScroller = false
        context.coordinator.load(html, text); configure(scroll, text)
        context.coordinator.measure(text)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.binding = $html
        context.coordinator.onHeightChange = onHeightChange
        (view.documentView as? NSTextView)?.isEditable = context.environment.isEnabled
        if let text = view.documentView as? NSTextView, !text.hasMarkedText() {
            if context.coordinator.last != html { context.coordinator.load(html, text) }
            configure(view, text)
            context.coordinator.measure(text)
        }
    }
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>; var last = ""
        var onHeightChange: ((CGFloat) -> Void)?
        init(_ binding: Binding<String>, onHeightChange: ((CGFloat) -> Void)? = nil) {
            self.binding = binding
            self.onHeightChange = onHeightChange
        }
        func measure(_ text: NSTextView) {
            guard let layoutManager = text.layoutManager, let textContainer = text.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let height = max(70, ceil(used.height + text.textContainerInset.height * 2 + 12))
            DispatchQueue.main.async { [weak self] in
                self?.onHeightChange?(height)
            }
        }
        func load(_ html: String, _ text: NSTextView) {
            last = html
            if let decoded = try? NoteTextCodec.decode(safeHTML(html)) { text.textStorage?.setAttributedString(decoded) }
            measure(text)
        }
        private func safeHTML(_ html: String) -> String {
            let allowed: Set<String> = ["p", "div", "br", "b", "strong", "i", "em", "u", "s", "ul", "ol", "li", "blockquote", "h1", "h2", "h3", "pre", "code", "hr", "a"]
            guard let regex = try? NSRegularExpression(pattern: "<[^>]*>") else { return "" }
            var result = html
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let tag = String(result[range]), name = tag.dropFirst().drop(while: { $0 == "/" || $0.isWhitespace }).prefix(while: { $0.isLetter }).lowercased()
                if name == "a", !tag.hasPrefix("</"),
                   let expression = try? NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*["']([^"']+)["']"#),
                   let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                   let linkRange = Range(match.range(at: 1), in: tag), let url = URL(string: String(tag[linkRange])),
                   ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    result.replaceSubrange(range, with: "<a href=\"\(NoteTextCodec.escape(url.absoluteString))\">"); continue
                }
                result.replaceSubrange(range, with: allowed.contains(name) ? "<" + (tag.hasPrefix("</") ? "/" : "") + name + ">" : "")
            }
            return result
        }
        func textView(_ text: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)), !text.hasMarkedText(), text.isEditable else { return false }
            let source = text.string as NSString, selection = text.selectedRange(), range = source.paragraphRange(for: selection)
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            let kind = range.location < source.length ? text.attributedString().attribute(NoteTextCodec.blockKey, at: range.location, effectiveRange: nil) as? String : nil
            let prefix = line.hasPrefix("• ") ? "• " : line.hasPrefix("☐ ") || line.hasPrefix("☑ ") ? "☐ " : nil
            guard prefix != nil || ["h1", "h2", "h3", "blockquote"].contains(kind ?? "") else { return false }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NoteRichEditor.ink, NoteTextCodec.blockKey: prefix == "• " ? "li" : "p"]
            if let prefix, line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).isEmpty {
                text.insertText(NSAttributedString(string: "", attributes: attributes), replacementRange: NSRange(location: range.location, length: line.utf16.count))
                text.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NoteRichEditor.ink, NoteTextCodec.blockKey: "p"]
            } else {
                text.insertText(NSAttributedString(string: "\n" + (prefix ?? ""), attributes: attributes), replacementRange: selection)
                text.typingAttributes = attributes
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, !text.hasMarkedText() else { return }
            LiveNoteFormatting.apply(to: text)
            last = NoteTextCodec.encode(text.attributedString()); binding.wrappedValue = last
            measure(text)
        }
    }
}

struct WriteBreakdownPanel: View {
    @ObservedObject var workspace: Workspace
    let sceneID: Decimal
    @State private var search = ""
    @State private var category = BreakdownCategory.props
    @State private var name = ""
    @State private var description = ""
    @State private var quantity = 1
    private var entries: [BreakdownEntry] { workspace.project.breakdownItems(for: sceneID) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("Breakdown · \(workspace.project.scenes.first { $0.id == sceneID }?.title ?? "")").font(.headline)
                TextField("Search breakdown", text: $search)
                Picker("Category", selection: $category) { ForEach(BreakdownCategory.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("Item name", text: $name); TextField("Description", text: $description)
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...100_000)
                Button("Add Requirement") { workspace.edit("Add Requirement") { try $0.addBreakdownItem(sceneID: sceneID, category: category, name: name, count: quantity, notes: description) } }
                Button("Add Selected Script Text") { addSelection() }
                ForEach(BreakdownCategory.allCases, id: \.self) { category in categoryView(category.rawValue, label: category.label) }
                ForEach(Array(Set(entries.map(\.category))).filter { BreakdownCategory(rawValue: $0) == nil }.sorted(), id: \.self) { category in categoryView(category, label: "Imported · " + category) }
            }
        }
    }
    private func addSelection() {
        guard let selection = workspace.writingSelectedQuote, selection.sceneID == sceneID, !selection.text.isEmpty else { workspace.errorMessage = "Select screenplay text in this scene first."; return }
        let quote = selection.text
        workspace.edit("Tag Script Selection") { try $0.addBreakdownItem(sceneID: sceneID, category: category, name: quote, sourceQuote: quote) }
    }
    private func categoryView(_ category: String, label: String) -> some View {
        let items = entries.filter { $0.category == category }
        return DisclosureGroup("\(label) (\(items.count))") {
            ForEach(items.filter { search.isEmpty || ($0.name + " " + $0.notes).localizedCaseInsensitiveContains(search) }) { item in
                VStack(alignment: .leading) {
                    TextField("Requirement name", text: Binding(get: { item.name }, set: { value in workspace.edit("Requirement Name", key: item.id) { try $0.updateBreakdownItem(sceneID: sceneID, itemID: item.id, name: value) } }))
                    TextField("Description", text: Binding(get: { item.notes }, set: { value in workspace.edit("Requirement Description", key: item.id) { try $0.updateBreakdownItem(sceneID: sceneID, itemID: item.id, notes: value) } }))
                    Stepper("Quantity: \(item.count)", value: Binding(get: { item.count }, set: { value in workspace.edit("Requirement Quantity") { try $0.updateBreakdownItem(sceneID: sceneID, itemID: item.id, count: value) } }), in: 1...100_000)
                    if let quote = item.sourceQuote { Text(quote).font(.caption).textSelection(.enabled) }
                    Menu("Move to category") { ForEach(BreakdownCategory.allCases, id: \.self) { target in Button(target.label) { workspace.edit("Move Requirement") { try $0.moveBreakdownItem(sceneID: sceneID, itemID: item.id, category: target) } } } }
                    Button("Delete Requirement") { workspace.edit("Delete Requirement") { try $0.removeBreakdownItem(sceneID: sceneID, itemID: item.id) } }
                }.padding(6)
            }
        }
    }
}
struct WriteHistoryPanel: View {
    @ObservedObject var workspace: Workspace
    let sceneID: Decimal
    @State private var label = ""
    @State private var restore: SceneRevision?
    private func readable(_ html: String) -> String { (try? ScreenplayTextCodec.decode(html).string) ?? html }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("Scene History").font(.headline)
                if !workspace.project.legacySceneRevisions(sceneID).isEmpty {
                    DisclosureGroup("Original history · read-only") {
                        ForEach(workspace.project.legacySceneRevisions(sceneID)) { revision in
                            DisclosureGroup(revision.label) { Text(revision.summary); Text(readable(revision.html)).textSelection(.enabled) }
                        }
                    }
                }
                TextField("Snapshot label", text: $label)
                Button("Capture Snapshot") { guard workspace.scriptController("write-continuous").textView?.hasMarkedText() != true, !workspace.whiteboard.beats.filter({ $0.sceneID == sceneID }).contains(where: { workspace.scriptController($0.id).textView?.hasMarkedText() == true }) else { workspace.errorMessage = "Finish the current text composition before taking a snapshot."; return }; workspace.edit("Capture Snapshot") { try $0.saveRevision(sceneID: sceneID, label: label) } }
                ForEach(workspace.project.revisions(for: sceneID)) { revision in
                    DisclosureGroup(revision.label) {
                        Text(revision.date, style: .date); Text(revision.date, style: .time)
                        Text(revision.summary).font(.caption)
                        ForEach(RevisionDiffLine.compare(before: readable(revision.html), after: readable(workspace.project.scenes.first { $0.id == sceneID }?.html ?? ""))) { line in
                            Text((line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text).font(.caption.monospaced()).foregroundStyle(line.kind == .removed ? .red : line.kind == .added ? .green : .primary).textSelection(.enabled)
                        }
                        let unsafeLegacy = !revision.hasBeatBoundaries && workspace.whiteboard.beats.filter { $0.sceneID == sceneID }.count > 1
                        if unsafeLegacy { Text("This legacy snapshot has no beat boundaries. Restoring a multi-beat scene is unsafe.").font(.caption) }
                        Button("Restore This Snapshot") { restore = revision }.disabled(unsafeLegacy || workspace.project.scenes.first { $0.id == sceneID }?.isTextLocked == true)
                    }
                }
            }
        }.confirmationDialog("Restore this scene? A backup will be created. Notes and breakdown stay unchanged.", isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } })) {
            Button("Restore") { if let revision = restore { workspace.edit("Restore Snapshot") { try $0.restoreRevision(sceneID: sceneID, revisionID: revision.id) } }; restore = nil }
            Button("Cancel", role: .cancel) { restore = nil }
        }
    }
}
#endif
