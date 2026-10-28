#if os(macOS)
import SwiftUI
import FrontstageCore

struct PulledOutShelf: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var destinations: [String: String] = [:]

    private var beats: [PulledOutBeat] {
        workspace.project.pulledOutBeats
    }

    private var filteredScenes: [FrontstageCore.Scene] {
        workspace.project.scenes.filter { scene in
            beats.contains { $0.sceneID == scene.id }
        }
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulled-Out Beats Shelf")
                        .font(.title3.bold())
                    Text("\(beats.count) shelved beat\(beats.count == 1 ? "" : "s") available to restore")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") {
                workspace.showPulledOutShelf = false
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.regular)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search shelved beats by title or script text…", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Pulled-Out Beats")
                .font(.headline)
            Text("Beats or scenes that you remove from the script without deleting are safely shelved here. You can pull out beats anytime and restore them with one click.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func beatCard(_ beat: PulledOutBeat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(beat.title)
                    .font(.subheadline.bold())
                Text(beat.wasOmitted ? "Previously Omitted" : "Previously Active")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    workspace.edit("Delete Shelved Beat") {
                        try $0.deletePulledOutBeats([beat.id])
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete permanently")
            }

            let snippet = (try? ScreenplayTextCodec.decode(beat.html).string) ?? beat.html
            if !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.85))
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Picker("Destination:", selection: Binding(
                    get: { destinations[beat.id] ?? "" },
                    set: { destinations[beat.id] = $0 }
                )) {
                    Text("Original container").tag("")
                    ForEach(workspace.whiteboard.blocks.filter { !workspace.whiteboard.isBlockLocked($0.id) }) {
                        Text($0.name).tag($0.id)
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: 220)

                Spacer()

                Button {
                    workspace.edit("Restore Beat") {
                        try $0.restorePulledOutBeats(
                            [beat.id],
                            into: destinations[beat.id].flatMap { $0.isEmpty ? nil : $0 }
                        )
                    }
                } label: {
                    Label("Restore Beat", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private func sceneSection(_ scene: FrontstageCore.Scene, beats: [PulledOutBeat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(scene.title, systemImage: "film")
                    .font(.headline)
                Spacer()
                Button("Restore All to Scene") {
                    workspace.edit("Restore Scene Beats") {
                        try $0.restorePulledOutBeats(Set(beats.map(\.id)))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.bottom, 2)

            ForEach(beats) { beat in
                beatCard(beat)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 0.75))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView
            if !beats.isEmpty {
                searchField
            }
            if beats.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(filteredScenes) { scene in
                            let sceneBeats = beats.filter {
                                $0.sceneID == scene.id &&
                                (search.isEmpty || ($0.title + " " + $0.html).localizedCaseInsensitiveContains(search))
                            }
                            if !sceneBeats.isEmpty {
                                sceneSection(scene, beats: sceneBeats)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 460, idealHeight: 520)
        .background(Color(white: 0.08))
    }
}
#endif
