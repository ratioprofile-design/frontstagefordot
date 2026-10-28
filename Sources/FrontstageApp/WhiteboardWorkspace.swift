#if os(macOS)
import SwiftUI
import AppKit
import FrontstageCore

struct WhiteboardWorkspace: View {
    @ObservedObject var workspace: Workspace
    @State private var selection = Set<String>()
    @State private var blockSelection = Set<String>()
    @State private var showProperties = true
    @State private var showTimeline = true
    @State private var expandedTimeline = false
    @State private var scriptBeforeTimeline = true
    @State private var drawing = false
    @State private var pushing = false
    @State private var fitRequest = 0
    @State private var linkReason = ""
    @State private var showMarkerEditor = false
    @State private var markerID: String?
    @State private var markerTitle = "Act I"
    @State private var markerTime = 0.0
    @State private var markerKind: StructuralBreakKind = .act
    private var board: Whiteboard { workspace.whiteboard }
    private var markers: [StoryMilestone] { workspace.project.storyMilestones }
    private var timelineEnd: Double { max(20, board.beats.map { $0.start + $0.duration }.max() ?? 20, (markers.last?.x ?? 0) / StorySequencer.pointsPerPage + 3) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    TextField("Untitled Screenplay", text: Binding(
                        get: { workspace.project.name },
                        set: { newName in
                            workspace.edit("Rename Screenplay", key: "project-name") {
                                $0.name = newName
                            }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 90)
                    .fixedSize(horizontal: true, vertical: false)
                    .onSubmit {
                        let trimmed = workspace.project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            workspace.edit("Rename Screenplay", key: "project-name") {
                                $0.name = "Untitled Screenplay"
                            }
                        }
                    }
                    .help("Click to rename screenplay")
                    Toggle("Script", isOn: $workspace.showBoardScript).toggleStyle(.button)
                    Toggle("Inspector", isOn: $workspace.showInspector).toggleStyle(.button)
                    Toggle("Timeline", isOn: $showTimeline).toggleStyle(.button)
                    Button { fitRequest += 1 } label: { Label("Fit All", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .help("Fit all beats in view")
                    Spacer()
                    Button { changeZoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom whiteboard out").help("Zoom whiteboard out")
                    Button("\(Int((board.viewport.zoom * 100).rounded()))%") { changeZoom(1 / board.viewport.zoom) }.accessibilityLabel("Reset whiteboard zoom").help("Reset whiteboard zoom to 100%")
                    Button { changeZoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom whiteboard in").help("Zoom whiteboard in")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 32)
            .background(Color(white: 0.24))

            HSplitView {
                VStack(spacing: 0) {
                    if showTimeline && !workspace.timelineDetached {
                        StoryTimelineView(workspace: workspace, expanded: $expandedTimeline)
                            .frame(minHeight: expandedTimeline ? 250 : 210, maxHeight: expandedTimeline ? .infinity : 210)
                    }
                    if let cause = workspace.pendingBoardCauseID {
                        HStack {
                            Text("Choose an effect for “\(board.beats.first { $0.id == cause }?.title ?? "Cause")”")
                            Spacer(); Button("Cancel") { workspace.pendingBoardCauseID = nil }
                        }.font(.caption).padding(6).background(.cyan.opacity(0.18))
                    }
                    if !expandedTimeline || workspace.timelineDetached {
                        WhiteboardCanvas(workspace: workspace, selection: $selection, blockSelection: $blockSelection, pushing: pushing, drawing: drawing, fitRequest: fitRequest)
                            .frame(minHeight: 100, maxHeight: .infinity)
                        bottomTools
                    }
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)

                if workspace.showInspector && !expandedTimeline {
                    properties.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showMarkerEditor) { markerEditor }
        .onAppear { initializeSelection() }
        .onChange(of: workspace.timelineDetached) { _, detached in if detached { expandedTimeline = false } }
        .onChange(of: expandedTimeline) { _, expanded in
            if expanded { scriptBeforeTimeline = workspace.showBoardScript; workspace.showBoardScript = false }
            else { workspace.showBoardScript = scriptBeforeTimeline }
        }
        .onChange(of: workspace.selectedSceneID) { _, id in
            if workspace.selectedBoardBeat?.sceneID != id, let beat = board.orderedBeats.first(where: { $0.sceneID == id }) { workspace.selectBoardBeat(beat.id); selection = [beat.id] }
        }
        .onChange(of: workspace.selectedBoardBeatID) { _, id in if let id, !selection.contains(id) { selection = [id] } }
        .onChange(of: workspace.changeID) { _, _ in
            selection.formIntersection(Set(board.beats.map(\.id)))
            blockSelection.formIntersection(Set(board.blocks.map(\.id)))
        }
    }

    private var bottomTools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { drawing = false } label: { Image(systemName: "cursorarrow") }.tint(drawing ? .gray : .cyan)
                Button { drawing.toggle() } label: { Image(systemName: "pencil.tip") }.tint(drawing ? .cyan : .gray)
                    .help("Draw board annotations (hold Option/ALT to erase)")
                Button { fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit selection or board")
                Toggle("Push", isOn: $pushing).toggleStyle(.button).help("Push space open or closed; also Command-drag on the board")
                Toggle("Ripple", isOn: $workspace.whiteboardRipple).toggleStyle(.button)
                Button { changeZoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int((board.viewport.zoom * 100).rounded()))%").monospacedDigit().frame(width: 36)
                Button { changeZoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                Divider().frame(height: 18)
                ForEach(BoardPaletteItem.allCases, id: \.rawValue) { kind in
                    Button(kind == .lane ? "Lane" : kind.rawValue.capitalized) { createPaletteItem(kind) }
                        .onDrag { NSItemProvider(object: ("frontstage-palette:" + kind.rawValue) as NSString) }
                        .help("Drag onto the whiteboard to create a \(kind.rawValue)")
                }
                Divider().frame(height: 18)
                Menu("Layer Settings") {
                    ForEach(board.layers) { layer in
                        Toggle("\(layer.name): Use Blocks\(layer.useBlocks == nil && board.blocks.contains(where: { $0.layerID == layer.id && $0.standalone != true && $0.containerKind != "beatGroup" }) ? " (legacy layout)" : "")", isOn: Binding(get: { board.usesBlocks(layer.id) }, set: { enabled in workspace.edit("Layer Block Policy") { try $0.setLayerUsesBlocks(layer.id, enabled: enabled) } }))
                    }
                }
                Button("Add to Block") { workspace.addWhiteboardBeat(blockID: workspace.selectedBoardBeat?.blockID) }
                    .disabled(workspace.selectedBoardBeat == nil)
                Menu {
                    Button("Wrap Selection in Block") { workspace.edit("Group Blocks") { try $0.groupBoardBlocks(blockSelection.isEmpty ? Set(board.beats.filter { selection.contains($0.id) }.map(\.blockID)) : blockSelection, name: "New Block") } }
                        .disabled(blockSelection.isEmpty && selection.isEmpty)
                    Button("Unwrap Selected Blocks") { workspace.edit("Ungroup Blocks") { try $0.ungroupBoardBlocks(blockSelection) } }
                        .disabled(!board.blocks.contains { $0.parentID.map(blockSelection.contains) == true || ($0.containerKind == "beatGroup" && blockSelection.contains($0.id)) })
                    Button("Resolve Causal Flow") { workspace.edit("Resolve Causes") { try $0.editWhiteboard { try $0.resolveCauses() } } }
                    Button("Compact Causal Time") { workspace.edit("Compact Causal Time") { try $0.editWhiteboard { try $0.compactCauses() } } }
                        .help("Remove time gaps while respecting causes and locked starts. Board placement stays independent.")
                    Button("Add Act / Marker…") { editMarker() }
                    Button("Apply Story Order to Script") { workspace.edit("Apply Story Order") { try $0.applyWhiteboardStoryOrder() } }
                    Button("Merge Selected Snippets") { workspace.edit("Merge Snippets") { try $0.mergeBoardBeats(selection) } }.disabled(selection.count < 2)
                    Button("Clear Annotations") { workspace.edit("Clear Drawing") { try $0.editWhiteboard { $0.strokes = [] } } }
                } label: { Text("Board Actions") }
                Spacer()
                Text("\(board.beats.count) beats").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 42)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.14, green: 0.145, blue: 0.16))
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityIdentifier("whiteboard-bottom-tools")
    }

    private func editMarker(_ marker: StoryMilestone? = nil) {
        markerKind = marker?.kind ?? .act
        markerID = marker?.id; markerTitle = marker?.title ?? "Act \(markers.count + 1)"
        markerTime = marker.map { $0.x / StorySequencer.pointsPerPage } ?? workspace.selectedBoardBeat?.start ?? 0
        showMarkerEditor = true
    }
    private var markerEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(markerID == nil ? "Add Act / Marker" : "Edit Act / Marker").font(.headline)
            Picker("Break type", selection: $markerKind) { ForEach(StructuralBreakKind.allCases, id: \.self) { Text($0.title).tag($0) } }
            TextField("Name", text: $markerTitle)
            TextField("Estimated story time", value: $markerTime, format: .number)
            Text("A visual guide in estimated story time; it does not force beats into an act.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { showMarkerEditor = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    workspace.edit("Story Marker") { project in
                        if let markerID { try project.updateStoryMilestone(markerID, title: markerTitle, page: markerTime, kind: markerKind) }
                        else { _ = try project.addStoryMilestone(title: markerTitle, page: markerTime, kind: markerKind) }
                    }
                    showMarkerEditor = false
                }.keyboardShortcut(.defaultAction)
                    .disabled(markerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !markerTime.isFinite || markerTime < 0 || markerTime > 1_000_000 / StorySequencer.pointsPerPage)
            }
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 370)
    }

