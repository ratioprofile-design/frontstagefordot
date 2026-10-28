#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import FrontstageCore

@main
struct FrontstageApp: App {
    @StateObject private var workspace: Workspace
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        UserDefaults.standard.register(defaults: [
            "NSConvolutionOverride1": 5.0,
            "NSConvolutionOverride2": 5.0
        ])
        UserDefaults.standard.set(5.0, forKey: "NSConvolutionOverride1")
        UserDefaults.standard.set(5.0, forKey: "NSConvolutionOverride2")
        _workspace = StateObject(wrappedValue: Workspace(recoveryStore: .applicationDefault()))
    }

    var body: some SwiftUI.Scene {
        Window("DOT", id: "workspace") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear {
                    delegate.workspace = workspace
                    workspace.loadRecentProjects()
                    workspace.checkRecovery()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        delegate.setupRecentMenu()
                    }
                    if !delegate.hasPendingOpenFile {
                        workspace.restoreLastProjectIfNeeded()
                    }
                }
                .navigationTitle("")
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        Settings {
            PreferencesView(workspace: workspace)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    workspace.showPreferences = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project", action: workspace.newProject).keyboardShortcut("n")
                Button("Open or Import…", action: workspace.open).keyboardShortcut("o")
                Button("Import Script Document…", action: workspace.importScriptDocument)
                Button("Import Spreadsheet to Research…", action: workspace.importSpreadsheet)
            }
            CommandGroup(after: .newItem) {
                Menu("Open Recent") {
                    if workspace.recentProjects.isEmpty {
                        Button("No Recent Projects") {}
                            .disabled(true)
                    } else {
                        ForEach(workspace.recentProjects, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                workspace.openFile(at: url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            workspace.clearRecentProjects()
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save", action: workspace.save).keyboardShortcut("s")
                Button("Save As…") { workspace.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("Export Screenplay PDF…", action: workspace.exportPDF)
                    .disabled(!workspace.hasActiveScenes)
                Button("Export Final Draft (.fdx)…", action: workspace.exportFDX)
                    .disabled(!workspace.hasActiveScenes)
                Button("Export Fountain (.fountain)…", action: workspace.exportFountain)
                    .disabled(!workspace.hasActiveScenes)
                Button("Export Screenplay DOCX…", action: workspace.exportDOCX)
                    .disabled(!workspace.hasActiveScenes)
                Button("Export Schedule XLSX…", action: workspace.exportScheduleXLSX)
                Divider()
                Button("Print Screenplay…", action: workspace.printScreenplay).keyboardShortcut("p")
                    .disabled(!workspace.hasActiveScenes)
            }
            CommandMenu("Screenplay") {
                ForEach(Array(ScreenplayElement.ordered.enumerated()), id: \.element.rawValue) { index, element in
                    Button("\(index + 1)  \(element.label)") {
                        if element == .sceneHeading, let panel = NSApp.keyWindow as? BeatEditorPanel {
                            panel.focusSlugline()
                        } else {
                            (workspace.focusedScreenplayController ?? workspace.scriptController("write-continuous")).format(element)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }
            CommandMenu("Project") {
                Button("Undo \(workspace.history.undoLabel)", action: workspace.undoProject)
                    .keyboardShortcut("z", modifiers: [.command, .option]).disabled(!workspace.history.canUndo)
                Button("Redo \(workspace.history.redoLabel)", action: workspace.redoProject)
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift]).disabled(!workspace.history.canRedo)
                Divider()
                Button("Pulled-Out Beats Shelf…") { workspace.showPulledOutShelf = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class RecentProjectsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentProjectsMenuDelegate()
    weak var workspace: Workspace?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents: [URL] = {
            if let list = workspace?.recentProjects, !list.isEmpty { return list }
            let paths = UserDefaults.standard.stringArray(forKey: "frontstage_recent_projects") ?? []
            return paths.compactMap { path in
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }()

        if recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for url in recents {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentItems(_:)), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            let targetWorkspace = workspace ?? (NSApp.delegate as? AppDelegate)?.workspace
            targetWorkspace?.openFile(at: url)
        }
    }

    @objc func clearRecentItems(_ sender: NSMenuItem) {
        workspace?.clearRecentProjects()
        UserDefaults.standard.removeObject(forKey: "frontstage_recent_projects")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace? {
        didSet {
            RecentProjectsMenuDelegate.shared.workspace = workspace
            setupRecentMenu()
            if let pending = pendingOpenFile, let workspace {
                _ = workspace.openFile(at: pending)
                pendingOpenFile = nil
            }
        }
    }
    private(set) var pendingOpenFile: URL?
    var hasPendingOpenFile: Bool { pendingOpenFile != nil }

    func setupRecentMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let submenu = item.submenu {
                if submenu.items.contains(where: { $0.title.contains("Open") || $0.title.contains("New Project") }) {
                    let subMenu: NSMenu
                    if let existing = submenu.item(withTitle: "Open Recent"), let sub = existing.submenu {
                        subMenu = sub
                    } else {
                        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
                        let newSub = NSMenu(title: "Open Recent")
                        newSub.delegate = RecentProjectsMenuDelegate.shared
                        recentMenuItem.submenu = newSub

                        if let openIdx = submenu.items.firstIndex(where: { $0.title.contains("Open") }) {
                            submenu.insertItem(recentMenuItem, at: openIdx + 1)
                        } else {
                            submenu.insertItem(recentMenuItem, at: min(1, submenu.items.count))
                        }
                        subMenu = newSub
                    }
                    RecentProjectsMenuDelegate.shared.menuNeedsUpdate(subMenu)
                    return
                }
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSConvolutionOverride1": 5.0,
            "NSConvolutionOverride2": 5.0
        ])
        UserDefaults.standard.set(5.0, forKey: "NSConvolutionOverride1")
        UserDefaults.standard.set(5.0, forKey: "NSConvolutionOverride2")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 5
            window.contentView?.layer?.masksToBounds = false
        }
        updateDockIcon()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDockIcon()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TamilInputManager.restoreStandardInput()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if NSApp.keyWindow == nil {
                    TamilInputManager.restoreStandardInput()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setupRecentMenu()
        }
        DispatchQueue.main.async { [weak self] in
            self?.setupRecentMenu()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        TamilInputManager.restoreStandardInput()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let workspace {
            return workspace.openFile(at: url)
        } else {
            pendingOpenFile = url
            return true
        }
    }

    func updateDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = isDark ? "app_icon_light_standard" : "app_icon_dark_standard"
        if let url = Bundle.main.url(forResource: name, withExtension: "png") ?? Bundle.main.url(forResource: isDark ? "app_icon_light" : "app_icon_dark", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.confirmDiscardOrSave() == false ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class Workspace: ObservableObject {
    var focusedScreenplayController: ScreenplayEditorController? {
        screenplayController(in: NSApp.keyWindow)
    }
    func screenplayController(in focusedWindow: NSWindow?) -> ScreenplayEditorController? {
        if let focused = popup.focusedController(in: focusedWindow) { return focused }
        if let focused = scriptEditors.values.first(where: { controller in
            guard let text = controller.textView, let window = text.window else { return false }
            return focusedWindow === window && window.firstResponder === text
        }) { return focused }
        guard let text = editor.textView, let window = text.window,
              focusedWindow === window, window.firstResponder === text else { return nil }
        return editor
    }
    enum Mode: String, CaseIterable {
        case board = "Whiteboard", edit = "Write", pages = "Pages", revisions = "Revisions", people = "People", breakdown = "Breakdown", production = "Production", writingTools = "Writing Tools", studio = "Research & Studio", shared = "Shared Projects"
    }
    @Published private(set) var project = Project(oneBeatPerScene: true)
    var writingSelectedQuote: (sceneID: Decimal, text: String)?
    @Published var selectedSceneID: Decimal? {
        didSet { if oldValue != selectedSceneID { editor.textView?.undoManager?.removeAllActions() } }
    }
    @Published private(set) var hasChanges = false
    @Published var errorMessage: String?
    @Published var selectedBoardBeatID: String?
    @Published var pendingBoardCauseID: String?
    @Published var showBoardScript = true
    @Published var writeCardsVisible = UserDefaults.standard.object(forKey: "write-left-visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(writeCardsVisible, forKey: "write-left-visible") }
    }
    @Published var writeInspectorVisible = UserDefaults.standard.object(forKey: "write-right-visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(writeInspectorVisible, forKey: "write-right-visible") }
    }
    @Published var writeCardsToggle = 0
    @Published var writeInspectorToggle = 0
    @Published var showInspector: Bool = true {
        didSet { writeInspectorVisible = showInspector }
    }
    func toggleInspector() {
        showInspector.toggle()
        writeInspectorToggle += 1
    }
    func toggleSidebar() {
        if mode == .edit {
            writeCardsVisible.toggle()
            writeCardsToggle += 1
        } else {
            showBoardScript.toggle()
        }
    }
    @Published var reader = ScriptReaderSettings()
    @Published var whiteboardRipple = true
    @Published var selectedResearchID: String?
    @Published var mode = Mode.board {
        didSet { if oldValue != mode { editor.textView?.undoManager?.removeAllActions() } }
    }
    @Published var paper = ScreenplayPaper.a4
    @Published var showPreferences = false
    @Published var showPulledOutShelf = false
    @Published private(set) var preview: PDFDocument?
    @Published private(set) var history = ProjectHistory()
    @Published private(set) var recoveryCandidate: Project?
    @Published private(set) var recoveryStatus = ""
    @Published private(set) var changeID = 0
    private(set) var documentSessionID = UUID()
    @Published private(set) var whiteboardCache: Whiteboard?
    let editor = ScreenplayEditorController()
    private var scriptEditors: [String: ScreenplayEditorController] = [:]
    func scriptController(_ id: String) -> ScreenplayEditorController {
        if let controller = scriptEditors[id] { return controller }
        let controller = ScreenplayEditorController(); scriptEditors[id] = controller; return controller
    }
    @Published var timelineDetached = false
    let timelineWindow = TimelineWindowPresenter()
    let popup = BeatPopupPresenter()
    let sharedProjects = SharedProjectClient()
    private var saveURL: URL?
    private var savedProject: Project? = Project(oneBeatPerScene: true)
    private let recoveryStore: RecoveryStore?
    private var recoveryTask: Task<Void, Never>?
    private var checkedRecovery = false
    private var recoveryBlocked = false

    @Published var restoreLastProjectAutomatically: Bool = UserDefaults.standard.object(forKey: "frontstage_restore_last_project") as? Bool ?? true {
        didSet { UserDefaults.standard.set(restoreLastProjectAutomatically, forKey: "frontstage_restore_last_project") }
    }
    @Published var recentProjects: [URL] = []

    func loadRecentProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: "frontstage_recent_projects") ?? []
        recentProjects = paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func recordRecentProject(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        var paths = UserDefaults.standard.stringArray(forKey: "frontstage_recent_projects") ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 15 {
            paths = Array(paths.prefix(15))
        }
        UserDefaults.standard.set(paths, forKey: "frontstage_recent_projects")
        UserDefaults.standard.set(path, forKey: "frontstage_last_project_path")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        loadRecentProjects()
    }

    func clearRecentProjects() {
        UserDefaults.standard.removeObject(forKey: "frontstage_recent_projects")
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentProjects = []
    }

    func restoreLastProjectIfNeeded() {
        guard restoreLastProjectAutomatically else { return }
        guard saveURL == nil, !hasChanges else { return }
        if let lastPath = UserDefaults.standard.string(forKey: "frontstage_last_project_path"),
           FileManager.default.fileExists(atPath: lastPath) {
            let url = URL(fileURLWithPath: lastPath)
            do {
                let imported = try Project.load(from: url)
                loadCopy(imported)
                saveURL = url
                savedProject = imported
                didSave()
                recordRecentProject(url)
            } catch {
                // If project cannot be loaded, safely continue with fresh project
            }
        }
    }

    init(recoveryStore: RecoveryStore? = nil) {
        self.recoveryStore = recoveryStore
        loadRecentProjects()
    }

    func checkRecovery() {
        guard !checkedRecovery else { return }
        checkedRecovery = true
        do { recoveryCandidate = try recoveryStore?.load() }
        catch {
            recoveryBlocked = true
            recoveryStatus = "Recovery disabled: unreadable copy preserved"
            errorMessage = "The recovery copy could not be read. It has been kept on disk and will not be overwritten. \(error.localizedDescription)"
        }
    }

    func recoverSession() {
        guard let candidate = recoveryCandidate else { return }
        recoveryCandidate = nil
        loadCopy(candidate)
    }

    func acceptConvertedCopy(_ copy: Project) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Frontstage/Conversion Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try project.encoded().write(to: root.appendingPathComponent(UUID().uuidString + ".frontstage"), options: .atomic)
        loadCopy(copy); mode = .edit
    }

    func loadCopy(_ imported: Project) {
        documentSessionID = UUID()
        reader.filters = .init(); reader.filter = ""
        sharedProjects.detach()
        popup.close()
        scriptEditors.removeAll()
        selectedBoardBeatID = nil
        recoveryTask?.cancel()
        editor.textView?.undoManager?.removeAllActions()
        project = imported
        savedProject = nil
        history = ProjectHistory()
        selectedSceneID = project.scenes.first?.id
        saveURL = nil
        mode = .board
        preview = nil
        changed()
    }

    func discardRecovery() {
        do { try recoveryStore?.clear(); recoveryCandidate = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func flushRecovery() throws {
        recoveryTask?.cancel()
        guard !recoveryBlocked else { throw ProjectError.invalidProject("an unreadable recovery copy must be recovered manually before automatic recovery can resume") }
        if hasChanges {
            try recoveryStore?.save(project)
            if recoveryStore != nil { recoveryStatus = "Recovery copy saved" }
        } else { try recoveryStore?.clear() }
    }

    func edit(_ label: String, key: String? = nil, _ operation: (inout Project) throws -> Void) {
        guard sharedProjects.linked?.access != "reader" else { errorMessage = "This shared project is read-only."; return }
        let previous = project
        do {
            try operation(&project)
            try project.validateSceneModel()
            guard project != previous else { return }
            history.record(previous, label: label, key: key)
            changed()
        } catch { project = previous; errorMessage = error.localizedDescription }
    }

    func updateScriptLayout(_ action: (inout ScriptLayoutSettings) -> Void) {
        var layout = project.scriptLayout
        action(&layout)
        edit("Script Typography") { try $0.setScriptLayout(layout) }
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: "default_script_layout")
        }
        changeID += 1
    }

    func undoProject() {
        guard let previous = history.undo(current: project) else { return }
        project = previous
        reconcileSelection()
        changed()
    }

    func redoProject() {
        guard let next = history.redo(current: project) else { return }
        project = next
        reconcileSelection()
        changed()
    }

    private func reconcileSelection() {
        if !project.scenes.contains(where: { $0.id == selectedSceneID }) { selectedSceneID = project.scenes.first?.id }
        editor.textView?.undoManager?.removeAllActions()
        for id in popup.panels.keys { popup.controller(for: id)?.textView?.undoManager?.removeAllActions() }
        for controller in scriptEditors.values { controller.textView?.undoManager?.removeAllActions() }
        if !whiteboard.beats.contains(where: { $0.id == selectedBoardBeatID }) { selectedBoardBeatID = whiteboard.orderedBeats.first?.id }
        if let beat = whiteboard.beats.first(where: { $0.id == selectedBoardBeatID }), project.scenes.contains(where: { $0.id == beat.sceneID }) { selectedSceneID = beat.sceneID }
        if project.scenes.isEmpty { selectedSceneID = nil; selectedBoardBeatID = nil }
    }

    private func didSave() {
        savedProject = project
        hasChanges = false
        recoveryTask?.cancel()
        do { if !recoveryBlocked { try recoveryStore?.clear(); recoveryStatus = "" } }
        catch { recoveryStatus = "Saved project; recovery cleanup failed" }
    }

    var selectedScene: FrontstageCore.Scene? {
        project.scenes.first { $0.id == selectedSceneID }
    }
    var hasActiveScenes: Bool { project.scenes.contains { !$0.isDisabled } }

    func newProject() {
        guard confirmDiscardOrSave() else { return }
        documentSessionID = UUID()
        reader.filters = .init(); reader.filter = ""
        sharedProjects.detach()
        popup.close(); scriptEditors.removeAll(); selectedBoardBeatID = nil
        recoveryTask?.cancel()
        if !recoveryBlocked {
            do { try recoveryStore?.clear() }
            catch { errorMessage = error.localizedDescription; return }
        }
        editor.textView?.undoManager?.removeAllActions()
        project = Project(oneBeatPerScene: true)
        if let defaultData = UserDefaults.standard.data(forKey: "default_script_layout"),
           let defaultLayout = try? JSONDecoder().decode(ScriptLayoutSettings.self, from: defaultData) {
            _ = try? project.setScriptLayout(defaultLayout)
        }
        whiteboardCache = nil
        savedProject = project
        history = ProjectHistory()
        saveURL = nil
        hasChanges = false
        selectedSceneID = nil
        mode = .board
        preview = nil
    }

    func addScene() {
        if project.preservedState["frontstageWhiteboard"] != nil {
            addWhiteboardBeat()
            mode = .board
            return
        }
        var id: Decimal?
        edit("Add Scene") { id = $0.addScene() }
        selectedSceneID = id
        mode = .board
    }

    func updateScene(id: Decimal, title: String? = nil, html: String? = nil, summary: String? = nil,
                     heading: SceneHeading? = nil, sceneNumber: String? = nil) {
        let field = html != nil ? "Text" : heading != nil ? "Heading" : title != nil ? "Title" : summary != nil ? "Summary" : "Number"
        edit("Edit Scene \(field)", key: "\(id)-\(field)") {
            try $0.updateScene(id: id, title: title, html: html, summary: summary,
                                    heading: heading, sceneNumber: sceneNumber)
        }
    }

    func rename(_ name: String) {
        edit("Rename Project", key: "name") { $0.name = name }
    }

    private func changed() {
        whiteboardCache = try? project.whiteboard()
        if let board = whiteboardCache { popup.refreshTitles(board) }
        changeID &+= 1
        hasChanges = project != savedProject
        preview = nil
        if mode == .pages { makePreview() }
        recoveryTask?.cancel()
        if recoveryStore != nil && !recoveryBlocked {
            recoveryStatus = hasChanges ? "Recovery copy pending…" : ""
            recoveryTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                do { try self.flushRecovery() }
                catch { self.recoveryStatus = "Recovery unavailable: \(error.localizedDescription)" }
            }
        }
    }

    func makePreview() {
        guard hasActiveScenes else { preview = nil; return }
        do {
            let result = try ScreenplayPDF.render(project: project, paper: paper)
            guard let document = PDFDocument(data: result.data) else { throw ScreenplayPDFError.cannotCreatePDF }
            preview = document
        } catch { preview = nil; errorMessage = error.localizedDescription }
    }

    func exportPDF() {
        do {
            let result = try ScreenplayPDF.render(project: project, paper: paper)
            try exportPDF(result, name: project.name)
        } catch { errorMessage = error.localizedDescription }
    }

    func exportPDF(_ result: RenderedScreenplay, name: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try result.save(to: url)
    }

    func printScreenplay() {
        do {
            let result = try ScreenplayPDF.render(project: project, paper: paper)
            try printPDF(result)
        } catch { errorMessage = error.localizedDescription }
    }

    func printPDF(_ result: RenderedScreenplay) throws {
            guard let document = PDFDocument(data: result.data) else { throw ScreenplayPDFError.cannotCreatePDF }
            let settings = NSPrintInfo.shared.copy() as! NSPrintInfo
            settings.paperSize = NSSize(width: result.paper.width, height: result.paper.height)
            settings.orientation = .portrait
            guard let operation = document.printOperation(for: settings, scalingMode: .pageScaleToFit, autoRotate: false) else {
                throw ScreenplayPDFError.cannotCreatePDF
            }
            operation.run()
    }

    @discardableResult
    func openFile(at url: URL) -> Bool {
        guard confirmDiscardOrSave() else { return false }
        do {
            let imported = try Project.load(from: url)
            loadCopy(imported)
            saveURL = url
            savedProject = imported
            didSave()
            recordRecentProject(url)
            NSApp.activate(ignoringOtherApps: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func open() {
        guard confirmDiscardOrSave() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "frontstage") ?? .data,
            UTType(filenameExtension: "dot") ?? .data,
            UTType(filenameExtension: "backstage") ?? .data,
            .json
        ]
        panel.allowsMultipleSelection = false
        panel.message = "Open a Frontstage or DOT project file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(at: url)
    }

    func save() { _ = saveCurrent() }

    static func applyFileIcon(to url: URL) {
        #if os(macOS)
        let resolved = url.resolvingSymlinksInPath()
        let image: NSImage? = {
            if let path = Bundle.main.path(forResource: "DocIcon", ofType: "icns"),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
            return NSApp?.applicationIconImage
        }()
        if let image {
            NSWorkspace.shared.setIcon(image, forFile: resolved.path, options: [])
        }
        #endif
    }

    static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Screenplay" : trimmed
        return base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    @discardableResult
    private func saveCurrent() -> Bool {
        guard let currentURL = saveURL else { return saveAs() }
        let desiredFileName = "\(Self.sanitizeFileName(project.name)).frontstage"
        let folder = currentURL.deletingLastPathComponent()
        let targetURL = folder.appendingPathComponent(desiredFileName)

        if currentURL.lastPathComponent != desiredFileName {
            if FileManager.default.fileExists(atPath: targetURL.path) && targetURL.standardizedFileURL != currentURL.standardizedFileURL {
                return saveAs()
            }
            do {
                try project.save(to: targetURL)
                Self.applyFileIcon(to: targetURL)
                if FileManager.default.fileExists(atPath: currentURL.path) && currentURL.standardizedFileURL != targetURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: currentURL)
                }
                saveURL = targetURL
                didSave()
                recordRecentProject(targetURL)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }

        do {
            try project.save(to: currentURL)
            Self.applyFileIcon(to: currentURL)
            didSave()
            recordRecentProject(currentURL)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "frontstage") ?? .json]
        let desiredFileName = "\(Self.sanitizeFileName(project.name)).frontstage"
        panel.nameFieldStringValue = desiredFileName
        if let currentURL = saveURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
        }
        panel.message = "Save a Frontstage project copy."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try project.save(to: url)
            Self.applyFileIcon(to: url)
            saveURL = url
            didSave()
            recordRecentProject(url)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func confirmDiscardOrSave() -> Bool {
        guard hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(project.name)?"
        alert.informativeText = "Unsaved edits will be lost if you discard them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveCurrent()
        case .alertThirdButtonReturn:
            recoveryTask?.cancel()
            do { if !recoveryBlocked { try recoveryStore?.clear() }; return true }
            catch { errorMessage = error.localizedDescription; return false }
        default: return false
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    private var isSidebarVisible: Bool {
        if workspace.mode == .edit {
            return false
        }
        return workspace.showBoardScript
    }

    private var detailView: some View {
        Group {
            if workspace.mode == .shared {
                SharedProjectsView(workspace: workspace, client: workspace.sharedProjects)
            } else if workspace.mode == .studio {
                StudioView(workspace: workspace)
            } else if workspace.mode == .writingTools {
                WritingToolsView(workspace: workspace)
            } else if workspace.mode == .production {
                ProductionView(workspace: workspace)
            } else if workspace.mode == .people {
                PeopleView(workspace: workspace)
            } else if workspace.mode == .breakdown {
                BreakdownView(workspace: workspace)
            } else if workspace.mode == .board {
                StoryWorkspaceView(workspace: workspace, boardFirst: true)
            } else if workspace.mode == .revisions {
                RevisionsView(workspace: workspace)
            } else if workspace.mode == .pages {
                if let preview = workspace.preview {
                    VStack(spacing: 0) {
                        Text("\(preview.pageCount) pages · \(workspace.paper.label)")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                        ScreenplayPDFView(document: preview)
                    }
                } else {
                    ContentUnavailableView("No screenplay pages", systemImage: "doc.text",
                        description: Text("Add an active scene to preview the screenplay."))
                }
            } else {
                ScriptWritingWorkspace(workspace: workspace)
            }
        }
        .background(Color(boardHex: WorkspaceDesign.panelColor))
    }

    private var workspaceLayout: some View {
        HSplitView {
            if isSidebarVisible {
                ScriptSidePaper(workspace: workspace)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            }
            detailView
        }
    }

    private var bottomStatusBar: some View {
        HStack {
            Text(workspace.hasChanges ? "Unsaved project changes" : "No pending changes")
            Spacer()
            if !workspace.recoveryStatus.isEmpty { Text(workspace.recoveryStatus) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(Color(boardHex: WorkspaceDesign.panelColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private struct WindowSharpener: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = 5
                window.contentView?.layer?.masksToBounds = false
            }
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                window.contentView?.layer?.cornerRadius = 5
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceLayout
            bottomStatusBar
        }
        .background(WindowSharpener())
        .toolbar { workspaceToolbar }
        .preferredColorScheme(.dark)
        .font(.system(size: 12))
        .navigationTitle("")
        .onChange(of: workspace.mode) { _, mode in if mode == .pages { workspace.makePreview() } }
        .onChange(of: workspace.paper) { _, _ in if workspace.mode == .pages { workspace.makePreview() } }
        .sheet(isPresented: $workspace.showPreferences) {
            PreferencesView(workspace: workspace)
        }
        .sheet(isPresented: Binding(get: { workspace.recoveryCandidate != nil }, set: { _ in })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Recover your last session?").font(.title2)
                Text("A recovery copy of \(workspace.recoveryCandidate?.name ?? "your project") was found. Recover it as a new unsaved copy, or discard it.")
                HStack {
                    Button("Discard Recovery", action: workspace.discardRecovery)
                    Spacer()
                    Button("Recover", action: workspace.recoverSession).keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 440).interactiveDismissDisabled()
        }
        .alert("DOT", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } })) {
                Button("OK") { workspace.errorMessage = nil }
            } message: { Text(workspace.errorMessage ?? "") }
        .sheet(isPresented: $workspace.showPulledOutShelf) {
            PulledOutShelf(workspace: workspace)
        }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                CompanyLogoView()

                Divider().frame(height: 14)

                Button {
                    workspace.toggleSidebar()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sidebar.left")
                        Text("Sidebar")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
                .help("Toggle Sidebar (Script / Cards)")
            }
        }

        ToolbarItem(placement: .principal) {
            PageTabsView(workspace: workspace)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.toggleInspector()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sidebar.right")
                    Text("Inspector")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
            .help("Toggle Inspector Panel")

            Button("Add Scene", systemImage: "plus", action: workspace.addScene)
                .help("Add Scene")
            Button("Save", systemImage: "square.and.arrow.down", action: workspace.save)
                .help("Save Project")

            Menu {
                Button {
                    workspace.exportPDF()
                } label: {
                    Label("Export Screenplay PDF…", systemImage: "doc.richtext")
                }
                Button {
                    workspace.exportFDX()
                } label: {
                    Label("Export Final Draft (.fdx)…", systemImage: "doc.text")
                }
                Button {
                    workspace.exportFountain()
                } label: {
                    Label("Export Fountain (.fountain)…", systemImage: "character.cursor.ibeam")
                }
                Divider()
                Button {
                    workspace.exportDOCX()
                } label: {
                    Label("Export Microsoft Word (.docx)…", systemImage: "doc")
                }
                Button {
                    workspace.exportScheduleXLSX()
                } label: {
                    Label("Export Production Schedule (.xlsx)…", systemImage: "tablecells")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
            .disabled(!workspace.hasActiveScenes)
            .help("Export Screenplay in various formats (PDF, Final Draft, Fountain, Word)")
        }
    }
}

struct PageTabsView: View {
    @ObservedObject var workspace: Workspace
    @State private var hoveredMode: Workspace.Mode?

    private let primaryModes: [(Workspace.Mode, String, String)] = [
        (.board, "Whiteboard", "rectangle.3.group"),
        (.edit, "Write", "pencil.line"),
        (.pages, "Pages", "doc.text")
    ]

    private let secondaryModes: [(Workspace.Mode, String, String)] = [
        (.revisions, "Revisions", "clock.arrow.circlepath"),
        (.people, "People", "person.2"),
        (.breakdown, "Breakdown", "list.bullet.rectangle"),
        (.production, "Production", "film"),
        (.writingTools, "Tools", "wrench.and.screwdriver"),
        (.studio, "Studio", "books.vertical"),
        (.shared, "Shared", "person.crop.circle.badge.plus")
    ]

    private var activeSecondary: (Workspace.Mode, String, String)? {
        secondaryModes.first { $0.0 == workspace.mode }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(primaryModes, id: \.0) { mode, title, icon in
                let isSelected = workspace.mode == mode
                let isHovered = hoveredMode == mode && !isSelected

                Button {
                    workspace.mode = mode
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(
                                isSelected ? Color.white :
                                isHovered ? Color.white.opacity(0.95) :
                                Color(white: 0.62)
                            )
                        Text(title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(
                                isSelected ? Color.white :
                                isHovered ? Color.white.opacity(0.95) :
                                Color(white: 0.65)
                            )
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.22),
                                                Color.white.opacity(0.12)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(
                                                LinearGradient(
                                                    colors: [
                                                        Color.white.opacity(0.35),
                                                        Color.white.opacity(0.08)
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                ),
                                                lineWidth: 0.75
                                            )
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.07))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.clear)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredMode = hovering ? mode : nil
                }
            }

            // Divider between core modes and More dropdown
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 1)

            // More Dropdown Menu for secondary production tools
            Menu {
                ForEach(secondaryModes, id: \.0) { mode, title, icon in
                    Button {
                        workspace.mode = mode
                    } label: {
                        Label(title, systemImage: icon)
                    }
                }
                Divider()
                Button {
                    workspace.showPulledOutShelf = true
                } label: {
                    Label("Pulled-Out Beats Shelf…", systemImage: "tray.full")
                }
            } label: {
                let isSecondaryActive = activeSecondary != nil
                HStack(spacing: 4) {
                    if let active = activeSecondary {
                        Image(systemName: active.2)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text(active.1)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                    } else {
                        Text("More")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color(white: 0.65))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSecondaryActive ? Color.white : Color(white: 0.55))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Group {
                        if isSecondaryActive {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.12)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.75
                                        )
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                        }
                    }
                )
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.11),
                            Color(white: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.09), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
        .animation(.snappy(duration: 0.18), value: workspace.mode)
        .animation(.easeOut(duration: 0.12), value: hoveredMode)
    }
}

