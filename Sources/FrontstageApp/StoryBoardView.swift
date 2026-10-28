#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore

/// Both panes share the project, selection and undo history.
struct StoryWorkspaceView: View {
    @ObservedObject var workspace: Workspace
    let boardFirst: Bool

    var body: some View {
        WhiteboardWorkspace(workspace: workspace)
            .onAppear { if !boardFirst { workspace.showBoardScript = true } }
    }
}

struct StoryBoardView: View {
    @ObservedObject var workspace: Workspace
    @State private var boardID = 0
    @State private var selected = Set<Decimal>()
    @State private var ripple = true
    @State private var snap = true
    @State private var zoom = 0.8
    @State private var pendingSource: Decimal?
    @State private var linkKind = StoryLinkKind.cause
    @State private var linkLabel = ""
    @State private var showInspector = false
    @State private var showMilestoneForm = false
    @State private var milestoneTitle = "Act break"
    @State private var milestonePage = 30.0
    @State private var dragPreview: StorySequencer?
    @State private var cachedModel = Project().storySequencer()
    @State private var dragBase: Project?
    @State private var dragIDs = Set<Decimal>()
    @State private var dragError: String?
    @State private var dragDelta = 0.0
    @State private var dragLane: Int?

    private let gutter = 136.0
    private let rulerHeight = 36.0
    private var model: StorySequencer { dragPreview ?? cachedModel }
    private var allBoards: [Int] { workspace.project.storyGraph.boardIDs }
    private var issues: [SequencerIssue] { model.issues }
    private var canvasWidth: Double { max(1300, (model.beats.map(\.end).max() ?? 0) + 400, (model.milestones.map(\.x).max() ?? 0) + 160) }
    private var canvasHeight: Double { rulerHeight + model.lanes.reduce(0) { $0 + laneHeight($1) } }
    private func laneHeight(_ lane: StoryLane) -> Double { lane.isCollapsed ? 48 : StorySequencer.laneHeight }
    private func laneTop(_ index: Int) -> Double { rulerHeight + model.lanes.prefix(index).reduce(0) { $0 + laneHeight($1) } }
    private func beatY(_ beat: SequencerBeat) -> Double { laneTop(beat.lane) + laneHeight(model.lanes[beat.lane]) / 2 }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let source = pendingSource {
                HStack {
                    Text("Choose the effect beat for “\(model.beats.first { $0.id == source }?.node.title ?? "Cause")”.")
                    Spacer()
                    Button("Cancel") { pendingSource = nil }
                }.font(.caption).padding(8).background(Color.cyan.opacity(0.18))
            }
            HStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        laneBackground
                        drawing
                        groupOverlays
                        milestoneOverlays
                        ForEach(model.beats) { beat in beatCard(beat) }
                    }.frame(width: canvasWidth + gutter, height: canvasHeight)
                        .coordinateSpace(name: "sequencer")
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: (canvasWidth + gutter) * zoom, height: canvasHeight * zoom, alignment: .topLeading)
                }.background(Color(red: 0.085, green: 0.09, blue: 0.105))
                if showInspector { Divider(); inspector.frame(width: 270) }
            }
            statusBar
        }
        .environment(\.colorScheme, .dark)
        .onAppear { synchronizeSelection(); selectBoardForScene(); refreshModel() }
        .onChange(of: boardID) { _, _ in
            pendingSource = nil; refreshModel(); selected.formIntersection(Set(model.beats.map(\.id)))
            if !model.beats.contains(where: { $0.id == workspace.selectedSceneID }) { workspace.selectedSceneID = model.beats.first?.id }
        }
        .onChange(of: workspace.selectedSceneID) { _, _ in synchronizeSelection(); selectBoardForScene() }
        .onChange(of: workspace.changeID) { _, _ in
            refreshModel()
            selected.formIntersection(Set(model.beats.map(\.id)))
            if !allBoards.contains(boardID) { boardID = allBoards.first ?? 0 }
        }
        .popover(isPresented: $showMilestoneForm) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Story milestone").font(.headline)
                TextField("Title", text: $milestoneTitle)
                TextField("Estimated page", value: $milestonePage, format: .number)
                Button("Add Milestone") {
                    workspace.edit("Add Milestone") { _ = try $0.addStoryMilestone(title: milestoneTitle, page: milestonePage) }
                    showMilestoneForm = false
                }
            }.padding(20).frame(width: 260)
        }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Label("STORY SEQUENCER", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                if allBoards.count > 1 {
                    Picker("Board", selection: $boardID) {
                        ForEach(allBoards, id: \.self) { Text("Board \($0 + 1)").tag($0) }
                    }.frame(width: 115)
                }
                Divider().frame(height: 18)
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Toggle Inspector Panel")
                Toggle("Ripple", isOn: $ripple).toggleStyle(.button).tint(.cyan)
                    .help("Preserve lane order and push downstream effects and overlapping beats.")
                Toggle("Snap", isOn: $snap).toggleStyle(.button).tint(.purple)
                Button("Resolve Flow", systemImage: "arrow.triangle.branch") {
                    workspace.edit("Resolve Story Flow") { try $0.resolveStory(boardID: boardID) }
                }
                Menu {
                    Button("Add Beat") { addBeat(lane: selectedBeat?.lane ?? 0) }
                    Button("Add Lane") { workspace.edit("Add Story Lane") { _ = try $0.addStoryLane(label: "New Storyline") } }
                    Button("Add Milestone…") { showMilestoneForm = true }
                    Divider()
                    Button("Group Selected Beats") {
                        workspace.edit("Group Story Beats") { _ = try $0.groupStoryBeats(selected, title: "New Sequence", boardID: boardID) }
                    }.disabled(selected.count < 2)
                    Button("Ungroup Selected Beats") { workspace.edit("Ungroup Beats") { try $0.ungroupStoryBeats(selected) } }
                        .disabled(selected.isEmpty)
                    Divider()
                    Button("Apply Board Order to Screenplay") { workspace.edit("Apply Story Order") { try $0.applyStoryOrder(boardID: boardID) } }
                } label: { Label("Story", systemImage: "plus") }
                Divider().frame(height: 18)
                Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 40)
                Button { zoom = min(1.5, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
            }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
        }.background(Color(red: 0.12, green: 0.125, blue: 0.14))
    }

    private var laneBackground: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("STORYLINES").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: gutter, height: rulerHeight)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<Int(canvasWidth / StorySequencer.pointsPerPage), id: \.self) { page in
                        Text("\(page)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .offset(x: Double(page) * StorySequencer.pointsPerPage + 4, y: 12)
                    }
                }.frame(width: canvasWidth, height: rulerHeight)
            }.background(.black.opacity(0.18))
            ForEach(model.lanes) { lane in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.storyHex(lane.color)).frame(width: 6, height: 6)
                            Text(lane.label.uppercased()).font(.system(size: 10, weight: .bold)).lineLimit(2)
                            if lane.isLocked { Image(systemName: "lock.fill").font(.caption2) }
                        }
                        if !lane.isCollapsed {
                            Text("\(model.beats.filter { $0.lane == lane.index }.count) beats").font(.system(size: 10)).foregroundStyle(.secondary)
                            Button { addBeat(lane: lane.index) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                                .disabled(lane.isLocked).help("Add beat to \(lane.label)")
                        }
                    }.padding(.horizontal, 12).frame(width: gutter, height: laneHeight(lane), alignment: .leading)
                        .background(Color.black.opacity(0.16))
                        .contextMenu {
                            Button(lane.isCollapsed ? "Expand Lane" : "Collapse Lane") {
                                workspace.edit("Change Lane Display") { try $0.updateStoryLane(lane.index, collapsed: !lane.isCollapsed) }
                            }
                            Button(lane.isLocked ? "Unlock Lane" : "Lock Lane") {
                                workspace.edit("Change Lane Lock") { try $0.updateStoryLane(lane.index, locked: !lane.isLocked) }
                            }
                            Button("Compact Lane") { workspace.edit("Compact Lane") { try $0.resolveStory(boardID: boardID, compactLane: lane.index) } }
                            ForEach(["#eab308", "#38bdf8", "#ef4444", "#8b5cf6", "#22c55e"], id: \.self) { color in
                                Button("Color \(color)") { workspace.edit("Lane Color") { try $0.updateStoryLane(lane.index, color: color) } }
                            }
                        }
                    Rectangle().fill(Color.storyHex(lane.color).opacity(lane.isUnused ? 0.015 : 0.04))
                        .frame(width: canvasWidth, height: laneHeight(lane))
                        .contentShape(Rectangle()).onTapGesture { pendingSource = nil; selected = [] }
                }.overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
            }
        }
    }

    private var drawing: some View {
        Canvas { context, _ in
            // Keep extreme imported coordinates usable without allocating millions of grid marks.
            let gridStep = max(30.0, ceil(canvasWidth / 2400 / 30) * 30)
            for column in 0...Int(canvasWidth / gridStep) {
                let x = gutter + Double(column) * gridStep
                var line = Path(); line.move(to: CGPoint(x: x, y: rulerHeight)); line.addLine(to: CGPoint(x: x, y: canvasHeight))
                context.stroke(line, with: .color(.white.opacity(column % 4 == 0 ? 0.065 : 0.025)), lineWidth: 1)
            }
            let byID = Dictionary(uniqueKeysWithValues: model.beats.map { ($0.id, $0) })
            for link in model.links {
                guard let a = byID[link.from], let b = byID[link.to] else { continue }
                let start = CGPoint(x: gutter + a.end, y: beatY(a))
                let end = CGPoint(x: gutter + b.x, y: beatY(b))
                let bend = max(36, abs(end.x - start.x) * 0.45)
                var path = Path(); path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
                let invalid = link.kind == .cause && b.x < a.end + StorySequencer.gap - 0.001
                let color: Color = invalid ? .red : (selected.contains(a.id) || selected.contains(b.id) ? .cyan : .gray)
                context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: link.kind == .reference ? [4, 4] : []))
                var arrow = Path(); arrow.move(to: CGPoint(x: end.x - 7, y: end.y - 4)); arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                context.stroke(arrow, with: .color(color), lineWidth: 1.5)
            }
        }.frame(width: canvasWidth + gutter, height: canvasHeight).allowsHitTesting(false)
    }

    private var groupOverlays: some View {
        ForEach(model.groups) { group in
            let members = model.beats.filter { $0.groupID == group.id }
            if let first = members.first {
                let left = members.map(\.x).min() ?? first.x
                let right = members.map(\.end).max() ?? first.end
                RoundedRectangle(cornerRadius: 5).fill(Color.storyHex(model.lanes[first.lane].color).opacity(0.10))
                    .overlay(alignment: .topLeading) {
                        Text(group.title.uppercased()).font(.system(size: 9, weight: .bold)).padding(5)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15)))
                    .frame(width: right - left + 16, height: laneHeight(model.lanes[first.lane]) - 12)
                    .position(x: gutter + (left + right) / 2, y: beatY(first))
                    .onTapGesture { selected = Set(members.map(\.id)); workspace.selectedSceneID = first.id }
            }
        }
    }

    private var milestoneOverlays: some View {
        ForEach(model.milestones) { milestone in
            VStack(spacing: 0) {
                Text(milestone.title.uppercased()).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).frame(height: rulerHeight).background(.orange.opacity(0.25))
                Rectangle().fill(.orange.opacity(0.5)).frame(width: 1, height: canvasHeight - rulerHeight)
            }.fixedSize(horizontal: true, vertical: false)
                .position(x: gutter + milestone.x, y: canvasHeight / 2)
                .contextMenu {
                    Button("Remove Milestone") { workspace.edit("Remove Milestone") { $0.removeStoryMilestone(milestone.id) } }
                }
        }
    }

    private func beatCard(_ beat: SequencerBeat) -> some View {
        let lane = model.lanes[beat.lane]
        let isSelected = selected.contains(beat.id) || workspace.selectedSceneID == beat.id
        let color = Color.storyHex(lane.color)
        let height = lane.isCollapsed ? 30.0 : 68.0
        return HStack(spacing: 0) {
            Button { completeConnection(to: beat.id) } label: {
                Circle().stroke(.black.opacity(0.5), lineWidth: 1).background(Circle().fill(isSelected ? Color.cyan : color))
                    .frame(width: 8, height: 8)
            }.buttonStyle(.plain).frame(width: 16).help("Connect the pending cause to this effect")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(beat.node.title.isEmpty ? "Untitled Beat" : beat.node.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if beat.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                }
                if !lane.isCollapsed {
                    Text(beat.node.summary.isEmpty ? "Add a beat summary in the script pane" : beat.node.summary)
                        .font(.system(size: 10)).lineLimit(2).opacity(0.7)
                    Text(beat.node.isDisabled ? "OMITTED" : String(format: "%.1f pp", beat.pages))
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).opacity(0.65)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { pendingSource = beat.id } label: {
                Circle().fill(.black.opacity(0.6)).frame(width: 7, height: 7)
            }.buttonStyle(.plain).frame(width: 16).help("Start a cause-and-effect connection")
        }
        .foregroundStyle(beat.node.isDisabled ? Color.white.opacity(0.7) : Color.black.opacity(0.88))
        .frame(width: beat.width, height: height)
        .background(beat.node.isDisabled ? color.opacity(0.12) : color, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.white : color.opacity(0.6), lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(isSelected ? 0.45 : 0.2), radius: isSelected ? 5 : 2, y: 2)
        .position(x: gutter + beat.x + beat.width / 2, y: beatY(beat))
        .onTapGesture(count: 2) { workspace.selectedSceneID = beat.id; selected = [beat.id] }
        .onTapGesture { select(beat) }
        .gesture(DragGesture(coordinateSpace: .named("sequencer"))
            .onChanged { value in drag(beat, translation: value.translation) }
            .onEnded { _ in finishDrag() })
        .contextMenu {
            Button("Select Sequence") {
                selected = beat.groupID.map { group in Set(model.beats.filter { $0.groupID == group }.map(\.id)) } ?? [beat.id]
                workspace.selectedSceneID = beat.id
            }
            Button("Connect as Cause…") { pendingSource = beat.id }
            Button(beat.isLocked ? "Unlock Beat" : "Lock Beat") {
                workspace.edit("Change Beat Lock") { try $0.setStoryBeatLocked(beat.id, locked: !beat.isLocked) }
            }
            Button(beat.node.isDisabled ? "Include in Screenplay" : "Omit from Screenplay") {
                workspace.edit("Change Scene Inclusion") { try $0.setSceneOmitted(beat.id, omitted: !beat.node.isDisabled) }
            }
            Button("Delete Beat", role: .destructive) {
                workspace.edit("Delete Story Beat") { try $0.removeStoryBeats([beat.id]) }
                if workspace.selectedSceneID == beat.id { workspace.selectedSceneID = workspace.project.scenes.first?.id }
            }
            Menu("Move to Storyline") {
                ForEach(model.lanes) { target in
                    Button(target.label) { workspace.edit("Move Beat to Lane") { try $0.moveStoryBeats([beat.id], by: 0, toLane: target.index, boardID: boardID, ripple: ripple, snap: snap) } }
                        .disabled(target.isLocked)
                }
            }
        }
        .accessibilityLabel("\(beat.node.title), \(lane.label), \(beat.pages) estimated pages")
    }

    private var selectedBeat: SequencerBeat? { model.beats.first { $0.id == workspace.selectedSceneID } }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let beat = selectedBeat {
                    Text("BEAT INSPECTOR").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(beat.node.title).font(.headline)
                    Text("Estimated duration").font(.caption)
                    HStack {
                        TextField("Pages", value: Binding(get: { beat.pages }, set: { pages in
                            workspace.edit("Resize Story Beat") { try $0.resizeStoryBeat(beat.id, pages: pages, boardID: boardID, ripple: ripple) }
                        }), format: .number.precision(.fractionLength(1))).frame(width: 65)
                        Text("pages").foregroundStyle(.secondary)
                    }
                    Text("Story estimates are separate from the printed screenplay's page count.").font(.caption2).foregroundStyle(.secondary)
                    TextField("Storyline name", text: Binding(get: { model.lanes[beat.lane].label }, set: { title in
                        workspace.edit("Rename Storyline", key: "lane-\(beat.lane)") { try $0.updateStoryLane(beat.lane, label: title) }
                    }))
                    if let groupID = beat.groupID, let group = model.groups.first(where: { $0.id == groupID }) {
                        TextField("Sequence title", text: Binding(get: { group.title }, set: { title in
                            workspace.edit("Rename Sequence", key: "group-\(groupID)") { try $0.renameStoryGroup(groupID, title: title) }
                        }))
                    }
                    Picker("Link", selection: $linkKind) { ForEach(StoryLinkKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    TextField("Why does this cause the effect?", text: $linkLabel)
                    Button("Connect this beat to…") { pendingSource = beat.id }
                    Divider()
                    Text("CAUSES & EFFECTS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(model.links.filter { $0.from == beat.id || $0.to == beat.id }) { link in
                        HStack(alignment: .top) {
                            Button {
                                workspace.selectedSceneID = link.from == beat.id ? link.to : link.from
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(link.from == beat.id ? "EFFECT →" : "← CAUSE").font(.system(size: 9, weight: .bold))
                                    Text(model.beats.first { $0.id == (link.from == beat.id ? link.to : link.from) }?.node.title ?? "Beat")
                                    if link.kind == .reference { Text("Reference only").foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { workspace.edit("Disconnect Beats") { $0.disconnectScenes(from: link.from, to: link.to) } }
                                label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove connection")
                        }.font(.caption)
                        TextField("Connection reason", text: Binding(get: { link.label }, set: { text in
                            workspace.edit("Edit Connection Reason", key: "link-\(link.id)") { try $0.updateStoryLink(from: link.from, to: link.to, label: text) }
                        })).font(.caption)
                    }
                } else { Text("Select a beat to inspect its causes and effects.").foregroundStyle(.secondary) }
                Divider()
                Text("STORY ISSUES · \(issues.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(issues) { issue in
                    Button(issue.message) { workspace.selectedSceneID = issue.sceneIDs.sorted().first }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                }
                if workspace.project.storyGraph.hasCycle {
                    Text("Imported causal loop: remove a conflicting connection to enable ripple.").font(.caption).foregroundStyle(.red)
                }
            }.padding(14).textFieldStyle(.roundedBorder)
        }.background(Color(red: 0.12, green: 0.125, blue: 0.14))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.beats.count) beats · \(selected.count) selected")
            if let dragError { Text(dragError).foregroundStyle(.orange).lineLimit(1) }
            else if !issues.isEmpty {
                Button("\(issues.count) story issues") { showInspector = true }.foregroundStyle(.orange).buttonStyle(.plain)
            }
            Spacer()
            Text("⇧ click to select · drag to sequence · dots connect causes").lineLimit(1).foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(red: 0.12, green: 0.125, blue: 0.14))
    }

    private func synchronizeSelection() {
        if let id = workspace.selectedSceneID, !selected.contains(id) { selected = [id] }
        if workspace.selectedSceneID == nil { selected = [] }
    }

    private func selectBoardForScene() {
        if let node = workspace.project.storyGraph.nodes.first(where: { $0.id == workspace.selectedSceneID }) { boardID = node.boardID }
    }

    private func select(_ beat: SequencerBeat) {
        if pendingSource != nil { completeConnection(to: beat.id); return }
        if NSEvent.modifierFlags.contains(.shift) {
            if !selected.insert(beat.id).inserted { selected.remove(beat.id) }
            if selected.contains(beat.id) { workspace.selectedSceneID = beat.id }
        } else { selected = [beat.id]; workspace.selectedSceneID = beat.id }
    }

    private func completeConnection(to id: Decimal) {
        guard let source = pendingSource, source != id else { return }
        workspace.edit("Connect Cause and Effect") { try $0.connectScenes(from: source, to: id, label: linkLabel, kind: linkKind) }
        pendingSource = nil
    }

    private func addBeat(lane: Int) {
        var id: Decimal?
        let end = model.beats.filter { $0.lane == lane }.map(\.end).max().map { $0 + StorySequencer.gap } ?? 0
        workspace.edit("Add Story Beat") { project in
            let newID = project.addScene(); id = newID
            try project.setStoryBoard(newID, boardID: boardID)
            let initial = project.storySequencer(boardID: boardID).beats.first { $0.id == newID }?.x ?? 0
            try project.moveStoryBeats([newID], by: end - initial, toLane: lane, boardID: boardID, ripple: false, snap: false)
        }
        if workspace.errorMessage == nil { workspace.selectedSceneID = id; selected = id.map { [$0] } ?? [] }
    }

    private func drag(_ beat: SequencerBeat, translation: CGSize) {
        if dragBase == nil {
            if !selected.contains(beat.id) { selected = [beat.id] }
            workspace.selectedSceneID = beat.id
            dragBase = workspace.project; dragIDs = selected
        }
        guard var preview = dragBase else { return }
        let baseModel = preview.storySequencer(boardID: boardID)
        guard let original = baseModel.beats.first(where: { $0.id == beat.id }) else { return }
        dragDelta = translation.width
        let center = beatY(original) + translation.height
        let destination = model.lanes.first { center >= laneTop($0.index) && center < laneTop($0.index) + laneHeight($0) }?.index ?? original.lane
        dragLane = destination == original.lane ? nil : destination
        do {
            try preview.moveStoryBeats(dragIDs, by: dragDelta, toLane: dragLane, boardID: boardID, ripple: ripple, snap: snap)
            dragPreview = preview.storySequencer(boardID: boardID); dragError = nil
        } catch { dragError = error.localizedDescription; dragPreview = nil }
    }

    private func finishDrag() {
        if dragError == nil && dragBase != nil {
            workspace.edit("Move Story Beats") {
                try $0.moveStoryBeats(dragIDs, by: dragDelta, toLane: dragLane, boardID: boardID, ripple: ripple, snap: snap)
            }
        }
        dragPreview = nil; dragBase = nil; dragIDs = []; dragLane = nil
    }

    private func refreshModel() { cachedModel = workspace.project.storySequencer(boardID: boardID) }
}

private extension Color {
    static func storyHex(_ value: String) -> Color {
        guard value.count == 7, value.first == "#", let rgb = UInt32(value.dropFirst(), radix: 16) else { return .yellow }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
#endif
