#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class TimelineWindowPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var workspace: Workspace?
    func open(_ workspace: Workspace) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        self.workspace = workspace
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "Timeline · " + workspace.project.name
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 300)
        panel.delegate = self
        let hosting = NSHostingView(rootView: StoryTimelineView(workspace: workspace, expanded: .constant(true), detached: true).preferredColorScheme(.dark))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 5
        panel.contentView = hosting
        self.panel = panel; workspace.timelineDetached = true
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil; panel = nil; workspace?.timelineDetached = false; workspace = nil
    }
}
#endif