struct CompanyLogoView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let name = colorScheme == .light ? "logo_light_trimmed" : "logo_dark_trimmed"
        if let url = Bundle.main.url(forResource: name, withExtension: "png") ?? Bundle.main.url(forResource: "logo_dark_trimmed", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(height: 18)
                .padding(.horizontal, 4)
                .help("DOT Screenplay")
        } else {
            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("DOT")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }
}

struct SceneWritingView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let scene = workspace.selectedScene {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    TextField("Scene title", text: Binding(
                        get: { workspace.selectedScene?.title ?? "" },
                        set: { workspace.updateScene(id: scene.id, title: $0) }))
                        .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                    if scene.isDisabled { Text("OMITTED").font(.caption).foregroundStyle(.orange) }
                }
                TextField("Beat summary — what changes because of this scene?", text: Binding(
                    get: { workspace.selectedScene?.summary ?? "" },
                    set: { workspace.updateScene(id: scene.id, summary: $0) }))
                    .textFieldStyle(.roundedBorder)
                SceneHeadingFields(scene: scene, workspace: workspace)
                ScreenplayFormatBar(controller: workspace.editor)
                ScreenplayEditor(html: Binding(
                    get: { workspace.selectedScene?.html ?? "" },
                    set: { workspace.updateScene(id: scene.id, html: $0) }),
                    controller: workspace.editor, width: workspace.paper.contentWidth,
                    onError: { workspace.errorMessage = $0 })
                    .id(scene.id)
            }.padding(16)
        } else {
            ContentUnavailableView {
                Label("Your next story starts here", systemImage: "doc.richtext")
            } description: {
                Text("Create a beat in the sequencer, or import a Backstage project as a copy.")
            } actions: {
                Button("Add Scene", action: workspace.addScene)
                Button("Open or Import…", action: workspace.open)
            }
        }
    }
}

