#if os(macOS)
import AppKit
import SwiftUI
import FrontstageCore

struct WhiteboardCanvas: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    @Binding var selection: Set<String>
    @Binding var blockSelection: Set<String>
    var pushing: Bool = false
    var drawing: Bool
    var fitRequest: Int

    func makeNSView(context: Context) -> NativeWhiteboard {
        let view = NativeWhiteboard()
        view.workspace = workspace
        view.registerForDraggedTypes([.string])
        return view
    }
    func updateNSView(_ view: NativeWhiteboard, context: Context) {
        view.workspace = workspace; view.board = workspace.whiteboard
        view.selection = selection; view.blockSelection = blockSelection
        if view.drawingMode != drawing {
            view.drawingMode = drawing
            view.window?.invalidateCursorRects(for: view)
        }
        view.pushingMode = pushing
        view.selected = { ids, blocks in selection = ids; blockSelection = blocks }
        if view.fitRequest != fitRequest { view.fitRequest = fitRequest; view.fitSelection() }
        view.needsDisplay = true
    }
}

@MainActor
final class NativeWhiteboard: NSView, NSTextFieldDelegate {
    weak var workspace: Workspace?
    var board = Whiteboard() {
        didSet {
            if isErasing && !erasedStrokeIDs.isEmpty {
                board.strokes.removeAll { erasedStrokeIDs.contains($0.id) }
            }
            geometry = WhiteboardLayout(board, measureBeat: WhiteboardBeatText.size)
        }
    }
    private var geometry = WhiteboardLayout(Whiteboard())
    var selection = Set<String>()
    var blockSelection = Set<String>()
    var selected: ((Set<String>, Set<String>) -> Void)?
    var drawingMode = false
    var pushingMode = false
    private var isErasing = false
    private var eraserStroke: [BoardPoint] = []
    private var erasedStrokeIDs = Set<String>()
    private var pushOrigin: BoardPoint?
    private var dependencyOrigin: String?
    var fitRequest = 0
    private var dragStart: BoardPoint?
    private var viewStart = NSPoint.zero
    private var dragDelta = BoardPoint()
    private var panStart: BoardPoint?
    private var movingBlocks = false
    private var expandedDragBlocks = Set<String>()
    private var movingBeat: String?
    private var resizingBlock: String?
    private var resizeWidth = 224.0
    private var marquee: BoardRect?
    private var stroke: [BoardPoint] = []
    private var spaceHeld = false
    private var contextBeat: String?
    private var contextBlock: String?
    private var contextPoint = BoardPoint()
    private var inlineField: NSTextField?
    private var inlineDestination: (layer: String, position: BoardPoint, parent: String?)?
    func beginInlineBeat(layerID: String, position: BoardPoint, parentID: String? = nil) {
        guard let workspace, let layer = board.layers.first(where: { $0.id == layerID }), !layer.locked else { return }
        guard !board.usesBlocks(layerID) || parentID != nil else { workspace.errorMessage = "Create beats inside a block on this layer"; return }
        if let parentID, board.isBlockLocked(parentID) { return }
        inlineField?.removeFromSuperview()
        let field = NSTextField(string: "")
        field.placeholderString = "Beat name"; field.setAccessibilityLabel("New beat name")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.backgroundColor = .systemPurple; field.textColor = .white
        field.frame = NSRect(x: (position.x + 110 - board.viewport.origin.x) * zoom,
            y: (position.y + (geometry.layerRects[layerID]?.y ?? 0) - board.viewport.origin.y) * zoom,
            width: max(140, 224 * zoom), height: 28)
        field.delegate = self; inlineField = field; inlineDestination = (layerID, position, parentID)
        addSubview(field); window?.makeFirstResponder(field)
    }
    private func finishInlineBeat(next: Bool, cancel: Bool = false) {
        guard let field = inlineField, let destination = inlineDestination else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineField = nil; inlineDestination = nil; field.delegate = nil; field.removeFromSuperview()
        guard !cancel, !title.isEmpty, let workspace else { window?.makeFirstResponder(self); return }
        var created: String?
        workspace.edit("Create Beat") { project in
            let id = try project.createBoardItem(.beat, layerID: destination.layer, position: destination.position, parentID: destination.parent)
            try project.updateBoardBeat(id) { $0.title = title }; created = id
        }
        guard let created else { return }
        board = workspace.whiteboard; workspace.selectBoardBeat(created); selection = [created]; selected?(selection, [])
        if next {
            let height = geometry.beatRects[created]?.height ?? 28
            beginInlineBeat(layerID: destination.layer, position: .init(x: destination.position.x, y: destination.position.y + height + 12), parentID: destination.parent)
        }
        needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishInlineBeat(next: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishInlineBeat(next: false, cancel: true); return true }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { finishInlineBeat(next: false) }

    private func paletteKind(_ sender: NSDraggingInfo) -> BoardPaletteItem? {
        guard let value = sender.draggingPasteboard.string(forType: .string), value.hasPrefix("frontstage-palette:") else { return nil }
        return BoardPaletteItem(rawValue: String(value.dropFirst("frontstage-palette:".count)))
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { paletteKind(sender) == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let kind = paletteKind(sender), let workspace else { return false }
        let point = world(convert(sender.draggingLocation, from: nil)), layer = layerAt(point)
        let parent = hitBlock(point).flatMap { id in board.blocks.first { $0.id == id && $0.standalone != true }?.id }
        let position = BoardPoint(x: max(0, point.x - 110), y: max(32, point.y - (geometry.layerRects[layer.id]?.y ?? 0)))
        var created: String?
        workspace.edit("Create \(kind.rawValue.capitalized)") { created = try $0.createBoardItem(kind, layerID: layer.id, position: position, parentID: kind == .block || kind == .lane ? nil : parent) }
        if let created, kind == .beat { workspace.selectBoardBeat(created); workspace.popup.open(created, workspace: workspace) }
        return created != nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Story whiteboard" }
    override func accessibilityChildren() -> [Any]? {
        let visibleIDs = geometry.beats(in: visible)
        return board.orderedBeats.filter { visibleIDs.contains($0.id) }.compactMap { beat -> NSAccessibilityElement? in
            guard let rect = geometry.beatRects[beat.id], let frame = screenRect(rect) else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(beat.title)
            element.setAccessibilityHelp("Story beat. Use Edit Beat to open its snippet editor.")
            element.setAccessibilityValue(selection.contains(beat.id) ? "Selected" : "")
            element.setAccessibilityFrame(frame)
            element.setAccessibilityParent(self)
            element.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Edit Beat", handler: { [weak self] in
                guard let self else { return false }; self.openPopup(beat.id); return true
            })])
            return element
        }
    }

    private var zoom: Double { board.viewport.zoom }
    private func world(_ point: NSPoint) -> BoardPoint {
        BoardPoint(x: point.x / zoom + board.viewport.origin.x, y: point.y / zoom + board.viewport.origin.y)
    }
    private func screenRect(_ rect: BoardRect) -> NSRect? {
        guard let window else { return nil }
        let local = NSRect(x: (rect.x - board.viewport.origin.x) * zoom, y: (rect.y - board.viewport.origin.y) * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return window.convertToScreen(convert(local, to: nil))
    }
    private var visible: BoardRect {
        BoardRect(x: board.viewport.origin.x, y: board.viewport.origin.y, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.46, alpha: 1).setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -board.viewport.origin.x, y: -board.viewport.origin.y)
        let viewport = visible
        for (index, layer) in board.layers.enumerated() {
            guard let rect = geometry.layerRects[layer.id], rect.intersects(viewport) else { continue }
            NSColor(calibratedWhite: index % 2 == 0 ? 0.49 : 0.46, alpha: 1).setFill()
            NSRect(x: viewport.x, y: rect.y, width: viewport.width, height: rect.height).fill()
            label("\(layer.collapsed ? "▸" : "▾") \(layer.name)\(layer.locked ? "  🔒" : "")", at: NSRect(x: max(5, viewport.x + 5), y: rect.y + 9, width: 145, height: 18), size: 10, color: .white)
        }
        for marker in workspace?.project.storyMilestones ?? [] {
            let x = 110 + marker.x
            guard x >= viewport.x - 200, x <= viewport.maxX else { continue }
            NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: viewport.y)); line.line(to: NSPoint(x: x, y: viewport.maxY))
            line.lineWidth = 1 / zoom; line.setLineDash([3, 5], count: 2, phase: 0); line.stroke()
            let tag = NSRect(x: x, y: viewport.maxY - 19 / zoom, width: 190, height: 18 / zoom)
            NSColor.systemBlue.withAlphaComponent(0.8).setFill(); tag.fill()
            label(marker.title, at: tag.insetBy(dx: 4, dy: 2), size: 10 / zoom, color: .white)
        }
        let byID = Dictionary(uniqueKeysWithValues: board.beats.map { ($0.id, $0) })
        let issueBeats = Set(board.issues.flatMap(\.beatIDs))
        for edge in board.dependencies {
            guard let a = geometry.beatRects[edge.cause], let b = geometry.beatRects[edge.effect] else { continue }
            let extent = BoardRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + max(a.width, b.width), height: abs(a.y - b.y) + max(a.height, b.height))
            guard extent.intersects(viewport) else { continue }
            let start = NSPoint(x: a.maxX, y: a.center.y), end = NSPoint(x: b.x, y: b.center.y)
            let path = NSBezierPath(); path.move(to: start)
            let bend = max(30, abs(end.x - start.x) * 0.45)
            path.curve(to: end, controlPoint1: NSPoint(x: start.x + bend, y: start.y), controlPoint2: NSPoint(x: end.x - bend, y: end.y))
            let invalid = !edge.reference && (byID[edge.effect]?.start ?? 0) < (byID[edge.cause]?.start ?? 0) + (byID[edge.cause]?.duration ?? 0)
            (invalid ? NSColor.systemRed : selection.contains(edge.cause) || selection.contains(edge.effect) ? NSColor.systemCyan : NSColor(calibratedWhite: 0.82, alpha: 0.65)).setStroke()
            path.lineWidth = 1.3 / max(0.6, zoom)
            if edge.reference { path.setLineDash([4, 4], count: 2, phase: 0) }
            path.stroke()
            let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: end.x - 6, y: end.y - 3)); arrow.line(to: end); arrow.line(to: NSPoint(x: end.x - 6, y: end.y + 3)); arrow.stroke()
        }
        let groups = Set(board.blocks.compactMap(\.parentID))
        let memberCounts = Dictionary(grouping: board.beats, by: \.blockID).mapValues(\.count)
        let sortedBlocks = board.blocks.sorted { a, b in
            if groups.contains(a.id) != groups.contains(b.id) { return groups.contains(a.id) }
            return a.id < b.id
        }
        for block in sortedBlocks {
            if block.standalone == true && (memberCounts[block.id] ?? 0) <= 1 && !groups.contains(block.id) { continue }
            guard var rect = geometry.blockRects[block.id], rect.intersects(viewport) else { continue }
            if resizingBlock == block.id { rect.width = resizeWidth }
            if movingBlocks && expandedDragBlocks.contains(block.id) { rect.x += dragDelta.x; rect.y += dragDelta.y }
            let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            NSColor(calibratedWhite: 0.9, alpha: groups.contains(block.id) ? 0.10 : block.containerKind == "beatGroup" ? 0.22 : 0.30).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
            (blockSelection.contains(block.id) ? NSColor.white : NSColor(calibratedWhite: 1, alpha: 0.15)).setStroke()
            NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).stroke()
            NSColor(calibratedWhite: 0.33, alpha: 0.9).setFill()
            let tab = NSRect(x: rect.x + 12, y: rect.y - 17, width: min(rect.width - 24, max(90, Double(block.name.count) * 6)), height: 20)
            NSBezierPath(roundedRect: tab, xRadius: 3, yRadius: 3).fill()
            label("\(block.collapsed ? "▸ " : "")\(block.name)", at: tab.insetBy(dx: 6, dy: 3), size: 10, color: .white)
        }
        for id in geometry.beats(in: viewport) {
            guard let beat = byID[id], var rect = geometry.beatRects[id] else { continue }
            if resizingBlock == beat.blockID { rect.width = resizeWidth - 12 }
            if movingBlocks && expandedDragBlocks.contains(beat.blockID) { rect.x += dragDelta.x; rect.y += dragDelta.y }
            if movingBeat != nil && selection.contains(id) { rect.x += dragDelta.x; rect.y += dragDelta.y }
            let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            let color = NSColor(boardHex: beat.color)
            (beat.omitted ? NSColor.gray : board.isUnused(beat) ? color.withAlphaComponent(0.25) : color).setFill()
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4); path.fill()
            (selection.contains(id) ? NSColor.white : NSColor(calibratedWhite: 1, alpha: 0.3)).setStroke()
            path.lineWidth = selection.contains(id) ? 2 / zoom : 1; path.stroke()
            (beat.title as NSString).draw(with: frame.insetBy(dx: 7, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: WhiteboardBeatText.attributes, context: nil)
            if issueBeats.contains(id) {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: frame.maxX - 11, y: frame.minY - 7, width: 16, height: 16)).fill()
                label("!", at: NSRect(x: frame.maxX - 6, y: frame.minY - 6, width: 10, height: 14), size: 11, color: .white)
            }
        }
        for item in board.strokes { drawStroke(item.points, color: NSColor(boardHex: item.color), width: item.width) }
        if !stroke.isEmpty { drawStroke(stroke, color: .systemYellow, width: 2) }
        if isErasing && !eraserStroke.isEmpty { drawEraserStroke(eraserStroke) }
        if let marquee {
            NSColor.systemCyan.withAlphaComponent(0.12).setFill()
            let frame = NSRect(x: marquee.x, y: marquee.y, width: marquee.width, height: marquee.height)
            frame.fill(); NSColor.systemCyan.setStroke(); NSBezierPath(rect: frame).stroke()
        }
        context.restoreGState()
    }

    private func label(_ string: String, at rect: NSRect, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func drawStroke(_ points: [BoardPoint], color: NSColor, width: Double) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: NSPoint(x: first.x, y: first.y))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.x, y: point.y)) }
        path.lineWidth = width; path.lineCapStyle = .round; color.setStroke(); path.stroke()
    }
    private func drawEraserStroke(_ points: [BoardPoint]) {
        guard let first = points.first else { return }
        let eraserRadius = max(10.0, 16.0 / zoom)
        if points.count > 1 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: first.x, y: first.y))
            for pt in points.dropFirst() { path.line(to: NSPoint(x: pt.x, y: pt.y)) }
            path.lineWidth = eraserRadius
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.systemRed.withAlphaComponent(0.3).setStroke()
            path.stroke()

            let innerPath = NSBezierPath()
            innerPath.move(to: NSPoint(x: first.x, y: first.y))
            for pt in points.dropFirst() { innerPath.line(to: NSPoint(x: pt.x, y: pt.y)) }
            innerPath.lineWidth = 1.5 / zoom
            innerPath.setLineDash([4 / zoom, 4 / zoom], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            innerPath.stroke()
        }
        if let last = points.last {
            let tipRect = NSRect(x: last.x - eraserRadius / 2, y: last.y - eraserRadius / 2, width: eraserRadius, height: eraserRadius)
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: tipRect).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let tipOutline = NSBezierPath(ovalIn: tipRect)
            tipOutline.lineWidth = 1.5 / zoom
            tipOutline.stroke()
        }
    }

    private func eraseStrokesNear(point: BoardPoint) {
        let threshold = max(16.0 / zoom, 12.0)
        var toRemove = [String]()
        for stroke in board.strokes {
            if hitTestStroke(stroke, from: point, to: point, threshold: threshold) {
                toRemove.append(stroke.id)
            }
        }
        guard !toRemove.isEmpty else { return }
        for id in toRemove { erasedStrokeIDs.insert(id) }
        board.strokes.removeAll { erasedStrokeIDs.contains($0.id) }
    }

    private func eraseStrokesIntersecting(from p1: BoardPoint, to p2: BoardPoint) {
        let threshold = max(16.0 / zoom, 12.0)
        var toRemove = [String]()
        for stroke in board.strokes {
            if hitTestStroke(stroke, from: p1, to: p2, threshold: threshold) {
                toRemove.append(stroke.id)
            }
        }
        guard !toRemove.isEmpty else { return }
        for id in toRemove { erasedStrokeIDs.insert(id) }
        board.strokes.removeAll { erasedStrokeIDs.contains($0.id) }
    }

    private func strokeAt(_ point: BoardPoint) -> BoardStroke? {
        let threshold = max(16.0 / zoom, 12.0)
        for stroke in board.strokes.reversed() {
            if hitTestStroke(stroke, from: point, to: point, threshold: threshold) {
                return stroke
            }
        }
        return nil
    }

    private func hitTestStroke(_ stroke: BoardStroke, from p1: BoardPoint, to p2: BoardPoint, threshold: Double) -> Bool {
        guard !stroke.points.isEmpty else { return false }
        let strokeThreshold = max(threshold, stroke.width / 2 + threshold)
        let threshSq = strokeThreshold * strokeThreshold

        var minX = stroke.points[0].x, maxX = stroke.points[0].x
        var minY = stroke.points[0].y, maxY = stroke.points[0].y
        for pt in stroke.points {
            if pt.x < minX { minX = pt.x }
            if pt.x > maxX { maxX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.y > maxY { maxY = pt.y }
        }
        let eMinX = min(p1.x, p2.x) - strokeThreshold
        let eMaxX = max(p1.x, p2.x) + strokeThreshold
        let eMinY = min(p1.y, p2.y) - strokeThreshold
        let eMaxY = max(p1.y, p2.y) + strokeThreshold

        if maxX < eMinX || minX > eMaxX || maxY < eMinY || minY > eMaxY {
            return false
        }

        if stroke.points.count == 1 {
            let pt = stroke.points[0]
            return distanceSqToSegment(pt, p1, p2) <= threshSq
        }

        for i in 0..<(stroke.points.count - 1) {
            let a = stroke.points[i]
            let b = stroke.points[i + 1]

            if segmentsIntersect(p1, p2, a, b) {
                return true
            }
            if distanceSqToSegment(p1, a, b) <= threshSq || distanceSqToSegment(p2, a, b) <= threshSq {
                return true
            }
            if distanceSqToSegment(a, p1, p2) <= threshSq || distanceSqToSegment(b, p1, p2) <= threshSq {
                return true
            }
        }
        return false
    }

    private func distanceSqToSegment(_ p: BoardPoint, _ a: BoardPoint, _ b: BoardPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-9 {
            let px = p.x - a.x, py = p.y - a.y
            return px * px + py * py
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        let distDx = p.x - projX, distDy = p.y - projY
        return distDx * distDx + distDy * distDy
    }

    private func segmentsIntersect(_ a: BoardPoint, _ b: BoardPoint, _ c: BoardPoint, _ d: BoardPoint) -> Bool {
        func ccw(_ p1: BoardPoint, _ p2: BoardPoint, _ p3: BoardPoint) -> Double {
            (p3.y - p1.y) * (p2.x - p1.x) - (p2.y - p1.y) * (p3.x - p1.x)
        }
        func onSegment(_ p: BoardPoint, _ s1: BoardPoint, _ s2: BoardPoint) -> Bool {
            p.x >= min(s1.x, s2.x) - 1e-5 && p.x <= max(s1.x, s2.x) + 1e-5 &&
            p.y >= min(s1.y, s2.y) - 1e-5 && p.y <= max(s1.y, s2.y) + 1e-5
        }

        if max(a.x, b.x) < min(c.x, d.x) || min(a.x, b.x) > max(c.x, d.x) ||
           max(a.y, b.y) < min(c.y, d.y) || min(a.y, b.y) > max(c.y, d.y) {
            return false
        }
        let d1 = ccw(a, b, c)
        let d2 = ccw(a, b, d)
        let d3 = ccw(c, d, a)
        let d4 = ccw(c, d, b)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        if abs(d1) < 1e-5 && onSegment(c, a, b) { return true }
        if abs(d2) < 1e-5 && onSegment(d, a, b) { return true }
        if abs(d3) < 1e-5 && onSegment(a, c, d) { return true }
        if abs(d4) < 1e-5 && onSegment(b, c, d) { return true }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil), worldPoint = world(point)
        viewStart = point; dragStart = worldPoint; dragDelta = .init()
        if event.modifierFlags.contains(.option) && (drawingMode || strokeAt(worldPoint) != nil) {
            isErasing = true
            eraserStroke = [worldPoint]
            erasedStrokeIDs.removeAll()
            eraseStrokesNear(point: worldPoint)
            NSCursor.disappearingItem.set()
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.option), let beat = geometry.hitBeat(worldPoint) { dependencyOrigin = beat; return }
        if pushingMode || event.modifierFlags.contains(.command) { pushOrigin = worldPoint; return }
        if spaceHeld || event.modifierFlags.contains(.option) { panStart = board.viewport.origin; return }
        if drawingMode { stroke = [worldPoint]; return }
        if event.clickCount == 2, geometry.hitBeat(worldPoint) == nil {
            let layer = layerAt(worldPoint)
            let parent = hitBlock(worldPoint).flatMap { id in board.blocks.first { $0.id == id && $0.standalone != true }?.id }
            beginInlineBeat(layerID: layer.id, position: .init(x: max(0, worldPoint.x - 110), y: max(32, worldPoint.y - (geometry.layerRects[layer.id]?.y ?? 0))), parentID: parent)
            return
        }
        if let id = hitBlock(worldPoint), let rect = geometry.blockRects[id],
           abs(worldPoint.x - rect.maxX) <= 7 / zoom, worldPoint.y >= rect.y, !board.isBlockLocked(id) {
            resizingBlock = id; resizeWidth = board.blocks.first { $0.id == id }?.width ?? rect.width
            blockSelection = [id]; selection = Set(board.beats.filter { $0.blockID == id }.map(\.id))
            selected?(selection, blockSelection); needsDisplay = true; return
        }
        if worldPoint.x - board.viewport.origin.x < 110,
           let layer = board.layers.first(where: { layer in
               guard let rect = geometry.layerRects[layer.id] else { return false }
               return worldPoint.y >= rect.y && worldPoint.y < rect.y + 32
           }) {
            workspace?.edit("Layer Display") { try $0.editWhiteboard { board in
                if let i = board.layers.firstIndex(where: { $0.id == layer.id }) { board.layers[i].collapsed.toggle() }
            } }; return
        }
        if let beat = geometry.hitBeat(worldPoint) {
            if let cause = workspace?.pendingBoardCauseID {
                workspace?.edit("Create Dependency") { try $0.connectBoardBeats(cause: cause, effect: beat) }
                workspace?.pendingBoardCauseID = nil; return
            }
            if event.modifierFlags.contains(.shift) { if !selection.insert(beat).inserted { selection.remove(beat) } }
            else if !selection.contains(beat) { selection = [beat] }
            blockSelection = []; movingBeat = beat
            workspace?.selectBoardBeat(beat)
            selected?(selection, blockSelection)
            if event.clickCount == 2 { openPopup(beat); movingBeat = nil }
        } else if let block = hitBlock(worldPoint) {
            if event.modifierFlags.contains(.shift) { if !blockSelection.insert(block).inserted { blockSelection.remove(block) } }
            else if !blockSelection.contains(block) { blockSelection = [block] }
            expandedDragBlocks = blockSelection
            var changed = true
            while changed {
                let old = expandedDragBlocks
                expandedDragBlocks.formUnion(board.blocks.filter { $0.parentID.map(expandedDragBlocks.contains) == true }.map(\.id))
                changed = old != expandedDragBlocks
            }
            selection = Set(board.beats.filter { expandedDragBlocks.contains($0.blockID) }.map(\.id))
            movingBlocks = true; selected?(selection, blockSelection)
            if let id = selection.sorted().first { workspace?.selectBoardBeat(id) }
        } else {
            selection = []; blockSelection = []; selected?([], [])
            if event.clickCount == 2 {
                let layer = layerAt(worldPoint)
                workspace?.addWhiteboardBeat(layerID: layer.id, position: BoardPoint(x: max(0, worldPoint.x - 110), y: max(35, worldPoint.y - (geometry.layerRects[layer.id]?.y ?? 0))))
            } else { marquee = BoardRect(x: worldPoint.x, y: worldPoint.y, width: 0, height: 0) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isErasing {
            let point = convert(event.locationInWindow, from: nil), current = world(point)
            if let previous = eraserStroke.last {
                eraseStrokesIntersecting(from: previous, to: current)
            }
            if eraserStroke.count < 10000 {
                eraserStroke.append(current)
            }
            needsDisplay = true
            return
        }
        if dependencyOrigin != nil { return }
        if pushOrigin != nil { NSCursor.resizeLeftRight.set(); return }
        let point = convert(event.locationInWindow, from: nil), current = world(point)
        if let panStart {
            board.viewport.origin = BoardPoint(x: panStart.x - (point.x - viewStart.x) / zoom, y: panStart.y - (point.y - viewStart.y) / zoom)
        } else if drawingMode && !stroke.isEmpty {
            if stroke.count < 10000 { stroke.append(current) }
        } else if let id = resizingBlock, let start = dragStart, let original = board.blocks.first(where: { $0.id == id }) {
            resizeWidth = max(140, min(2000, original.width + current.x - start.x))
        } else if let start = dragStart {
            dragDelta = BoardPoint(x: current.x - start.x, y: current.y - start.y)
            if marquee != nil {
                marquee = BoardRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
                selection = geometry.beats(in: marquee!); selected?(selection, [])
            }
        }
        needsDisplay = true
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        viewStart = point
        panStart = board.viewport.origin
    }
    override func otherMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let panStart {
            board.viewport.origin = BoardPoint(x: panStart.x - (point.x - viewStart.x) / zoom, y: panStart.y - (point.y - viewStart.y) / zoom)
            needsDisplay = true
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        if panStart != nil {
            panStart = nil
            persistViewport()
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isErasing {
            isErasing = false
            eraserStroke = []
            let removedIDs = erasedStrokeIDs
            erasedStrokeIDs.removeAll()
            if drawingMode {
                if NSEvent.modifierFlags.contains(.option) {
                    NSCursor.disappearingItem.set()
                } else {
                    NSCursor.crosshair.set()
                }
            } else {
                NSCursor.arrow.set()
            }
            if !removedIDs.isEmpty {
                workspace?.edit("Erase Annotation") { project in
                    try project.editWhiteboard { board in
                        board.strokes.removeAll { removedIDs.contains($0.id) }
                    }
                }
            }
            dragStart = nil
            needsDisplay = true
            return
        }
        if let cause = dependencyOrigin {
            dependencyOrigin = nil; dragStart = nil
            if let effect = geometry.hitBeat(world(convert(event.locationInWindow, from: nil))), effect != cause { workspace?.edit("Create Dependency") { try $0.connectBoardBeats(cause: cause, effect: effect) } }
            return
        }
        if let origin = pushOrigin {
            pushOrigin = nil; NSCursor.arrow.set()
            let delta = world(convert(event.locationInWindow, from: nil)).x - origin.x
            workspace?.edit("Push Whiteboard") { try $0.pushWhiteboard(from: origin.x - 110, by: delta); try $0.applyWhiteboardSpatialOrder() }
            dragStart = nil; return
        }
        defer { dragStart = nil; panStart = nil; movingBlocks = false; movingBeat = nil; resizingBlock = nil; marquee = nil; dragDelta = .init(); stroke = []; needsDisplay = true }
        if panStart != nil { persistViewport(); return }
        if let id = resizingBlock {
            let width = resizeWidth
            workspace?.edit("Resize Block") { try $0.resizeBoardBlock(id, width: width) }; return
        }
        if stroke.count > 1 {
            let points = stroke
            workspace?.edit("Draw Annotation") { try $0.editWhiteboard { $0.strokes.append(BoardStroke(points: points)) } }; return
        }
        guard abs(dragDelta.x) + abs(dragDelta.y) > 3 else { return }
        if movingBlocks {
            var delta = dragDelta
            let ids = blockSelection, target = layerAt(world(convert(event.locationInWindow, from: nil)))
            let sourceLayer = board.blocks.first { ids.contains($0.id) }?.layerID
            if let sourceLayer, sourceLayer != target.id {
                delta.y += (geometry.layerRects[sourceLayer]?.y ?? 0) - (geometry.layerRects[target.id]?.y ?? 0)
            }
            let ripple = workspace?.whiteboardRipple ?? true
            let point = world(convert(event.locationInWindow, from: nil))
            var container: BoardBlock?
            var smallestArea = Double.infinity
            for block in board.blocks {
                guard !expandedDragBlocks.contains(block.id), !ids.contains(block.id),
                      block.standalone != true, block.containerKind != "beatGroup",
                      let rect = geometry.blockRects[block.id], rect.contains(point) else { continue }
                let area = rect.width * rect.height
                if area < smallestArea { container = block; smallestArea = area }
            }
            workspace?.edit("Move Groups or Blocks") {
                if let container, ids.allSatisfy({ id in board.blocks.first { $0.id == id }?.containerKind == "beatGroup" }) {
                    try $0.nestBoardGroups(ids, inBlock: container.id, delta: delta)
                } else { try $0.moveBoardBlocks(ids, delta: delta, layerID: sourceLayer == target.id ? nil : target.id, ripple: ripple) }
                try $0.applyWhiteboardSpatialOrder()
            }
        } else if let beat = movingBeat {
            let point = world(convert(event.locationInWindow, from: nil))
            let destination = hitBlock(point)
            if let owner = board.beats.first(where: { $0.id == beat })?.blockID,
               let block = board.blocks.first(where: { $0.id == owner }), block.standalone == true,
               destination == nil || destination == owner {
                let target = layerAt(point)
                var delta = dragDelta
                delta.y += (geometry.layerRects[block.layerID]?.y ?? 0) - (geometry.layerRects[target.id]?.y ?? 0)
                let ripple = workspace?.whiteboardRipple ?? true
                let ids = selection.contains(beat) ? selection : [beat]
                workspace?.edit("Move Standalone Beats") { try $0.moveStandaloneBeats(ids, delta: delta, layerID: target.id, ripple: ripple); try $0.applyWhiteboardSpatialOrder() }
            } else if let block = destination {
                let before = geometry.hitBeat(point)
                let moving = selection.contains(beat) ? selection : [beat]
                if let before, moving.contains(before) { return }
                workspace?.edit("Move Beats") {
                    if before == nil, let rect = geometry.blockRects[block] { try $0.placeBoardBeats(moving, inBlock: block, position: .init(x: point.x - rect.x, y: point.y - rect.y)) }
                    else if let before { try $0.dropBoardBeats(moving, onto: before) }
                    try $0.applyWhiteboardSpatialOrder()
                }
            } else {
                let target = layerAt(point), moving = selection.contains(beat) ? selection : [beat]
                let position = BoardPoint(x: point.x - 110, y: point.y - (geometry.layerRects[target.id]?.y ?? 0))
                workspace?.edit("Move Beats to Lane") {
                    try $0.moveBoardBeatsToLayer(moving, layerID: target.id, position: position)
                    try $0.applyWhiteboardSpatialOrder()
                }
            }
        }
    }

    private func hitBlock(_ point: BoardPoint) -> String? {
        geometry.blockRects.filter { entry in
            if board.blocks.first(where: { $0.id == entry.key })?.standalone == true {
                return board.beats.contains { $0.blockID == entry.key && geometry.beatRects[$0.id]?.contains(point) == true }
            }
            return entry.value.contains(point) || BoardRect(x: entry.value.x, y: entry.value.y - 18, width: entry.value.width, height: 20).contains(point)
        }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
    }
    private func layerAt(_ point: BoardPoint) -> BoardLayer {
        board.layers.first { geometry.layerRects[$0.id]?.contains(point) == true } ?? board.layers[0]
    }
    private func openPopup(_ id: String) {
        guard let workspace else { return }
        workspace.selectBoardBeat(id)
        workspace.popup.open(id, workspace: workspace, near: geometry.beatRects[id].flatMap(screenRect))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { zoomAt(convert(event.locationInWindow, from: nil), factor: exp(event.scrollingDeltaY * 0.015)) }
        else {
            board.viewport.origin.x -= event.scrollingDeltaX / zoom
            board.viewport.origin.y -= event.scrollingDeltaY / zoom
            persistViewport()
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) { zoomAt(convert(event.locationInWindow, from: nil), factor: 1 + event.magnification) }
    private func zoomAt(_ point: NSPoint, factor: Double) {
        let anchor = world(point)
        board.viewport.zoom = max(0.15, min(3, zoom * factor))
        board.viewport.origin = BoardPoint(x: anchor.x - point.x / zoom, y: anchor.y - point.y / zoom)
        persistViewport(); needsDisplay = true
    }
    private func persistViewport() {
        var value = board.viewport
        value.origin.x = max(-1_000_000, min(1_000_000, value.origin.x)); value.origin.y = max(-1_000_000, min(1_000_000, value.origin.y))
        workspace?.edit("Whiteboard View", key: "whiteboard-viewport") { try $0.editWhiteboard { $0.viewport = value } }
    }
    func fitSelection() {
        let frames = selection.compactMap { geometry.beatRects[$0] }
        let items = frames.isEmpty ? (Array(geometry.beatRects.values) + Array(geometry.blockRects.values)) : frames
        guard let x = items.map(\.x).min(), let y = items.map(\.y).min(), let right = items.map(\.maxX).max(), let bottom = items.map(\.maxY).max() else { return }
        board.viewport.zoom = max(0.15, min(1.5, min((bounds.width - 60) / (right - x + 100), (bounds.height - 60) / (bottom - y + 100))))
        board.viewport.origin = BoardPoint(x: x - 40, y: y - 40); persistViewport()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let id = selection.first {
            if event.charactersIgnoringModifiers == "i" { workspace?.pendingBoardCauseID = id; return }
            if event.charactersIgnoringModifiers == "o", let cause = workspace?.pendingBoardCauseID { workspace?.edit("Create Dependency") { try $0.connectBoardBeats(cause: cause, effect: id) }; workspace?.pendingBoardCauseID = nil; return }
        }
        if event.keyCode == 49 { spaceHeld = true; return }
        if event.keyCode == 36 {
            if let beat = board.orderedBeats.first(where: { selection.contains($0.id) }), let owner = board.blocks.first(where: { $0.id == beat.blockID }) {
                let loose = owner.standalone == true
                workspace?.addWhiteboardBeat(blockID: loose ? nil : owner.id, layerID: owner.layerID,
                    position: BoardPoint(x: owner.position.x, y: owner.position.y + (geometry.beatRects[beat.id]?.height ?? 24) + 12),
                    sceneID: beat.sceneID, after: beat.id)
            } else { workspace?.addWhiteboardBeat() }
            return
        }
        if event.keyCode == 53 {
            workspace?.pendingBoardCauseID = nil
            dragStart = nil; panStart = nil; movingBlocks = false; movingBeat = nil; resizingBlock = nil
            marquee = nil; dragDelta = .init(); stroke = []; spaceHeld = false
            selection = []; blockSelection = []; selected?([], []); needsDisplay = true; return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            let ids = selection
            if !blockSelection.isEmpty {
                let blocks = blockSelection
                workspace?.edit("Pull Out Container Contents") { try $0.pullOutContainerContents(blocks) }
            } else { workspace?.edit("Pull Out Beats") { try $0.pullOutBeats(ids) } }
            selected?([], []); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selection = Set(board.beats.map(\.id)); selected?(selection, []); needsDisplay = true; return
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let visibleBeats = board.orderedBeats.filter { geometry.beatRects[$0.id] != nil }
            var next = visibleBeats.first?.id
            if let id = selection.sorted().first, let current = geometry.beatRects[id]?.center {
                let candidates = visibleBeats.compactMap { beat -> (String, Double)? in
                    guard beat.id != id, let p = geometry.beatRects[beat.id]?.center else { return nil }
                    let dx = p.x - current.x, dy = p.y - current.y
                    let primary = event.keyCode == 123 ? -dx : event.keyCode == 124 ? dx : event.keyCode == 125 ? dy : -dy
                    guard primary > 1 else { return nil }
                    return (beat.id, primary + 2 * abs(event.keyCode == 123 || event.keyCode == 124 ? dy : dx))
                }
                next = candidates.min { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }?.0 ?? id
            }
            if let next, let rect = geometry.beatRects[next] {
                selection = [next]; blockSelection = []; selected?(selection, []); workspace?.selectBoardBeat(next)
                let viewport = visible
                if rect.x < viewport.x || rect.maxX > viewport.maxX { board.viewport.origin.x = rect.x - 30 }
                if rect.y < viewport.y || rect.maxY > viewport.maxY { board.viewport.origin.y = rect.y - 30 }
                persistViewport(); needsDisplay = true
            }
            return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) } }

    override func resetCursorRects() {
        super.resetCursorRects()
        if drawingMode {
            let cursor: NSCursor = NSEvent.modifierFlags.contains(.option) ? .disappearingItem : .crosshair
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        window?.invalidateCursorRects(for: self)
        if drawingMode {
            if event.modifierFlags.contains(.option) {
                NSCursor.disappearingItem.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        contextPoint = world(convert(event.locationInWindow, from: nil))
        contextBeat = geometry.hitBeat(contextPoint); contextBlock = hitBlock(contextPoint)
        let menu = NSMenu()
        func item(_ name: String, _ action: Selector) { let item = NSMenuItem(title: name, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        if contextBeat != nil {
            item("Group Selected Beats", #selector(groupBeatContext)); item("Edit Beat…", #selector(editContextBeat)); item("Jump To Snippet", #selector(jumpToSnippet)); item("Show In Research", #selector(showResearch))
            menu.addItem(.separator()); item("Create Cause", #selector(createCause)); item("Create Dependency From", #selector(startDependency))
            item("Must Be Caused", #selector(toggleRequired)); item("Split Beat at Cursor…", #selector(splitContext))
            item("Insert Beat Before", #selector(insertBeforeContext)); item("Insert Beat After", #selector(insertAfterContext))
            item("Characters & Tags…", #selector(editContextBeat)); menu.addItem(.separator())
            item("Split Group Here", #selector(splitGroupContext))
            item("Omit / Include Beat", #selector(toggleOmitted)); item("Pull Out Beat", #selector(deleteContext))
        } else if contextBlock != nil {
            item("Add Beat", #selector(insertContext)); item("Collapse / Expand Block", #selector(collapseContext))
            item("Container Synopsis…", #selector(synopsisContext))
            item("Split Block Here", #selector(splitBlockContext))
            item("Lock / Unlock Block", #selector(lockContext))
            if board.blocks.contains(where: { $0.parentID == contextBlock || ($0.id == contextBlock && $0.containerKind == "beatGroup") }) { item("Ungroup", #selector(ungroupContext)) }
            item("Pull Out Container Contents", #selector(deleteBlockContext))
        } else { item("Add Beat Here", #selector(insertContext)) }
        menu.addItem(.separator())
        item(board.usesBlocks(layerAt(contextPoint).id) ? "Disable Use Blocks" : "Enable Use Blocks", #selector(toggleLayerBlocks))
        if blockSelection.count > 1 { item("Group Selected Blocks", #selector(groupContext)); item("Merge Groups / Blocks", #selector(mergeContext)) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func splitBlockContext() { if let id = contextBlock { workspace?.edit("Split Block") { try $0.splitBoardBlock(id, at: contextPoint.x - 110) } } }
    @objc private func synopsisContext() {
        guard let id = contextBlock, let block = board.blocks.first(where: { $0.id == id }), !board.isBlockLocked(id) else { return }
        let alert = NSAlert(); alert.messageText = "Container Synopsis"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: block.synopsis ?? ""); field.frame = NSRect(x: 0, y: 0, width: 360, height: 80); alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { workspace?.edit("Container Synopsis") { try $0.editWhiteboard { board in if let i = board.blocks.firstIndex(where: { $0.id == id }) { board.blocks[i].synopsis = field.stringValue } } } }
    }
    @objc private func splitGroupContext() { if let id = contextBeat { workspace?.edit("Split Group") { try $0.splitBoardGroup(at: id) } } }
    @objc private func mergeContext() { workspace?.edit("Merge Containers") { try $0.mergeBoardContainers(blockSelection) } }
    @objc private func toggleLayerBlocks() {
        let layer = layerAt(contextPoint), enabled = !board.usesBlocks(layer.id)
        workspace?.edit("Layer Block Policy") { try $0.setLayerUsesBlocks(layer.id, enabled: enabled) }
    }
    @objc private func editContextBeat() { if let id = contextBeat { openPopup(id) } }
    @objc private func jumpToSnippet() { if let id = contextBeat { workspace?.selectBoardBeat(id); workspace?.showBoardScript = true } }
    @objc private func showResearch() { if let id = contextBeat { workspace?.openBoardResearch(id) } }
    @objc private func startDependency() { workspace?.pendingBoardCauseID = contextBeat }
    @objc private func toggleRequired() { if let id = contextBeat { workspace?.edit("Cause Requirement") { try $0.updateBoardBeat(id) { $0.mustBeCaused.toggle() } } } }
    @objc private func splitContext() { editContextBeat() }
    @objc private func createCause() {
        guard let effect = contextBeat, let owner = board.beats.first(where: { $0.id == effect }) else { return }
        var cause: String?
        workspace?.edit("Create Cause") { project in
            cause = try project.addBoardBeat(blockID: owner.blockID, title: "Cause of \(owner.title)")
            try project.connectBoardBeats(cause: cause!, effect: effect)
            try project.updateBoardBeat(cause!) { $0.order = owner.order - 0.5; $0.start = max(0, owner.start - $0.duration) }
            try project.editWhiteboard { try $0.resolveCauses() }
        }
        if let cause { openPopup(cause) }
    }
    @objc private func insertContext() {
        let layer = layerAt(contextPoint)
        workspace?.addWhiteboardBeat(blockID: contextBlock, layerID: layer.id, position: BoardPoint(x: max(0, contextPoint.x - 110), y: max(35, contextPoint.y - (geometry.layerRects[layer.id]?.y ?? 0))))
    }
    @objc private func insertBeforeContext() { insertRelative(after: false) }
    @objc private func insertAfterContext() { insertRelative(after: true) }
    private func insertRelative(after: Bool) {
        guard let id = contextBeat, let beat = board.beats.first(where: { $0.id == id }) else { return }
        let items = board.orderedBeats.filter { $0.blockID == beat.blockID }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let before = after ? (index + 1 < items.count ? items[index + 1].id : nil) : id
        let layer = board.blocks.first { $0.id == beat.blockID }?.layerID ?? "main"
        workspace?.addWhiteboardBeat(blockID: beat.blockID, layerID: layer, before: before)
    }
    @objc private func toggleOmitted() { if let id = contextBeat { workspace?.edit("Beat Inclusion") { try $0.updateBoardBeat(id) { $0.omitted.toggle() } } } }
    @objc private func deleteContext() { if let id = contextBeat { workspace?.edit("Pull Out Beat") { try $0.pullOutBeats([id]) } } }
    @objc private func collapseContext() { if let id = contextBlock { workspace?.edit("Block Display") { try $0.editWhiteboard { board in if let i = board.blocks.firstIndex(where: { $0.id == id }) { board.blocks[i].collapsed.toggle() } } } } }
    @objc private func lockContext() { if let id = contextBlock { workspace?.edit("Block Lock") { try $0.editWhiteboard { board in if let i = board.blocks.firstIndex(where: { $0.id == id }) { board.blocks[i].locked.toggle() } } } } }
    @objc private func groupBeatContext() { workspace?.edit("Group Beats") { try $0.groupBoardBeats(selection.isEmpty ? Set([contextBeat].compactMap { $0 }) : selection) } }
    @objc private func groupContext() { let ids = blockSelection; workspace?.edit("Group Blocks") { try $0.groupBoardBlocks(ids, name: "New Group") } }
    @objc private func ungroupContext() { if let id = contextBlock { workspace?.edit("Ungroup Blocks") { try $0.ungroupBoardBlocks([id]) } } }
    @objc private func deleteBlockContext() { if let id = contextBlock { workspace?.edit("Pull Out Container Contents") { try $0.pullOutContainerContents([id]) } } }
}

extension NSColor {
    convenience init(boardHex value: String) {
        let rgb = UInt32(value.hasPrefix("#") ? String(value.dropFirst()) : value, radix: 16) ?? 0xa34eae
        self.init(calibratedRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
}
#endif
