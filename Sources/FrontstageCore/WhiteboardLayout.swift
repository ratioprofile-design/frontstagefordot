import Foundation

public struct BoardRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: BoardPoint { BoardPoint(x: x + width / 2, y: y + height / 2) }
    public func contains(_ p: BoardPoint) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }
    public func intersects(_ r: BoardRect) -> Bool { maxX >= r.x && x <= r.maxX && maxY >= r.y && y <= r.maxY }
}

/// One geometry source drives drawing, hit-testing, marquee selection and viewport culling.
public struct WhiteboardLayout: Sendable {
    public let layerRects: [String: BoardRect]
    public let blockRects: [String: BoardRect]
    public let beatRects: [String: BoardRect]
    public let width: Double
    public let height: Double
    private let cells: [String: Set<String>]
    private let largeItems: Set<String>
    private static let cellSize = 320.0

    /// Compact monospace cards grow with their title; long titles wrap at the container width.
    public static func beatSize(_ text: String, maximumWidth: Double) -> (width: Double, height: Double) {
        let limit = max(1, Int((maximumWidth - 18) / 6.7))
        let lines = text.components(separatedBy: "\n").map { max(1, $0.count) }
        let columns = min(limit, lines.max() ?? 1)
        let rows = lines.reduce(0) { $0 + Int(ceil(Double($1) / Double(limit))) }
        return (max(32, Double(columns) * 6.7 + 18), max(26, Double(rows) * 14 + 12))
    }

    public init(_ board: Whiteboard, measureBeat: (String, Double) -> (width: Double, height: Double) = { Self.beatSize($0, maximumWidth: $1) }) {
        var measured = [String: [Double: (width: Double, height: Double)]]()
        func size(_ title: String, maximumWidth: Double) -> (width: Double, height: Double) {
            if let cached = measured[title]?[maximumWidth] { return cached }
            let result = measureBeat(title, maximumWidth)
            measured[title, default: [:]][maximumWidth] = result
            return result
        }
        var layers = [String: BoardRect](), blocks = [String: BoardRect](), beats = [String: BoardRect]()
        let blockByID = Dictionary(uniqueKeysWithValues: board.blocks.map { ($0.id, $0) })
        let byBlock = Dictionary(grouping: board.orderedBeats, by: \.blockID)
        var offset = 0.0, maximumX = 1400.0
        func hidden(_ block: BoardBlock) -> Bool {
            var parent = block.parentID, seen = Set<String>()
            while let id = parent, seen.insert(id).inserted, let item = blockByID[id] {
                if item.collapsed { return true }; parent = item.parentID
            }
            return false
        }
        for layer in board.layers {
            let items = board.blocks.filter { $0.layerID == layer.id && !hidden($0) }
            let contentHeight = items.map { block in
                let members = byBlock[block.id] ?? []
                let stacked = members.reduce(42.0) { $0 + size($1.title, maximumWidth: block.width - 12).height + 4 }
                let placed = members.map { ($0.position?.y ?? 24) + size($0.title, maximumWidth: block.width - 12).height + 12 }.max() ?? 0
                return block.position.y + (block.collapsed ? 32 : max(stacked, placed, layer.useBlocks == true && block.standalone != true && block.containerKind != "beatGroup" ? 180 : 60))
            }.max() ?? 0
            let layerHeight = layer.collapsed ? 38 : max(layer.height, contentHeight + 45)
            layers[layer.id] = BoardRect(x: 0, y: offset, width: 1_000_000, height: layerHeight)
            if !layer.collapsed {
                for block in items {
                    let members = byBlock[block.id] ?? []
                    let rect = BoardRect(x: 110 + block.position.x, y: offset + block.position.y,
                        width: max(block.width, members.map { ($0.position?.x ?? 6) + size($0.title, maximumWidth: block.width - 12).width + 12 }.max() ?? 0),
                        height: block.collapsed ? 28 : max(layer.useBlocks == true && block.standalone != true && block.containerKind != "beatGroup" ? 180 : 60, members.reduce(32.0) { $0 + size($1.title, maximumWidth: block.width - 12).height + 4 }, members.map { ($0.position?.y ?? 24) + size($0.title, maximumWidth: block.width - 12).height + 12 }.max() ?? 0))
                    blocks[block.id] = rect; maximumX = max(maximumX, rect.maxX + 120)
                    if !block.collapsed {
                        var top = rect.y + 24
                        for beat in members {
                            let size = size(beat.title, maximumWidth: block.width - 12)
                            beats[beat.id] = BoardRect(x: rect.x + (beat.position?.x ?? 6), y: beat.position.map { rect.y + $0.y } ?? top, width: size.width, height: size.height)
                            top += size.height + 4
                        }
                    }
                }
            }
            offset += layerHeight
        }
        // Fold visible descendants into parents once, from leaves upward, without a depth limit.
        var remaining = Dictionary(uniqueKeysWithValues: blocks.keys.map { ($0, 0) })
        for block in board.blocks where blocks[block.id] != nil {
            if let parent = block.parentID, blocks[parent] != nil { remaining[parent, default: 0] += 1 }
        }
        var ready = remaining.filter { $0.value == 0 }.map(\.key), cursor = 0
        while cursor < ready.count {
            let id = ready[cursor]; cursor += 1
            guard let parent = blockByID[id]?.parentID, let c = blocks[id], let r = blocks[parent], blockByID[parent]?.collapsed != true else { continue }
            blocks[parent] = BoardRect(x: min(r.x, c.x - 12), y: min(r.y, c.y - 28),
                width: max(r.maxX, c.maxX + 12) - min(r.x, c.x - 12), height: max(r.maxY, c.maxY + 12) - min(r.y, c.y - 28))
            remaining[parent, default: 0] -= 1
            if remaining[parent] == 0 { ready.append(parent) }
        }
        var index = [String: Set<String>](), big = Set<String>()
        for (id, rect) in beats {
            let left = Int(floor(rect.x / Self.cellSize)), right = Int(floor(rect.maxX / Self.cellSize))
            let top = Int(floor(rect.y / Self.cellSize)), bottom = Int(floor(rect.maxY / Self.cellSize))
            if (right - left + 1) * (bottom - top + 1) > 400 { big.insert(id); continue }
            for x in left...right { for y in top...bottom { index["\(x),\(y)", default: []].insert(id) } }
        }
        layerRects = layers; blockRects = blocks; beatRects = beats; width = max(2400, maximumX + 500); height = max(1200, offset + 500)
        cells = index; largeItems = big
    }

    public func beats(in rect: BoardRect) -> Set<String> {
        guard rect.width >= 0, rect.height >= 0, rect.x.isFinite, rect.y.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return [] }
        let left = Int(floor(rect.x / Self.cellSize)), right = Int(floor(rect.maxX / Self.cellSize))
        let top = Int(floor(rect.y / Self.cellSize)), bottom = Int(floor(rect.maxY / Self.cellSize))
        if (right - left + 1) * (bottom - top + 1) > 10000 { return Set(beatRects.filter { $0.value.intersects(rect) }.map(\.key)) }
        var result = largeItems
        for x in left...right { for y in top...bottom { result.formUnion(cells["\(x),\(y)"] ?? []) } }
        return result.filter { beatRects[$0]?.intersects(rect) == true }
    }

    public func hitBeat(_ point: BoardPoint) -> String? {
        beats(in: BoardRect(x: point.x, y: point.y, width: 0, height: 0)).sorted().last { beatRects[$0]?.contains(point) == true }
    }
}
