import Foundation

public struct PulledOutBeat: Identifiable, Equatable, Sendable {
    public let id: String
    public let sceneID: Decimal
    public let title: String
    public let html: String
    public let originalBlockID: String
    public let wasOmitted: Bool
}
extension Project {
    public var pulledOutBeats: [PulledOutBeat] {
        (state["frontstagePullouts"]?.array ?? []).compactMap { record in
            guard let beat = record.object?["beat"]?.object, let id = beat["id"]?.string, let sceneID = beat["sceneID"]?.decimal else { return nil }
            return PulledOutBeat(id: id, sceneID: sceneID, title: beat["title"]?.string ?? "Untitled Beat", html: beat["html"]?.string ?? "", originalBlockID: beat["blockID"]?.string ?? "", wasOmitted: beat["omitted"] == .bool(true))
        }
    }
    public mutating func setBeatOmitted(_ id: String, omitted: Bool) throws {
        let board = try whiteboard()
        guard let beat = board.beats.first(where: { $0.id == id }), !board.isLocked(beat), !scenes.contains(where: { $0.id == beat.sceneID && $0.isTextLocked }) else { throw ProjectError.invalidProject("Unlock the scene before changing inclusion") }
        try updateBoardBeat(id) { $0.omitted = omitted }
    }
    public mutating func pullOutScene(_ sceneID: Decimal) throws {
        try pullOutBeats(Set(whiteboard().beats.filter { $0.sceneID == sceneID }.map(\.id)))
    }
    public mutating func pullOutBeats(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        var candidate = self
        let board = try whiteboard(), selected = board.beats.filter { ids.contains($0.id) }
        guard selected.count == ids.count, !selected.contains(where: { board.isLocked($0) }) else { throw ProjectError.invalidProject("Select existing unlocked beats") }
        let sceneIDs = Set(selected.map(\.sceneID))
        guard !scenes.contains(where: { sceneIDs.contains($0.id) && $0.isTextLocked }) else { throw ProjectError.invalidProject("Unlock the scene before pulling it out") }
        guard state["frontstagePullouts"] == nil || state["frontstagePullouts"]?.array != nil else { throw ProjectError.invalidProject("Unsupported archive data is preserved") }
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(board))
        let raw = state["frontstageWhiteboard"]?.object ?? encoded.object ?? [:]
        let ordered = board.orderedBeats
        var archive = state["frontstagePullouts"]?.array ?? []
        for beat in selected {
            guard !archive.contains(where: { $0.object?["id"]?.string == beat.id }) else { throw ProjectError.invalidProject("This beat is already archived") }
            let index = ordered.firstIndex { $0.id == beat.id }!
            let rawBeat = raw["beats"]?.array?.first { $0.object?["id"]?.string == beat.id } ?? .null
            archive.append(.object(["id": .string(beat.id), "beat": rawBeat,
                "previousID": index > 0 ? .string(ordered[index - 1].id) : .null,
                "nextID": index + 1 < ordered.count ? .string(ordered[index + 1].id) : .null]))
        }
        var links = state["frontstageArchivedDependencies"]?.array ?? []
        for link in raw["dependencies"]?.array ?? [] {
            guard let fields = link.object, ids.contains(fields["cause"]?.string ?? "") || ids.contains(fields["effect"]?.string ?? "") else { continue }
            if !links.contains(where: { $0.object?["id"] == fields["id"] }) { links.append(link) }
        }
        candidate.state["frontstagePullouts"] = .array(archive)
        candidate.state["frontstageArchivedDependencies"] = .array(links)
        try candidate.editWhiteboard { board in
            board.beats.removeAll { ids.contains($0.id) }
            board.dependencies.removeAll { ids.contains($0.cause) || ids.contains($0.effect) }
        }
        for sceneID in sceneIDs where !board.beats.contains(where: { $0.sceneID == sceneID && !ids.contains($0.id) }) {
            try candidate.editBeat(sceneID) { $0["content"] = .string(""); $0["isDisabled"] = .bool(true) }
        }
        self = candidate
    }
    public mutating func restorePulledOutBeats(_ ids: Set<String>, into blockID: String? = nil) throws {
        var candidate = self, board = try whiteboard()
        var archive = state["frontstagePullouts"]?.array ?? []
        let selected = archive.filter { ids.contains($0.object?["id"]?.string ?? "") }.sorted { ($0.object?["beat"]?.object?["order"]?.double ?? 0) < ($1.object?["beat"]?.object?["order"]?.double ?? 0) }
        guard !ids.isEmpty, selected.count == ids.count else { throw ProjectError.invalidProject("Select archived beats to restore") }
        var rawRestored = [JSONValue]()
        for record in selected {
            guard let value = record.object?["beat"] else { throw ProjectError.invalidProject("Archived beat data is unavailable") }
            var beat = try JSONDecoder().decode(BoardBeat.self, from: JSONEncoder().encode(value))
            guard !board.beats.contains(where: { $0.id == beat.id }), let scene = scenes.first(where: { $0.id == beat.sceneID }), !scene.isTextLocked else { throw ProjectError.invalidProject("The scene is locked, missing, or already contains this beat") }
            if let blockID { beat.blockID = blockID }
            guard board.blocks.contains(where: { $0.id == beat.blockID }), !board.isBlockLocked(beat.blockID) else { throw ProjectError.invalidProject("Choose an existing unlocked destination container") }
            let ordered = board.orderedBeats, available = Set(board.beats.map(\.id))
            func neighbor(_ first: String?, key: String) -> String? {
                var cursor = first, seen = Set<String>()
                while let id = cursor, !available.contains(id), seen.insert(id).inserted {
                    cursor = archive.first(where: { $0.object?["id"]?.string == id })?.object?[key]?.string
                }
                return cursor.flatMap { available.contains($0) ? $0 : nil }
            }
            if let nextID = neighbor(record.object?["nextID"]?.string, key: "nextID"), let index = ordered.firstIndex(where: { $0.id == nextID }) {
                beat.order = ((index > 0 ? ordered[index - 1].order : ordered[index].order - 2) + ordered[index].order) / 2
            } else if let previousID = neighbor(record.object?["previousID"]?.string, key: "previousID"), let index = ordered.firstIndex(where: { $0.id == previousID }) {
                beat.order = (ordered[index].order + (index + 1 < ordered.count ? ordered[index + 1].order : ordered[index].order + 2)) / 2
            } else { beat.order = (ordered.last?.order ?? -1) + 1 }
            board.beats.append(beat); rawRestored.append(value)
        }
        let links = state["frontstageArchivedDependencies"]?.array ?? []; var remaining = [JSONValue]()
        let available = Set(board.beats.map(\.id))
        for value in links {
            let link = try JSONDecoder().decode(BoardDependency.self, from: JSONEncoder().encode(value))
            if available.contains(link.cause) && available.contains(link.effect) {
                if !board.dependencies.contains(where: { $0.id == link.id }) { board.dependencies.append(link) }
            } else { remaining.append(value) }
        }
        // Seed original raw records so the existing whiteboard serializer preserves extension fields.
        var fields = candidate.state["frontstageWhiteboard"]?.object ?? [:]
        fields["beats"] = .array((fields["beats"]?.array ?? []) + rawRestored)
        fields["dependencies"] = .array((fields["dependencies"]?.array ?? []) + links.filter { !remaining.contains($0) })
        // Validate the current projection before adding archived raw records to the persistence merge.
        try candidate.validateNativeScriptText(try whiteboard())
        candidate.state["frontstageWhiteboard"] = .object(fields)
        archive.removeAll { ids.contains($0.object?["id"]?.string ?? "") }
        candidate.state["frontstagePullouts"] = .array(archive)
        candidate.state["frontstageArchivedDependencies"] = .array(remaining)
        // Raw seeding changes the transient projection; commit using the same validated store directly.
        try board.validate(sceneIDs: Set(scenes.map(\.id)))
        try candidate.storeWhiteboard(board)
        self = candidate
    }
    public mutating func deletePulledOutBeats(_ ids: Set<String>) throws {
        var archive = state["frontstagePullouts"]?.array ?? []
        archive.removeAll { ids.contains($0.object?["id"]?.string ?? "") }
        state["frontstagePullouts"] = .array(archive)
    }
}

extension Project {
    public mutating func pullOutContainerContents(_ ids: Set<String>) throws {
        let board = try whiteboard()
        var included = ids
        var previous = -1
        while previous != included.count { previous = included.count; for block in board.blocks where block.parentID.map(included.contains) == true { included.insert(block.id) } }
        try pullOutBeats(Set(board.beats.filter { included.contains($0.blockID) }.map(\.id)))
    }
}