@MainActor
func findField(_ identifier: String, in view: NSView) -> NSTextField? {
    if let tf = view as? NSTextField, tf.identifier?.rawValue == identifier {
        return tf
    }
    for sub in view.subviews {
        if let match = findField(identifier, in: sub) {
            return match
        }
    }
    return nil
}

@MainActor
func findScreenplayTextView(in view: NSView) -> ScreenplayTextView? {
    if let tv = view as? ScreenplayTextView {
        return tv
    }
    for sub in view.subviews {
        if let match = findScreenplayTextView(in: sub) {
            return match
        }
    }
    return nil
}

struct ScriptSuggestionField: NSViewRepresentable {
    let label: String
    @Binding var text: String
    let options: [String]
    var identifier: String? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text.uppercased())
        field.placeholderString = label; field.setAccessibilityLabel(label)
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        if let identifier { field.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self; field.isEnabled = enabled
        if let identifier { field.identifier = NSUserInterfaceItemIdentifier(identifier) }
        if field.currentEditor() == nil { field.stringValue = text.uppercased() }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScriptSuggestionField
        var completing = false
        init(_ parent: ScriptSuggestionField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            if let editor = field.currentEditor() as? NSTextView, editor.string != editor.string.uppercased() {
                let caret = editor.selectedRange();let prefix = (editor.string as NSString).substring(to: min(caret.location, (editor.string as NSString).length)).uppercased()
                editor.string = editor.string.uppercased();editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            }
            parent.text = field.stringValue.uppercased()
            guard !completing, let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText(), !field.stringValue.isEmpty else { return }
            completing = true; editor.complete(nil); completing = false
        }
        func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            let source = textView.string as NSString
            let prefix = source.substring(to: NSMaxRange(range))
            let before = source.substring(to: range.location)
            index.pointee = -1
            return Array(Set(parent.options.map { $0.uppercased() })).sorted().filter { $0.lowercased().hasPrefix(prefix.lowercased()) && $0.lowercased() != prefix.lowercased() }.map { String($0.dropFirst(before.count)) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard let window = control.window, let content = window.contentView else { return false }
                if parent.identifier == "beatPopupSluglinePrefix" {
                    if let next = findField("beatPopupSluglineLocation", in: content) {
                        window.makeFirstResponder(next)
                        next.selectText(nil)
                        return true
                    }
                } else if parent.identifier == "beatPopupSluglineLocation" {
                    let timeField = findField("beatPopupSluglineTime", in: content)
                    if let timeField, timeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        window.makeFirstResponder(timeField)
                        timeField.selectText(nil)
                        return true
                    } else if let tv = findScreenplayTextView(in: content) {
                        window.makeFirstResponder(tv)
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                        return true
                    }
                } else if parent.identifier == "beatPopupSluglineTime" {
                    if let tv = findScreenplayTextView(in: content) {
                        window.makeFirstResponder(tv)
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                        return true
                    }
                }
            }
            return false
        }
    }
}

