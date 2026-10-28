#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore

struct ScriptWritingWorkspace: View {
    @ObservedObject var workspace: Workspace
    @AppStorage("frontstage-script-dedicated-display") private var display = "Final Script"
    @AppStorage("frontstage-script-dedicated-margin") private var margin = "Full Margins"
    @AppStorage("frontstage-script-dedicated-zoom") private var zoom = 1.0
    @AppStorage("frontstage-script-dedicated-characters") private var showCharacters = true
    @AppStorage("frontstage-script-dedicated-tags") private var showTags = true
    @AppStorage("frontstage-script-dedicated-synopsis") private var showSynopsis = false
    @AppStorage("frontstage-script-dedicated-boundaries") private var showBoundaries = false
    @AppStorage("frontstage-script-show-omitted") private var showOmitted = false
    @AppStorage("frontstage-write-paper-theme") private var paperTheme = "White"
    @State private var filter = ""
    @State private var activeController: ScreenplayEditorController?
    @State private var headingID: Decimal?
    @State private var toggled: Set<String> = []
    @State private var hiddenTarget: String?
    private var segments: [ScriptSegment] { (try? workspace.project.orderedScript(includeInactive: true)) ?? [] }
    private var plain: Bool { display == "Final Script" || display == "Content Only" }
    private var inset: CGFloat { margin == "Full Margins" ? workspace.paper.leftMargin : margin == "Compact Margins" ? 16 : margin == "Squeezed" ? 8 : 3 }
    private var contentWidth: CGFloat { margin == "Squeezed" ? 404 : margin == "Super Squeezed" ? 354 : workspace.paper.contentWidth }
    private func matches(_ beat: BoardBeat) -> Bool { workspace.reader.filters.matches(beat, board: workspace.whiteboard, scenes: workspace.project.scenes) && (filter.isEmpty || ([beat.title, beat.synopsis, beat.html] + beat.characters + beat.tags).joined(separator: " ").localizedCaseInsensitiveContains(filter)) }
    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    workspace.toggleInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector Panel")
                Menu {
                    Menu("Display") {
                        Picker("Beat Display", selection: $display) { ForEach(["Expand All", "Index Cards", "Collapse All", "Content Only", "Final Script"], id: \.self) { Text($0) } }
                        Divider()
                        Toggle("Show Characters", isOn: $showCharacters); Toggle("Show Tags", isOn: $showTags)
                        Toggle("Show Omitted Preview", isOn: $showOmitted)
                        Toggle("Show Synopsis", isOn: $showSynopsis); Toggle("Show Block/Group Beginnings", isOn: $showBoundaries)
                        Picker("Margins", selection: $margin) { ForEach(["Full Margins", "Compact Margins", "Squeezed", "Super Squeezed"], id: \.self) { Text($0) } }
                        Button("Zoom In") { zoom = min(2, zoom + 0.1) }; Button("Zoom Out") { zoom = max(0.5, zoom - 0.1) }; Button("100%") { zoom = 1 }
                    }
                    Menu("Styling") {
                        ForEach(ScreenplayElement.editable, id: \.self) { element in Button(element.label) { activeController?.format(element) } }
                        Divider()
                        ForEach(["bold", "italic", "underline"], id: \.self) { style in Button(style.capitalized) { activeController?.toggleInlineStyle(style) } }
                    }
                    .disabled(activeController?.textView?.isEditable != true)
                    ScriptFilterMenu(workspace: workspace, state: $workspace.reader.filters).id(workspace.documentSessionID)
                    Menu("Presets") {
                        Button("Reading") { display = "Final Script"; margin = "Full Margins"; zoom = 1; filter = "" }
                        Button("Story Review") { display = "Expand All" }
                        Button("Index Cards") { display = "Index Cards" }
                    }
                    Menu("Options") {
                        Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                        Button("Writing Settings") { workspace.mode = .writingTools }
                    }
                } label: { Label("Writing options", systemImage: "ellipsis.circle") }
                Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = max(0.5, zoom - 0.1) }.labelStyle(.iconOnly)
                Text("\(Int((zoom * 100).rounded()))%")
                Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = min(2, zoom + 0.1) }.labelStyle(.iconOnly)
                Picker("Paper theme", selection: $paperTheme) { ForEach(WritingPaperTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden().frame(width: 85)
                if let rev = workspace.project.currentRevision {
                    Button {
                        workspace.mode = .writingTools
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(rev.color.swiftUIColor)
                                .frame(width: 8, height: 8)
                            Text(rev.label.uppercased())
                                .font(.system(size: 10, weight: .bold))
                            if rev.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("Production Revision: \(rev.label) (\(rev.isLocked ? "Locked" : "Unlocked")). Click to configure.")
                } else {
                    Button {
                        workspace.mode = .writingTools
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.open")
                                .font(.system(size: 9))
                            Text("Spec Draft")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Script is in unlocked Spec Draft mode. Click to start production revisions.")
                }
            }.font(.caption).padding(10).fixedSize()
        }.frame(height: 40).background(Color(white: 0.2)).accessibilityIdentifier("dedicated-script-tools")
    }
    var body: some View {
        ScrollViewReader { proxy in
        WritePagePanels(workspace: workspace, navigate: { sceneID, beatID in
            if let beatID, let beat = workspace.whiteboard.beats.first(where: { $0.id == beatID }) {
                if !matches(beat) || beat.omitted || workspace.whiteboard.isUnused(beat) { hiddenTarget = beatID; return }
                if plain, let text = workspace.scriptController("write-continuous").textView as? WritingTextView {
                    text.revealBeat?(beatID)
                } else { workspace.selectBoardBeat(beatID); proxy.scrollTo(beatID, anchor: .center) }
            } else { workspace.selectedSceneID = sceneID; proxy.scrollTo("scene-\(sceneID)", anchor: .center) }
        }) {
        VStack(spacing: 0) {
            tools
            WriterElementBar(controller: plain ? workspace.scriptController("write-continuous") : (activeController ?? workspace.editor))
            if showOmitted {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Omitted beats — outside the active screenplay").bold()
                        ForEach(workspace.whiteboard.orderedBeats.filter { $0.omitted }) { beat in
                            VStack(alignment: .leading) {
                                Text(beat.title).bold()
                                Text((try? ScreenplayTextCodec.decode(beat.html).string) ?? "").textSelection(.enabled)
                                Button("Include Beat") { workspace.edit("Include Beat") { try $0.setBeatOmitted(beat.id, omitted: false) } }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.gray.opacity(0.15))
                        }
                    }.padding(12)
                }.frame(maxHeight: 220)
            }
            if plain {
                ContinuousScriptEditor(workspace: workspace, controller: workspace.scriptController("write-continuous"), width: contentWidth, zoom: zoom, theme: WritingPaperTheme(rawValue: paperTheme) ?? .white)
                    .onAppear { activeController = workspace.scriptController("write-continuous") }
            } else {
            ScrollView([.vertical, .horizontal]) {
                if segments.isEmpty { ContentUnavailableView("Your next story starts here", systemImage: "doc.richtext", description: Text("Add a scene or a beat to begin.")) }
                else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let beats = segment.beatIDs.compactMap { id in workspace.whiteboard.beats.first { $0.id == id } }.filter(matches)
                            if !beats.isEmpty || segment.beatIDs.isEmpty {
                                if display != "Index Cards" && !workspace.reader.filters.hideHeadings { heading(segment) }
                                if segment.beatIDs.isEmpty {
                                    snippet(sceneID: segment.scene.id, beatID: nil, key: "scene-\(segment.scene.id)")
                                } else { ForEach(beats) { beat in
                                    if let gap = workspace.reader.filters.gap(before: beat.id, board: workspace.whiteboard, scenes: workspace.project.scenes) { Text(gap).font(.caption).padding(10) }
                                    beatView(beat) } }
                            }
                        }
                        Spacer(minLength: 24)
                    }.frame(width: contentWidth * zoom, alignment: .topLeading)
                        .padding(.leading, inset * zoom).padding(.trailing, (margin == "Full Margins" ? workspace.paper.rightMargin : inset) * zoom)
                        .padding(.vertical, workspace.paper.topMargin * zoom)
                        .frame(minHeight: workspace.paper.height * zoom, alignment: .topLeading)
                        .background(Color.white).environment(\.colorScheme, .light).foregroundStyle(.black)
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 3).padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(white: 0.47))
            }
        }
        }
        .alert("This beat is hidden by screenplay filters", isPresented: Binding(get: { hiddenTarget != nil }, set: { if !$0 { hiddenTarget = nil } })) {
            Button("Reset filters and reveal") { if let id = hiddenTarget { workspace.reader.filters = ScriptFilters(); filter = ""; workspace.selectBoardBeat(id); if let beat = workspace.whiteboard.beats.first(where: { $0.id == id }), beat.omitted || workspace.whiteboard.isUnused(beat) { workspace.popup.open(id, workspace: workspace) } else { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } } }; hiddenTarget = nil }
            Button("Cancel", role: .cancel) { hiddenTarget = nil }
        }
        }.onAppear { display = "Final Script" }.onChange(of: display) { _, _ in toggled.removeAll(); activeController = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { _ in
            guard let controller = workspace.focusedScreenplayController else { return }
            let keys = ["write-continuous"] + segments.flatMap { $0.beatIDs.isEmpty ? ["scene-\($0.scene.id)"] : $0.beatIDs }
            if let key = keys.first(where: { workspace.scriptController($0) === controller }) { activeController = controller; if let beat = workspace.whiteboard.beats.first(where: { $0.id == key }) { workspace.selectBoardBeat(beat.id)
                if let text = controller.textView, text.selectedRange().length > 0, NSMaxRange(text.selectedRange()) <= (text.string as NSString).length { workspace.writingSelectedQuote = (beat.sceneID, (text.string as NSString).substring(with: text.selectedRange())) }
            } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { _ in
            guard let controller = workspace.focusedScreenplayController else { return }
            let keys = ["write-continuous"] + segments.flatMap { $0.beatIDs.isEmpty ? ["scene-\($0.scene.id)"] : $0.beatIDs }
            if let key = keys.first(where: { workspace.scriptController($0) === controller }) { activeController = controller; if let beat = workspace.whiteboard.beats.first(where: { $0.id == key }) { workspace.selectBoardBeat(beat.id)
                if let text = controller.textView, text.selectedRange().length > 0, NSMaxRange(text.selectedRange()) <= (text.string as NSString).length { workspace.writingSelectedQuote = (beat.sceneID, (text.string as NSString).substring(with: text.selectedRange())) }
            } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidBeginEditingNotification)) { _ in activeController = nil }
    }
    private func snippet(sceneID: Decimal, beatID: String?, key: String) -> some View {
        ContinuousSnippet(workspace: workspace, sceneID: sceneID, beatID: beatID, controller: workspace.scriptController(key), readerWidth: contentWidth * zoom, showControls: false, displayScale: zoom)
    }
    private func heading(_ segment: ScriptSegment) -> some View {
        Text("\(segment.number)  \(segment.scene.heading.text)\(segment.isContinuation ? " (CONTINUED)" : "")")
            .font(.custom(workspace.project.scriptLayout.fontName, size: workspace.project.scriptLayout.fontSize * zoom).weight(.bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
    private func beatView(_ beat: BoardBeat) -> some View {
        let expanded = (display != "Collapse All") != toggled.contains(beat.id)
        return VStack(alignment: .leading, spacing: 0) {
            if beat.omitted || workspace.whiteboard.isUnused(beat) { Text(workspace.whiteboard.isUnused(beat) ? "Unused lane · excluded from export" : "Disabled beat · excluded from export").font(.caption).foregroundStyle(.secondary).padding(5) }
            if !plain {
                Button { if !toggled.insert(beat.id).inserted { toggled.remove(beat.id) } } label: {
                    Text((expanded ? "▾ " : "▸ ") + beat.title).lineLimit(nil).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }.buttonStyle(.plain).background(Color(boardHex: beat.color).opacity(0.2))
                if display != "Index Cards" { BeatReferenceChips(characters: showCharacters ? beat.characters : [], tags: showTags ? beat.tags : []) }
                if showSynopsis || display == "Index Cards" { Text(beat.synopsis).font(.caption).padding(6) }
                if showBoundaries && !workspace.reader.filters.hideBreaks, let owner = workspace.whiteboard.blocks.first(where: { $0.id == beat.blockID }), owner.standalone != true, workspace.whiteboard.orderedBeats.first(where: { $0.blockID == owner.id })?.id == beat.id { Text(owner.name).font(.caption).padding(4) }
            }
            if display != "Index Cards", plain || expanded { snippet(sceneID: beat.sceneID, beatID: beat.id, key: beat.id) }
            if display == "Content Only" { Color.gray.frame(height: 6).padding(.vertical, 8) }
        }.id(beat.id).contextMenu {
            Button("Split at Cursor") { workspace.splitBoardBeat(beat.id, controller: workspace.scriptController(beat.id)) }.disabled(workspace.whiteboard.isLocked(beat) || activeController !== workspace.scriptController(beat.id))
            Button("Open Beat Editor") { workspace.popup.open(beat.id, workspace: workspace) }
            Button("Select on Whiteboard") { workspace.selectBoardBeat(beat.id); workspace.mode = .board }
        }
    }
}

struct ContinuousSnippet: View {
    @ObservedObject var workspace: Workspace
    let sceneID: Decimal
    let beatID: String?
    @ObservedObject var controller: ScreenplayEditorController
    var compact = false
    var readerWidth: CGFloat = 520
    var readerZoom: Double = 1
    var showControls = true
    var displayScale = 1.0
    private var displayTypography: ScriptLayoutSettings { var value = workspace.project.scriptLayout; if compact { value.fontSize = max(14, value.fontSize) * readerZoom; value.lineHeight = max(value.lineHeight * readerZoom, value.fontSize * 1.35) }; if !showControls { value.fontSize *= displayScale; value.lineHeight *= displayScale; value.paragraphSpacing *= displayScale }; return value }
    private var beat: BoardBeat? { workspace.whiteboard.beats.first { $0.id == beatID } }
    private var scene: FrontstageCore.Scene? { workspace.project.scenes.first { $0.id == sceneID } }
    private var html: Binding<String> {
        Binding(get: { beatID == nil ? scene?.html ?? "" : beat?.html ?? "" }, set: { value in
            if let beatID { workspace.edit("Snippet Text", key: "script-\(beatID)") { try $0.updateBoardBeat(beatID) { $0.html = value } } }
            else { workspace.updateScene(id: sceneID, html: value) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact && showControls, let beatID, let beat {
                Button(beat.title) { workspace.selectBoardBeat(beatID); workspace.popup.open(beatID, workspace: workspace) }
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.plain)
                    .padding(4).background(Color(white: 0.93))
            }
            if !compact && showControls { HStack {
                Picker("Element", selection: Binding(get: { controller.activeElement }, set: { controller.format($0) })) {
                    ForEach(ScreenplayElement.editable, id: \.self) { Text($0.label).tag($0) }
                }.frame(width: compact ? 120 : 180)
                InlineFormatButtons(controller: controller)
                Spacer()
            }.font(.caption).disabled(scene?.isTextLocked == true)
            ScreenplaySuggestions(workspace: workspace, controller: controller).disabled(scene?.isTextLocked == true)
            }
            ScreenplayEditor(html: html, controller: controller, width: compact || !showControls ? readerWidth : workspace.paper.contentWidth,
                typography: displayTypography, onError: { workspace.errorMessage = $0 }, editable: scene?.isTextLocked != true && !(beat.map { workspace.whiteboard.isLocked($0) } ?? false), continuous: true, suggestions: workspace.screenplayCompletions,
                continuationSeed: beatID.flatMap { DialoguePresentation.seed(project: workspace.project, beatID: $0) }, explicitCharacters: workspace.project.characters.map(\.name) + workspace.whiteboard.beats.flatMap(\.characters))
                .frame(height: controller.layoutHeight)
        }
    }
}
struct BeatReferenceChips: View {
    let characters: [String]
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !characters.isEmpty { LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading) {
                ForEach(characters, id: \.self) { name in
                    HStack(spacing: 4) {
                        Circle().fill(Color(boardHex: ["#11106b","#5de5bb","#a30e3f","#d6ae1c","#467e96"][name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5])).frame(width: 18, height: 18)
                        Text(name).font(.system(size: 12))
                    }
                }
            } }
            if !tags.isEmpty { LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading) {
                ForEach(tags, id: \.self) { tag in Text(tag).font(.system(size: 11)).foregroundStyle(.white).padding(4).background(Color(boardHex: "#ca53df")) }
            } }
        }
    }
}

struct ScriptReaderSettings {
    var display = "Expand All"
    var characters = true
    var tags = true
    var synopsis = false
    var boundaries = false
    var margins = "Compact Margins"
    var zoom = 1.0
    var filter = ""
    var filters = ScriptFilters()
    var followSelection = false
    var revision = 0
    var inset: CGFloat { margins == "Full Margins" ? 48 : margins == "Compact Margins" ? 16 : margins == "Squeezed" ? 8 : 3 }
}

struct SideScriptBeat: View {
    @ObservedObject var workspace: Workspace
    let beat: BoardBeat
    let width: CGFloat
    @State private var expanded = true
    private var settings: ScriptReaderSettings { workspace.reader }
    private var plain: Bool { ["Content Only", "Final Script"].contains(settings.display) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if beat.omitted || workspace.whiteboard.isUnused(beat) { Text(workspace.whiteboard.isUnused(beat) ? "Unused lane · excluded from export" : "Disabled beat · excluded from export").font(.caption).foregroundStyle(.secondary).padding(5) }
            if !plain {
                Button { expanded.toggle(); workspace.selectBoardBeat(beat.id) } label: {
                    Text((expanded ? "▼ " : "▶ ") + beat.title).font(.system(size: 16)).lineLimit(nil).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                }.buttonStyle(.plain).background(Color(boardHex: beat.color).opacity(0.2))
                if (settings.characters && !beat.characters.isEmpty) || (settings.tags && !beat.tags.isEmpty) {
                    BeatReferenceChips(characters: settings.characters ? beat.characters : [], tags: settings.tags ? beat.tags : []).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.94))
                }
                if settings.synopsis || settings.display == "Index Cards" { Text(beat.synopsis).padding(8) }
            }
            if plain || (expanded && settings.display != "Index Cards") {
                if beat.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write this beat’s screenplay here…").font(.custom("Courier", size: 14)).foregroundStyle(.secondary).padding(.horizontal, settings.inset).padding(.top, 10)
                }
                ContinuousSnippet(workspace: workspace, sceneID: beat.sceneID, beatID: beat.id, controller: workspace.scriptController("reader-" + beat.id), compact: true, readerWidth: max(180, width - settings.inset * 2), readerZoom: settings.zoom)
                    .padding(.horizontal, settings.inset).padding(.vertical, 12)
            }
        }.background(Color.white).foregroundStyle(.black).environment(\.colorScheme, .light)
            .overlay(Rectangle().stroke(workspace.selectedBoardBeatID == beat.id ? Color.accentColor : .clear, lineWidth: 2))
            .onTapGesture(count: 2) { workspace.popup.open(beat.id, workspace: workspace) }
            .onAppear { expanded = settings.display != "Collapse All" }
            .onChange(of: settings.revision) { _ in expanded = settings.display != "Collapse All" }
    }
}

