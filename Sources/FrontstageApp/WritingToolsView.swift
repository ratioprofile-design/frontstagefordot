#if os(macOS)
import SwiftUI
import AppKit
import FrontstageCore

struct WritingToolsView: View {
    @ObservedObject var workspace: Workspace
    @State private var bamini = ""
    private var layout: ScriptLayoutSettings { workspace.project.scriptLayout }
    private var rows: [ParallelScriptRow] { workspace.selectedSceneID.map { workspace.project.parallelScript(sceneID: $0) } ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Writing Tools").font(.title2)
                ProductionRevisionPanel(workspace: workspace)
                if let scene = workspace.selectedScene {
                    GroupBox("Scene script") {
                        VStack(alignment: .leading) {
                            Text(scene.title).font(.headline)
                            Toggle("Lock script text and heading", isOn: Binding(get: { scene.isTextLocked }, set: { value in workspace.edit("Scene Script Lock") { try $0.setSceneTextLocked(scene.id, locked: value) } }))
                            Toggle("Start this scene on a new page", isOn: Binding(get: { scene.startsNewPage }, set: { value in workspace.edit("Scene Page Break") { try $0.setScenePageStart(scene.id, newPage: value) } }))
                        }.padding(8)
                    }
                }
                GroupBox("Screenplay typography") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Font name", text: Binding(get: { layout.fontName }, set: { name in changeLayout { $0.fontName = name } }))
                        HStack {
                            Text("Font size")
                            TextField("Size", value: Binding(get: { layout.fontSize }, set: { value in changeLayout { $0.fontSize = value; $0.lineHeight = max(value, $0.lineHeight) } }), format: .number)
                            Text("Line height")
                            TextField("Height", value: Binding(get: { layout.lineHeight }, set: { value in changeLayout { $0.lineHeight = value } }), format: .number)
                        }
                        Button("Manage Typography in Preferences…") {
                            workspace.showPreferences = true
                        }
                        .buttonStyle(.borderedProminent)
                    }.padding(8)
                }
                GroupBox("Bamini → Unicode Tamil") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste Bamini text explicitly. English letters in the input will be converted too.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $bamini).frame(height: 100).font(.system(.body, design: .monospaced))
                        Text(TamilTranscoder.baminiToUnicode(bamini)).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                        Button("Copy Unicode") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TamilTranscoder.baminiToUnicode(bamini), forType: .string)
                        }
                    }.padding(8)
                }
                GroupBox("Two-column script / translation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(workspace.selectedScene?.title ?? "Select a scene in the sidebar").font(.headline)
                        ForEach(rows) { row in
                            HStack(alignment: .top) {
                                TextEditor(text: rowText(row.id, right: false)).frame(minHeight: 90)
                                TextEditor(text: rowText(row.id, right: true)).frame(minHeight: 90)
                                Button { editRows { $0.removeAll { $0.id == row.id } } } label: { Image(systemName: "minus.circle") }
                            }
                        }
                        HStack {
                            Button("Add Row") { editRows { $0.append(ParallelScriptRow()) } }.disabled(workspace.selectedSceneID == nil)
                            Button("Export Two-column PDF…") { exportParallel() }.disabled(rows.isEmpty)
                        }
                    }.padding(8)
                }
            }.padding(24).textFieldStyle(.roundedBorder)
        }
    }
    private func changeLayout(_ action: (inout ScriptLayoutSettings) -> Void) {
        var value = layout; action(&value)
        workspace.edit("Script Typography") { try $0.setScriptLayout(value) }
    }
    private func editRows(_ action: (inout [ParallelScriptRow]) -> Void) {
        guard let id = workspace.selectedSceneID else { return }
        var value = rows; action(&value)
        workspace.edit("Parallel Script", key: "parallel-\(id)") { try $0.setParallelScript(sceneID: id, rows: value) }
    }
    private func rowText(_ id: String, right: Bool) -> Binding<String> {
        Binding(get: { let row = rows.first { $0.id == id }; return (right ? row?.right : row?.left) ?? "" }, set: { text in editRows { rows in
            if let i = rows.firstIndex(where: { $0.id == id }) { if right { rows[i].right = text } else { rows[i].left = text } }
        } })
    }
    private func exportParallel() {
        do {
            let result = try ParallelScriptPDF.render(rows: rows, title: workspace.selectedScene?.title ?? "Parallel Script", paper: workspace.paper)
            try workspace.exportPDF(result, name: "Two-column Script")
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}

struct ProductionRevisionPanel: View {
    @ObservedObject var workspace: Workspace

    private var currentRevision: ProductionRevision? {
        workspace.project.currentRevision
    }

    var body: some View {
        GroupBox("Production Revisions & Page Locking") {
            VStack(alignment: .leading, spacing: 12) {
                if let rev = currentRevision {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(colorFor(rev.color))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rev.label)
                                .font(.headline)
                            Text("\(rev.color.rawValue) Revision • \(formattedDate(rev.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if rev.isLocked {
                            Label("Production Locked", systemImage: "lock.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .cornerRadius(6)
                        } else {
                            Label("Unlocked Draft", systemImage: "lock.open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()

                    Toggle("Lock Production Pages", isOn: Binding(
                        get: { rev.isLocked },
                        set: { _ in
                            workspace.edit("Toggle Production Lock") {
                                $0.toggleProductionLock()
                            }
                        }
                    ))
                    .help("When locked, any edits made will be flagged with revision asterisks (*) in the right margin on PDF export.")

                    HStack(spacing: 10) {
                        Button {
                            workspace.edit("Advance Revision Color") {
                                $0.startNextRevision()
                            }
                        } label: {
                            Label(nextRevisionButtonTitle(rev.color), systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Advance to the next industry production color and create a new change baseline.")

                        Menu {
                            ForEach(RevisionColor.allCases, id: \.self) { color in
                                Button {
                                    workspace.edit("Set Revision Color") {
                                        $0.setRevisionColor(color)
                                    }
                                } label: {
                                    HStack {
                                        Text(color.rawValue)
                                        if color == rev.color {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Reset to Spec Draft (Clear Revisions)", role: .destructive) {
                                workspace.edit("Clear Revisions") {
                                    $0.clearProductionRevision()
                                }
                            }
                        } label: {
                            Label("Change Color…", systemImage: "paintpalette")
                        }
                    }

                    if rev.isLocked {
                        Text("Edits to scenes are compared against the baseline. Lines modified since locking will display an asterisk (*) in the PDF margin and include the revision header \(rev.headerString).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Script is currently in Spec Draft mode. Production revisions track changes by color (White, Blue, Pink, Yellow, Green, Goldenrod, Buff, Salmon, Cherry) and stamp asterisks (*) next to revised lines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            workspace.edit("Start Production Revisions") {
                                $0.toggleProductionLock()
                            }
                        } label: {
                            Label("Lock Script & Start Production Draft (White)", systemImage: "lock.badge.clock")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(8)
        }
    }

    private func colorFor(_ revColor: RevisionColor) -> Color {
        switch revColor {
        case .white: return Color.white
        case .blue: return Color(red: 0.29, green: 0.56, blue: 0.89)
        case .pink: return Color(red: 0.89, green: 0.35, blue: 0.60)
        case .yellow: return Color(red: 0.96, green: 0.65, blue: 0.14)
        case .green: return Color(red: 0.49, green: 0.83, blue: 0.13)
        case .goldenrod: return Color(red: 0.82, green: 0.55, blue: 0.16)
        case .buff: return Color(red: 0.91, green: 0.85, blue: 0.65)
        case .salmon: return Color(red: 0.98, green: 0.50, blue: 0.45)
        case .cherry: return Color(red: 0.87, green: 0.19, blue: 0.39)
        case .secondWhite: return Color(red: 0.94, green: 0.94, blue: 0.94)
        }
    }

    private func nextRevisionButtonTitle(_ current: RevisionColor) -> String {
        if let next = current.next {
            return "Start \(next.rawValue) Revision"
        } else {
            return "Start 2nd White Revision"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

@MainActor
enum ParallelScriptPDF {
    static func render(rows: [ParallelScriptRow], title: String, paper: ScreenplayPaper) throws -> RenderedScreenplay {
        // AppKit's table layout paginates paired cells together and supports Unicode fallback fonts.
        let text = NSMutableAttributedString(string: "")
        let table = NSTextTable(); table.numberOfColumns = 2; table.collapsesBorders = true
        for (index, row) in rows.enumerated() {
            for (column, value) in [row.left, row.right].enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: index, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setValue(50, type: .percentageValueType, for: .width)
                cell.setWidth(8, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.gray)
                let paragraph = NSMutableParagraphStyle(); paragraph.textBlocks = [cell]
                text.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]))
            }
        }
        // TextKit, rather than CoreText, understands NSTextTable blocks.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.contentWidth, height: paper.contentHeight))
        view.textStorage?.setAttributedString(text); view.textContainerInset = .zero
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: paper.width, height: paper.height)
        info.leftMargin = paper.leftMargin; info.rightMargin = paper.rightMargin; info.topMargin = paper.topMargin; info.bottomMargin = paper.bottomMargin
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temp
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        guard operation.run() else { throw ScreenplayPDFError.cannotCreatePDF }
        let data = try Data(contentsOf: temp)
        return RenderedScreenplay(data: data, text: text, pageRanges: [], paper: paper, pages: [])
    }
}
#endif