struct SceneHeadingFields: View {
    let scene: FrontstageCore.Scene
    @ObservedObject var workspace: Workspace
    var compact = false
    private var current: FrontstageCore.Scene { workspace.project.scenes.first { $0.id == scene.id } ?? scene }
    private func heading(_ key: WritableKeyPath<SceneHeading, String>) -> Binding<String> {
        Binding(get: { current.heading[keyPath: key] }, set: { value in
            var updated = current.heading; updated[keyPath: key] = value.uppercased()
            workspace.updateScene(id: scene.id, heading: updated)
        })
    }
    @ViewBuilder private var fields: some View {
        ScriptSuggestionField(label: "INT. / EXT.", text: heading(\.prefix), options: ["INT.", "EXT.", "INT./EXT.", "EXT./INT."])
        ScriptSuggestionField(label: "Location", text: heading(\.location), options: Array(Set(workspace.project.scenes.map { $0.heading.location }.filter { !$0.isEmpty })).sorted())
        ScriptSuggestionField(label: "DAY / NIGHT", text: heading(\.time), options: ["DAY", "NIGHT", "DAWN", "DUSK", "MORNING", "AFTERNOON", "EVENING", "LATER", "CONTINUOUS", "SAME TIME"])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SLUGLINE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if compact { VStack { fields } } else { HStack { fields } }
            TextField("Auto #", text: Binding(get: { current.sceneNumber }, set: { workspace.updateScene(id: scene.id, sceneNumber: $0) }))
                .frame(width: 65).accessibilityLabel("Scene number override")
        }.disabled(current.isTextLocked)
    }
}

