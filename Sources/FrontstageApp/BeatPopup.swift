#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore

@MainActor
final class BeatEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func focusSlugline() {
        guard let content = contentView else { return }
        let prefixField = findField("beatPopupSluglinePrefix", in: content)
        let locationField = findField("beatPopupSluglineLocation", in: content)
        let isLocationFocused = firstResponder === locationField || (firstResponder as? NSText)?.delegate === locationField
        let target: NSTextField?
        if isLocationFocused {
            target = prefixField ?? locationField
        } else {
            if let p = prefixField, p.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target = p
            } else {
                target = locationField ?? prefixField
            }
        }
        if let target {
            makeFirstResponder(target)
            target.selectText(nil)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers == "1" {
            focusSlugline()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { close(); return }
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.control),
               !event.modifierFlags.contains(.option),
               event.charactersIgnoringModifiers == "1" {
                focusSlugline()
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class BeatPopupPresenter: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    private(set) var beatID: String?
    private(set) var controller: ScreenplayEditorController?
    private(set) var panels: [String: NSPanel] = [:]
    private var controllers: [String: ScreenplayEditorController] = [:]
    func controller(for id: String) -> ScreenplayEditorController? { controllers[id] }
    func focusedController(in focusedWindow: NSWindow?) -> ScreenplayEditorController? {
        guard let focusedWindow else { return nil }
        return controllers.values.first { editor in
            guard let text = editor.textView, let window = text.window else { return false }
            return focusedWindow === window && window.firstResponder === text
        }
    }
    func refreshTitles(_ board: Whiteboard) {
        guard !panels.isEmpty else { return }
        let titles = Dictionary(uniqueKeysWithValues: board.beats.map { ($0.id, $0.title) })
        for (id, window) in panels { window.title = titles[id] == nil ? "Beat removed" : "Edit Beat" }
    }

    func open(_ id: String, workspace: Workspace, near anchor: NSRect? = nil) {
        guard let beat = workspace.whiteboard.beats.first(where: { $0.id == id }) else { return }
        if let panel = panels[id] {
            panel.makeKeyAndOrderFront(nil)
            if !beat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, beat.title != "Untitled Beat", let text = controllers[id]?.textView { panel.makeFirstResponder(text) }
            else if let content = panel.contentView {
                @MainActor func nameField(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.placeholderString == "Beat Name" { return field }
                    return view.subviews.lazy.compactMap { nameField($0) }.first
                }
                nameField(content)?.selectText(nil)
            }
            return
        }
        let editor = ScreenplayEditorController()
        let panel = BeatEditorPanel(contentRect: NSRect(x: 0, y: 0, width: WorkspaceDesign.popupWidth, height: WorkspaceDesign.popupHeight),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        editor.onSceneHeadingRequested = { [weak panel] in
            panel?.focusSlugline()
        }
        panel.title = "Edit Beat"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 440)
        panel.delegate = self
        let hosting = NSHostingView(rootView: BeatPopupView(workspace: workspace, beatID: id, controller: editor, dismiss: { [weak self] in self?.close(id) }).preferredColorScheme(.dark))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 5
        panel.contentView = hosting
        let screen = NSScreen.screens.first { screen in anchor.map { screen.frame.intersects($0) } ?? false } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var point = anchor.map { NSPoint(x: $0.maxX + 12, y: $0.maxY - panel.frame.height) }
            ?? NSPoint(x: visible.midX - 330 + CGFloat(panels.count % 6) * 28, y: visible.midY - 370 - CGFloat(panels.count % 6) * 28)
        point.x = min(max(visible.minX + 8, point.x), visible.maxX - panel.frame.width - 8)
        point.y = min(max(visible.minY + 8, point.y), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(point)
        self.panel = panel; beatID = id; controller = editor
        panels[id] = panel; controllers[id] = editor
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        if !beat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, beat.title != "Untitled Beat" {
            panel.initialFirstResponder = editor.textView
            if let text = editor.textView { panel.makeFirstResponder(text) }
            DispatchQueue.main.async { [weak panel, weak editor] in
                if let text = editor?.textView { panel?.makeFirstResponder(text) }
            }
        }
    }

    func close() {
        for id in Array(panels.keys) { close(id) }
        panel = nil; beatID = nil; controller = nil
    }
    func close(_ id: String) {
        guard let window = panels[id] else { return }
        window.close()
        window.contentView = nil
        panels.removeValue(forKey: id); controllers.removeValue(forKey: id)
        if beatID == id { panel = nil; beatID = nil; controller = nil }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, let id = panels.first(where: { $0.value === window })?.key else { return }
        panel = window; beatID = id; controller = controllers[id]
        controller?.selectionChanged()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, let id = panels.first(where: { $0.value === window })?.key else { return }
        panels.removeValue(forKey: id); controllers.removeValue(forKey: id)
        window.contentView = nil
        if beatID == id { panel = nil; beatID = nil; controller = nil }
        TamilInputManager.restoreStandardInput()
    }
}

struct BeatPopupView: View {
    @ObservedObject var workspace: Workspace
    let beatID: String
    @ObservedObject var controller: ScreenplayEditorController
    let dismiss: () -> Void
    private var beat: BoardBeat? { workspace.whiteboard.beats.first { $0.id == beatID } }

    private func text(_ path: WritableKeyPath<BoardBeat, String>, label: String) -> Binding<String> {
        Binding(get: { beat?[keyPath: path] ?? "" }, set: { value in
            workspace.edit(label, key: "popup-\(beatID)-\(label)") { try $0.updateBoardBeat(beatID) { $0[keyPath: path] = value } }
        })
    }

    @FocusState private var nameFocused: Bool
    @State private var scriptExpanded = true
    @State private var showTools = false
    private var scene: FrontstageCore.Scene? { beat.flatMap { b in workspace.project.scenes.first { $0.id == b.sceneID } } }
    private func heading(_ key: WritableKeyPath<SceneHeading, String>) -> Binding<String> {
        Binding(get: { scene?.heading[keyPath: key] ?? "" }, set: { value in
            guard let scene else { return }; var heading = scene.heading; heading[keyPath: key] = value.uppercased()
            workspace.updateScene(id: scene.id, heading: heading)
        })
    }
    @ViewBuilder private var metadata: some View {
        if let beat {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    HStack { Text("Beat Name").frame(width: 80, alignment: .leading); TextField("Beat Name", text: text(\.title, label: "Beat Title")).focused($nameFocused) }
                    HStack { Text("Synopsis").frame(width: 80, alignment: .leading); TextField("Synopsis", text: text(\.synopsis, label: "Beat Synopsis"), axis: .vertical).lineLimit(2...3) }
                    HStack { Text("Visibility").frame(width: 80, alignment: .leading)
                        Picker("Visibility", selection: Binding(get: { beat.omitted }, set: { value in workspace.edit("Beat Visibility") { try $0.updateBoardBeat(beatID) { $0.omitted = value } } })) {
                            Text("Visible In Script").tag(false); Text("Hidden In Script").tag(true)
                        }.labelsHidden()
                        Label(workspace.whiteboard.isUnused(beat) ? "Beat is unused" : "Beat is used", systemImage: workspace.whiteboard.isUnused(beat) ? "circle" : "checkmark.circle.fill").font(.caption).foregroundStyle(workspace.whiteboard.isUnused(beat) ? Color.secondary : Color.green)
                    }
                }.frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Characters"); Menu("⊕") { ForEach(workspace.project.characters, id: \.id) { character in
                        Button(character.name) { workspace.edit("Beat Characters") { try $0.updateBoardBeat(beatID) { if !$0.characters.contains(character.name) { $0.characters.append(character.name) } } } }
                    } }.fixedSize() }
                    BeatReferenceChips(characters: beat.characters, tags: [])
                    TextField("Add names, separated by commas", text: Binding(get: { beat.characters.joined(separator: ", ") }, set: { value in workspace.edit("Beat Characters", key: "characters-\(beatID)") { try $0.updateBoardBeat(beatID) { $0.characters = value.boardList } } })).font(.caption)
                    Text("Tags ⊕")
                    BeatReferenceChips(characters: [], tags: beat.tags)
                    TextField("Add tags, separated by commas", text: Binding(get: { beat.tags.joined(separator: ", ") }, set: { value in workspace.edit("Beat Tags", key: "tags-\(beatID)") { try $0.updateBoardBeat(beatID) { $0.tags = value.boardList } } })).font(.caption)
                }.frame(width: 270)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var scriptControls: some View {
        if let scene {
            HStack {
                Text("Version").frame(width: 80, alignment: .leading)
                Picker("Version", selection: Binding(get: { "" }, set: { id in if !id.isEmpty { workspace.edit("Restore Scene Version") { try $0.restoreRevision(sceneID: scene.id, revisionID: id) } } })) {
                    Text("Untitled Version (current)").tag("")
                    ForEach(workspace.project.revisions(for: scene.id)) { version in Text(version.label).tag(version.id) }
                }.labelsHidden()
                Button("Save Version") { let label = "Version \(workspace.project.revisions(for: scene.id).count + 1)"; workspace.edit("Save Scene Version") { _ = try $0.saveRevision(sceneID: scene.id, label: label) } }
                Picker("Action", selection: Binding(get: { controller.activeElement }, set: { elem in
                    if elem == .sceneHeading {
                        controller.onSceneHeadingRequested?()
                    } else {
                        controller.format(elem)
                    }
                })) { ForEach(ScreenplayElement.editable, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 120)
                Button("⋯") { showTools.toggle() }.accessibilityLabel("Formatting options")
            }
            if showTools { HStack { InlineFormatButtons(controller: controller); ScreenplaySuggestions(workspace: workspace, controller: controller) } }
            HStack {
                Text("Location").frame(width: 80, alignment: .leading)
                ScriptSuggestionField(label: "INT. / EXT.", text: heading(\.prefix), options: ["INT.","EXT.","INT./EXT."], identifier: "beatPopupSluglinePrefix").frame(width: 85)
                ScriptSuggestionField(label: "Location", text: heading(\.location), options: Array(Set(workspace.project.scenes.map { $0.heading.location })).sorted(), identifier: "beatPopupSluglineLocation")
                ScriptSuggestionField(label: "DAY / NIGHT", text: heading(\.time), options: ["DAY","NIGHT","MORNING","EVENING","DAWN","DUSK","CONTINUOUS","LATER"], identifier: "beatPopupSluglineTime").frame(width: 180)
            }
        }
    }
    private var popupTypography: ScriptLayoutSettings {
        var layout = workspace.project.scriptLayout
        let targetSize = max(15.0, layout.fontSize * 1.25)
        let scale = targetSize / max(1.0, layout.fontSize)
        layout.fontSize = targetSize
        layout.lineHeight = max(targetSize * 1.35, layout.lineHeight * scale)
        layout.paragraphSpacing = max(10.0, layout.paragraphSpacing * scale)
        for (key, elem) in layout.elements {
            var updated = elem
            if let customSize = elem.fontSize {
                updated.fontSize = max(15.0, customSize * scale)
            }
            layout.elements[key] = updated
        }
        return layout
    }

    var body: some View {
        VStack(spacing: 10) {
            if let beat {
                metadata.padding(.bottom, 10)
                Button { scriptExpanded.toggle() } label: { Text((scriptExpanded ? "▼" : "▶") + " Script").frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                    .buttonStyle(.plain).background(Color(white: 0.13))
                if scriptExpanded {
                    scriptControls.disabled(scene?.isTextLocked == true)
                    ScreenplayEditor(html: text(\.html, label: "Snippet Text"), controller: controller, width: 532, typography: popupTypography,
                        onError: { workspace.errorMessage = $0 }, editable: scene?.isTextLocked != true, paper: true, paperTopInset: 16, suggestions: workspace.screenplayCompletions,
                        continuationSeed: DialoguePresentation.seed(project: workspace.project, beatID: beatID), explicitCharacters: workspace.project.characters.map(\.name) + workspace.whiteboard.beats.flatMap(\.characters)).id(beatID)
                        .frame(maxWidth: .infinity, minHeight: 280).environment(\.colorScheme, .light)
                }
                HStack {
                    Picker("Type", selection: Binding(get: { beat.kind }, set: { value in workspace.edit("Beat Type") { try $0.updateBoardBeat(beatID) { $0.kind = value } } })) { Text("Story Beat").tag(BoardBeatKind.story); Text("Subtext Beat").tag(BoardBeatKind.subtext) }.frame(width: 180)
                    Toggle("Must Be Caused", isOn: Binding(get: { beat.mustBeCaused }, set: { value in workspace.edit("Cause Requirement") { try $0.updateBoardBeat(beatID) { $0.mustBeCaused = value } } }))
                    Spacer(); Button("Split at Cursor") { workspace.splitBoardBeat(beatID, controller: controller) }
                }.font(.caption)
                Button("Close", action: dismiss).frame(width: 100).keyboardShortcut(.cancelAction)
            } else { Text("This beat was removed"); Button("Close", action: dismiss) }
        }.padding(18).textFieldStyle(.roundedBorder).background(Color(white: 0.267))
        .onAppear {
            if beat?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || beat?.title == "Untitled Beat" { nameFocused = true }

        }
        .onExitCommand(perform: dismiss)
    }
}

extension String {
    var boardList: [String] {
        var seen = Set<String>()
        return split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension Color {
    init(boardHex value: String) {
        let rgb = UInt32(value.hasPrefix("#") ? String(value.dropFirst()) : value, radix: 16) ?? 0xa34eae
        self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

extension Workspace {
    func openBoardResearch(_ id: String) {
        var record = (try? project.studio().records.first { $0.beatID == id && $0.kind == .research })?.id
        let beat = whiteboard.beats.first { $0.id == id }
        if record == nil {
            edit("Add Beat Research") { record = try $0.addStudioRecord(kind: .research, title: beat?.title ?? "Beat Research", sceneID: beat?.sceneID, beatID: id) }
        }
        selectedResearchID = record; mode = .studio
    }

    var whiteboard: Whiteboard { whiteboardCache ?? (try? project.whiteboard()) ?? Whiteboard() }
    var selectedBoardBeat: BoardBeat? { whiteboard.beats.first { $0.id == selectedBoardBeatID } }

    func selectBoardBeat(_ id: String) {
        selectedBoardBeatID = id
        if let beat = whiteboard.beats.first(where: { $0.id == id }) { selectedSceneID = beat.sceneID }
    }

    func createBeatGroup(_ selection: Set<String>) {
        if selection.isEmpty {
            var created: String?
            edit("Create Beat Group") { project in
                created = try project.addBoardBeat(position: .init(x: max(70, (whiteboard.blocks.map { $0.position.x + $0.width }.max() ?? -214) + 60), y: 70))
                if let created { try project.editWhiteboard { board in
                    let owner = board.beats.first { $0.id == created }?.blockID
                    if let i = board.blocks.firstIndex(where: { $0.id == owner }) { board.blocks[i].containerKind = "beatGroup"; board.blocks[i].name = "Beat Group" }
                } }
            }
            if let created { selectBoardBeat(created); popup.open(created, workspace: self) }
        } else { edit("Group Beats") { try $0.groupBoardBeats(selection) } }
    }

    func addWhiteboardBeat(blockID: String? = nil, layerID: String = "main", position: BoardPoint? = nil, before: String? = nil, standalone: Bool = true, sceneID: Decimal? = nil, after: String? = nil) {
        var created: String?
        let location = position ?? BoardPoint(x: min(900000, max(70, (whiteboard.blocks.map { $0.position.x + $0.width }.max() ?? -214) + 60)), y: 70)
        edit("Add Whiteboard Beat") { project in
            created = try project.addBoardBeat(blockID: blockID, layerID: layerID, position: location, sceneID: sceneID)
            if blockID == nil, standalone, let created {
                try project.editWhiteboard { board in
                    if let owner = board.beats.first(where: { $0.id == created })?.blockID,
                       let index = board.blocks.firstIndex(where: { $0.id == owner }) { board.blocks[index].standalone = true }
                }
            }
            if let created, let after {
                try project.editWhiteboard { board in
                    let ordered = board.orderedBeats.filter { $0.id != created }
                    if let index = ordered.firstIndex(where: { $0.id == after }), let target = board.beats.firstIndex(where: { $0.id == created }) {
                        board.beats[target].order = (ordered[index].order + (index + 1 < ordered.count ? ordered[index + 1].order : ordered[index].order + 2)) / 2
                    }
                }
            }
            if let created, let blockID, let before { try project.moveBoardBeat(created, toBlock: blockID, before: before) }
        }
        if let created { selectBoardBeat(created); popup.open(created, workspace: self) }
    }

    func splitBoardBeat(_ id: String, controller: ScreenplayEditorController? = nil) {
        guard let beat = whiteboard.beats.first(where: { $0.id == id }) else { return }
        do {
            let source = try ScreenplayTextCodec.decode(beat.html)
            let caret = (controller ?? popup.controller(for: id))?.textView?.selectedRange().location ?? source.length / 2
            guard caret > 0, caret < source.length else { throw ProjectError.invalidProject("place the cursor inside the snippet before splitting") }
            let first = ScreenplayTextCodec.encode(source.attributedSubstring(from: NSRange(location: 0, length: caret)))
            let second = ScreenplayTextCodec.encode(source.attributedSubstring(from: NSRange(location: caret, length: source.length - caret)))
            var created: String?
            edit("Split Beat") { created = try $0.splitBoardBeat(id, firstHTML: first, secondHTML: second) }
            if let created { selectBoardBeat(created); popup.open(created, workspace: self) }
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