    private var snippetPanel: some View { ScriptSidePaper(workspace: workspace) }

    private var properties: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("▾ Beat Properties").font(.caption.weight(.semibold))
                if let beat = workspace.selectedBoardBeat {
                    TextField("Beat name", text: beatText(beat.id, \.title, label: "Beat Name"))
                    Picker("Type", selection: Binding(get: { beat.kind }, set: { kind in update(beat.id, "Beat Type") { $0.kind = kind } })) {
                        Text("Story Beat").tag(BoardBeatKind.story); Text("Subtext Beat").tag(BoardBeatKind.subtext)
                    }.pickerStyle(.segmented)
                    Toggle("Must Be Caused", isOn: Binding(get: { beat.mustBeCaused }, set: { value in update(beat.id, "Cause Requirement") { $0.mustBeCaused = value } }))
                    Button("Create Dependency From…") { workspace.pendingBoardCauseID = beat.id }
                    TextField("Synopsis", text: beatText(beat.id, \.synopsis, label: "Synopsis"), axis: .vertical).lineLimit(2...5)
                    if let scene = workspace.project.scenes.first(where: { $0.id == beat.sceneID }) {
                        DisclosureGroup("Scene Heading") {
                            TextField("INT. / EXT.", text: headingField(scene.id, \.prefix))
                            TextField("Location", text: headingField(scene.id, \.location))
                            TextField("DAY / NIGHT", text: headingField(scene.id, \.time))
                            TextField("Scene number", text: Binding(get: { workspace.project.scenes.first { $0.id == scene.id }?.sceneNumber ?? "" }, set: { workspace.updateScene(id: scene.id, sceneNumber: $0) }))
                        }.disabled(scene.isTextLocked)
                    }
                    Button("Open Popup Editor") { workspace.popup.open(beat.id, workspace: workspace) }
                    Button("Research & Attachments…") { workspace.openBoardResearch(beat.id) }
                    Divider()
                    Text("▾ Characters").font(.caption.weight(.semibold))
                    listField("Characters", beat: beat, characters: true)
                    Text("▾ Tags").font(.caption.weight(.semibold)); listField("Tags", beat: beat, characters: false)
                    HStack {
                        ForEach(["#39798c", "#a34eae", "#ab7d22", "#34834b", "#535f8a"], id: \.self) { color in
                            Button { update(beat.id, "Beat Color") { $0.color = color } } label: {
                                Circle().fill(Color(boardHex: color)).frame(width: 17, height: 17)
                            }.buttonStyle(.plain)
                        }
                    }
                    Divider(); Text("▾ Story Time").font(.caption.weight(.semibold))
                    numberField("Start", beat: beat, duration: false)
                    numberField("Duration", beat: beat, duration: true)
                    Toggle("Omitted", isOn: Binding(get: { beat.omitted }, set: { value in update(beat.id, "Beat Inclusion") { $0.omitted = value } }))
                    Toggle("Locked", isOn: Binding(get: { beat.locked }, set: { value in update(beat.id, "Beat Lock") { $0.locked = value } }))
                    if let block = board.blocks.first(where: { $0.id == beat.blockID }) {
                        Divider(); Text("▾ Block & Layer").font(.caption.weight(.semibold))
                        TextField("Block name", text: Binding(get: { block.name }, set: { value in
                            workspace.edit("Block Name", key: "block-\(block.id)") { try $0.editWhiteboard { board in
                                if let i = board.blocks.firstIndex(where: { $0.id == block.id }) { board.blocks[i].name = value }
                            } }
                        }))
                        Picker("Layer", selection: Binding(get: { block.layerID }, set: { layer in
                            workspace.edit("Move Block to Layer") { try $0.moveBoardBlocks([block.id], delta: .init(), layerID: layer) }
                        })) { ForEach(board.layers) { Text($0.name).tag($0.id) } }
                        TextField("Layer name", text: Binding(get: { board.layers.first { $0.id == block.layerID }?.name ?? "" }, set: { value in
                            workspace.edit("Layer Name", key: "layer-\(block.layerID)") { try $0.editWhiteboard { board in
                                if let i = board.layers.firstIndex(where: { $0.id == block.layerID }) { board.layers[i].name = value }
                            } }
                        }))
                        if let layer = board.layers.first(where: { $0.id == block.layerID }) {
                            Toggle("Lock Layer", isOn: Binding(get: { layer.locked }, set: { value in
                                workspace.edit("Layer Lock") { try $0.editWhiteboard { board in if let i = board.layers.firstIndex(where: { $0.id == layer.id }) { board.layers[i].locked = value } } }
                            }))
                            Toggle("Unused Layer", isOn: Binding(get: { layer.unused }, set: { value in
                                workspace.edit("Layer Inclusion") { try $0.editWhiteboard { board in if let i = board.layers.firstIndex(where: { $0.id == layer.id }) { board.layers[i].unused = value } } }
                            }))
                        }
                        HStack {
                            Text("Width")
                            TextField("Width", value: Binding(get: { block.width }, set: { value in
                                workspace.edit("Resize Block") { try $0.resizeBoardBlock(block.id, width: value) }
                            }), format: .number)
                        }
                    }
                    dependencyProperties(beat)
                } else { Text("Select a beat to edit its properties.").foregroundStyle(.secondary) }
                Divider(); Text("▾ Story Issues (\(board.issues.count))").font(.caption.weight(.semibold))
                ForEach(board.issues) { issue in
                    Button(issue.message) { if let id = issue.beatIDs.sorted().first { workspace.selectBoardBeat(id) } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                }
            }.padding(10).font(.caption).textFieldStyle(.roundedBorder)
        }.background(Color(white: 0.28))
    }

    private func dependencyProperties(_ beat: BoardBeat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider(); Text("▾ Causes & Effects").fontWeight(.semibold)
            ForEach(board.dependencies.filter { $0.cause == beat.id || $0.effect == beat.id }) { edge in
                let other = edge.cause == beat.id ? edge.effect : edge.cause
                HStack {
                    Button("\(edge.cause == beat.id ? "→" : "←") \(board.beats.first { $0.id == other }?.title ?? "Beat")") { workspace.selectBoardBeat(other) }
                        .buttonStyle(.plain)
                    Spacer()
                    Button { workspace.edit("Remove Dependency") { try $0.editWhiteboard { $0.dependencies.removeAll { $0.id == edge.id } } } }
                        label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                TextField("Reason", text: Binding(get: { edge.reason }, set: { value in
                    workspace.edit("Dependency Reason", key: "edge-\(edge.id)") { try $0.editWhiteboard { board in
                        if let i = board.dependencies.firstIndex(where: { $0.id == edge.id }) { board.dependencies[i].reason = value }
                    } }
                }))
                Toggle("Reference only", isOn: Binding(get: { edge.reference }, set: { value in
                    workspace.edit("Dependency Type") { try $0.editWhiteboard { board in
                        if let i = board.dependencies.firstIndex(where: { $0.id == edge.id }) { board.dependencies[i].reference = value }
                        _ = try board.causalOrder()
                    } }
                }))
            }
        }
    }

    private func beatText(_ id: String, _ path: WritableKeyPath<BoardBeat, String>, label: String) -> Binding<String> {
        Binding(get: { workspace.whiteboard.beats.first { $0.id == id }?[keyPath: path] ?? "" }, set: { value in update(id, label) { $0[keyPath: path] = value } })
    }
    private func headingField(_ id: Decimal, _ path: WritableKeyPath<SceneHeading, String>) -> Binding<String> {
        Binding(get: { workspace.project.scenes.first { $0.id == id }?.heading[keyPath: path] ?? "" }, set: { text in
            guard var heading = workspace.project.scenes.first(where: { $0.id == id })?.heading else { return }
            heading[keyPath: path] = text; workspace.updateScene(id: id, heading: heading)
        })
    }
    private func update(_ id: String, _ label: String, _ action: (inout BoardBeat) -> Void) {
        workspace.edit(label, key: "\(id)-\(label)") { try $0.updateBoardBeat(id, action) }
    }
    private func listField(_ title: String, beat: BoardBeat, characters: Bool) -> some View {
        TextField(title, text: Binding(get: { (characters ? beat.characters : beat.tags).joined(separator: ", ") }, set: { value in
            update(beat.id, title) { if characters { $0.characters = value.boardList } else { $0.tags = value.boardList } }
        }))
    }
    private func numberField(_ title: String, beat: BoardBeat, duration: Bool) -> some View {
        HStack {
            Text(title).frame(width: 55, alignment: .leading)
            TextField(title, value: Binding(get: { duration ? beat.duration : beat.start }, set: { value in
                workspace.edit("Change Story Time") { try $0.editWhiteboard { board in
                    guard let i = board.beats.firstIndex(where: { $0.id == beat.id }), !board.isLocked(board.beats[i]) else { throw ProjectError.invalidProject("unlock this beat first") }
                    if duration { board.beats[i].duration = value } else { board.beats[i].start = value }
                    try board.resolveCauses()
                } }
            }), format: .number.precision(.fractionLength(1)))
        }
    }
    private func changeZoom(_ factor: Double) {
        workspace.edit("Whiteboard View", key: "whiteboard-viewport") { try $0.editWhiteboard { $0.viewport.zoom = max(0.15, min(3, $0.viewport.zoom * factor)) } }
    }
    private func createPaletteItem(_ kind: BoardPaletteItem) {
        let parent = board.blocks.first { $0.id == workspace.selectedBoardBeat?.blockID }
        let layerID = parent?.layerID ?? board.layers.first?.id ?? "main"
        let position = parent.map { BoardPoint(x: $0.position.x + 12, y: $0.position.y + 35) } ?? BoardPoint(x: board.viewport.origin.x + 70, y: 70)
        var created: String?
        workspace.edit("Create \(kind.rawValue.capitalized)") { created = try $0.createBoardItem(kind, layerID: layerID, position: position, parentID: kind == .block || kind == .lane || parent?.standalone == true ? nil : parent?.id) }
        if let created, kind == .beat { workspace.selectBoardBeat(created); workspace.popup.open(created, workspace: workspace) }
    }
    private func addLayer(unused: Bool) {
        workspace.edit("Add Layer") { try $0.editWhiteboard { $0.layers.append(BoardLayer(name: unused ? "Unused" : "New Layer", unused: unused)) } }
    }
    private func initializeSelection() {
        do {
            _ = try workspace.project.whiteboard()
            if let beat = workspace.selectedBoardBeat ?? board.orderedBeats.first { workspace.selectBoardBeat(beat.id); selection = [beat.id] }
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}
#endif