extension Workspace {
    static let screenplayFixedCompletions: [ScreenplayElement: [String]] = [
        .transition: ["CUT TO:", "DISSOLVE TO:", "FADE IN:", "FADE OUT.", "FADE TO BLACK.", "SMASH CUT TO:", "MATCH CUT TO:"],
        .parenthetical: CharacterCue.deliveryNotes, .shot: ["CLOSE ON", "ANGLE ON", "INSERT", "POV"]]
    var screenplayCompletions: [ScreenplayElement: [String]] {
        var choices = Self.screenplayFixedCompletions
        choices[.character] = Array(Set((project.characters.map(\.name) + whiteboard.beats.flatMap(\.characters) + whiteboard.beats.flatMap { ScriptCueNames.characters(in: $0.html) } + project.scenes.flatMap { ScriptCueNames.characters(in: $0.html) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })).filter { !$0.isEmpty }.sorted()
        choices[.sceneHeading] = project.scenes.map { $0.heading.inlineText }
        return choices
    }
}

struct ScreenplaySuggestions: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: ScreenplayEditorController
    private var names: [String] {
        Array(Set(workspace.project.characters.map(\.name) + workspace.whiteboard.beats.flatMap(\.characters))).filter { !$0.isEmpty }.sorted()
    }
    var body: some View {
        Text("Type for suggestions · Tab changes screenplay element")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct ScreenplayFormatBar: View {
    @ObservedObject var controller: ScreenplayEditorController
    var body: some View {
        HStack {
            Picker("Element", selection: Binding(get: { controller.activeElement }, set: { controller.format($0) })) {
                ForEach(ScreenplayElement.editable, id: \.self) { element in Text(element.label).tag(element) }
            }.frame(width: 210)
            Spacer()
            Text("Tab changes element · Return continues dialogue · ⌥1–7 formats")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#else
import Foundation
@main
struct FrontstageUnsupportedPlatform {
    static func main() {
        FileHandle.standardError.write(Data("Frontstage's native UI requires macOS 14 or later. Run swift test to validate the portable core.\n".utf8))
    }
}
#endif