struct ScreenplayTitleBanner: View {
    @ObservedObject var workspace: Workspace
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .trailing) {
            TextField("Untitled Screenplay", text: Binding(
                get: { workspace.project.name },
                set: { newName in
                    workspace.edit("Rename Screenplay", key: "project-name") {
                        $0.name = newName
                    }
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .focused($isFocused)
            .onSubmit {
                commitTitle()
                isFocused = false
            }
            .frame(maxWidth: .infinity)

            if isHovered && !isFocused {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(boardHex: "#078827"))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isFocused ? Color.white.opacity(0.8) : (isHovered ? Color.white.opacity(0.3) : Color.clear), lineWidth: 1.5)
        )
        .onHover { isHovered = $0 }
        .onChange(of: isFocused) { focused in
            if !focused {
                commitTitle()
            }
        }
        .help("Click to rename screenplay")
        .accessibilityIdentifier("screenplay-title-banner")
    }

    private func commitTitle() {
        let trimmed = workspace.project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            workspace.edit("Rename Screenplay", key: "project-name") {
                $0.name = "Untitled Screenplay"
            }
        }
    }
}

struct ScriptSidePaper: View {
    @ObservedObject var workspace: Workspace
    private func display(_ mode: String) { workspace.reader.display = mode; workspace.reader.revision += 1 }
    private var segments: [ScriptSegment] { (try? workspace.project.orderedScript(includeInactive: true)) ?? [] }
    private func matches(_ beat: BoardBeat) -> Bool {
        let query = workspace.reader.filter
        return workspace.reader.filters.matches(beat, board: workspace.whiteboard, scenes: workspace.project.scenes) && (query.isEmpty || ([beat.title, beat.synopsis, beat.html] + beat.characters + beat.tags).joined(separator: " ").localizedCaseInsensitiveContains(query))
    }
    private var tools: some View {
        HStack(spacing: 8) {
            Menu {
                Menu("Display Mode") {
                    ForEach(["Expand All", "Index Cards", "Collapse All", "Content Only", "Final Script"], id: \.self) { mode in
                        Button(mode) { display(mode) }
                    }
                }
                Menu("Beat Details") {
                    Toggle("Show Characters", isOn: $workspace.reader.characters)
                    Toggle("Show Tags", isOn: $workspace.reader.tags)
                    Toggle("Show Synopsis Field", isOn: $workspace.reader.synopsis)
                    Toggle("Show Block/Group Beginnings", isOn: $workspace.reader.boundaries)
                }
                Menu("Margins") {
                    ForEach(["Full Margins", "Compact Margins", "Squeezed", "Super Squeezed"], id: \.self) { m in
                        Button(m) { workspace.reader.margins = m }
                    }
                }
                Divider()
                Menu("Styling & Zoom") {
                    Button("Zoom In") { workspace.reader.zoom = min(2, workspace.reader.zoom + 0.1) }
                    Button("Zoom Out") { workspace.reader.zoom = max(0.7, workspace.reader.zoom - 0.1) }
                    Button("Reset Zoom (100%)") { workspace.reader.zoom = 1 }
                }
                ScriptFilterMenu(workspace: workspace, state: $workspace.reader.filters).id(workspace.documentSessionID)
                Menu("Presets") {
                    Button("Story Review") { workspace.reader = ScriptReaderSettings() }
                    Button("Reading") { display("Final Script"); workspace.reader.zoom = 1.1 }
                    Button("Index Cards") { display("Index Cards"); workspace.reader.synopsis = true }
                }
                Divider()
                Toggle("Follow Selected Beat", isOn: $workspace.reader.followSelection)
                Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                Divider()
                Button("Script Typography Preferences…") { workspace.showPreferences = true }
            } label: {
                Label("View Options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderedButton)
            .fixedSize()

            Spacer()

            Text("\(segments.count) scenes")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 38)
        .background(Color(white: 0.18))
        .accessibilityIdentifier("script-reader-tools")
    }
    var body: some View {
        VStack(spacing: 0) {
            tools.frame(maxWidth: .infinity, alignment: .leading)
            TextField("Filter script, characters or tags", text: $workspace.reader.filter).textFieldStyle(.roundedBorder).padding(6)
            if !workspace.project.pulledOutBeats.isEmpty {
                Button {
                    workspace.showPulledOutShelf = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill").foregroundStyle(.orange)
                        Text("Pulled Out Beats (\(workspace.project.pulledOutBeats.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("Restore")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                            .foregroundStyle(.orange)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            }
            if let id = workspace.selectedBoardBeatID, let beat = workspace.whiteboard.beats.first(where: { $0.id == id }), !matches(beat) {
                HStack { Text("Selected beat is hidden by filters.").font(.caption); Button("Reveal selected beat") { workspace.reader.filters = .init(); workspace.reader.filter = "" } }.padding(6)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ScreenplayTitleBanner(workspace: workspace)
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                let beats = segment.beatIDs.compactMap { id in workspace.whiteboard.beats.first { $0.id == id } }.filter(matches)
                                if !beats.isEmpty || (segment.beatIDs.isEmpty && workspace.reader.filter.isEmpty) {
                                    if !workspace.reader.filters.hideHeadings {
                                    HStack { Text(segment.scene.heading.text + (segment.isContinuation ? " (CONTINUED)" : "")); Spacer(); Text(segment.number) }
                                        .font(.custom("Courier", size: 14 * workspace.reader.zoom).bold()).foregroundStyle(.black).padding(10).background(Color.white)
                                    }
                                    ForEach(beats, id: \.id) { beat in
                                        if let gap = workspace.reader.filters.gap(before: beat.id, board: workspace.whiteboard, scenes: workspace.project.scenes) { Text(gap).font(.caption).frame(maxWidth: .infinity).padding(10).background(Color.gray.opacity(0.2)) }
                                        if workspace.reader.boundaries && !workspace.reader.filters.hideBreaks, let owner = workspace.whiteboard.blocks.first(where: { $0.id == beat.blockID }), owner.standalone != true,
                                           workspace.whiteboard.orderedBeats.first(where: { $0.blockID == owner.id })?.id == beat.id {
                                            Text(owner.name).font(.caption).padding(5).background(Color.black)
                                        }
                                        SideScriptBeat(workspace: workspace, beat: beat, width: max(200, geometry.size.width - 16)).id(beat.id)
                                    }
                                    if segment.beatIDs.isEmpty { ContinuousSnippet(workspace: workspace, sceneID: segment.scene.id, beatID: nil, controller: workspace.scriptController("reader-scene-\(segment.scene.id)"), compact: true, readerWidth: max(180, geometry.size.width - 36), readerZoom: workspace.reader.zoom).padding(10).background(Color.white) }
                                }
                            }
                        }.padding(8).frame(width: geometry.size.width, alignment: .topLeading).frame(minHeight: geometry.size.height, alignment: .topLeading)
                    }.onChange(of: workspace.selectedBoardBeatID) { id in if workspace.reader.followSelection, let id { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(white: 0.42))
    }
}

struct InlineFormatButtons: View {
    @ObservedObject var controller: ScreenplayEditorController
    var body: some View {
        HStack(spacing: 6) {
            Button("B") { controller.toggleInlineStyle("bold") }.fontWeight(.bold).accessibilityLabel("Bold")
            Button("I") { controller.toggleInlineStyle("italic") }.italic().accessibilityLabel("Italic")
            Button("U") { controller.toggleInlineStyle("underline") }.accessibilityLabel("Underline")
        }
    }
}

private struct WriterElementBar: View {
    @ObservedObject var controller: ScreenplayEditorController

    private let elements: [ScreenplayElement] = ScreenplayElement.ordered

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(elements.enumerated()), id: \.element) { index, element in
                    let isSelected = controller.activeElement == element
                    let num = index + 1
                    Button {
                        controller.format(element)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(num)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : Color(white: 0.55))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.08))
                                )
                            Text(element.label)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color(white: 0.78))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color(red: 0.18, green: 0.48, blue: 0.92) : Color(white: 0.22))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.white.opacity(0.7) : Color.white.opacity(0.12), lineWidth: isSelected ? 1.5 : 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("writer-element-\(element.rawValue)")
                    .help("\(element.label) (⌘\(num))")
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 4)

                Button {
                    controller.toggleDualDialogue()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 11))
                        Text("Dual Dialogue")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(white: 0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(white: 0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Toggle Dual Dialogue for current speech block (⌘⇧D)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 38)
        .background(Color(white: 0.16))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
#endif
