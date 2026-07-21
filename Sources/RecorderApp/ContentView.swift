import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecorderCore

struct ContentView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var selection: UUID?
    @State private var setupMode: RecordingMode?
    @State private var pendingDeletion: RecordingManifest?
    @State private var tagFilter = ""

    var selectedRecording: RecordingManifest? {
        library.recordings.first { $0.id == selection }
    }

    private var visibleRecordings: [RecordingManifest] {
        guard !tagFilter.isEmpty else { return library.recordings }
        return library.recordings.filter {
            $0.tag?.localizedCaseInsensitiveCompare(tagFilter) == .orderedSame
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Filter by tag", selection: $tagFilter) {
                        Text("All Tags").tag("")
                        ForEach(library.existingTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 170, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                List(selection: $selection) {
                    ForEach(visibleRecordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                            .contextMenu {
                                Button("Reveal in Finder") { reveal(recording) }
                                Button("Transcribe Again") { coordinator.transcribe(recording) }
                                Divider()
                                Button("Delete Recording Folder…", role: .destructive) {
                                    pendingDeletion = recording
                                }
                                .disabled(!canDelete(recording))
                            }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationSplitViewColumnWidth(min: 250, ideal: 310)
        } detail: {
            VStack(spacing: 0) {
                if let active = coordinator.activeRecording {
                    ActiveRecordingBanner(recording: active)
                    Divider()
                }
                if let selectedRecording {
                    RecordingDetailView(
                        recording: selectedRecording,
                        onRequestDelete: { pendingDeletion = $0 }
                    )
                        .id(selectedRecording.id)
                } else {
                    EmptyLibraryView(
                        start: { setupMode = $0 },
                        importAudio: { importAudioFile() }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { importAudioFile() } label: { Label("Import", systemImage: "tray.and.arrow.down") }
                    .help("Import Audio File")
                Button { setupMode = .audio } label: { Label("Audio", systemImage: "waveform") }
                    .help("New Audio Recording")
                Button { setupMode = .camera } label: { Label("Movie", systemImage: "video") }
                    .help("New Movie Recording")
                Button { setupMode = .screen } label: { Label("Screen", systemImage: "rectangle.on.rectangle") }
                    .help("New Screen Recording")
            }
        }
        .sheet(item: $setupMode) { mode in
            RecordingSetupView(mode: mode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newAudioRecording)) { _ in setupMode = .audio }
        .onReceive(NotificationCenter.default.publisher(for: .newMovieRecording)) { _ in setupMode = .camera }
        .onReceive(NotificationCenter.default.publisher(for: .newScreenRecording)) { _ in setupMode = .screen }
        .onReceive(NotificationCenter.default.publisher(for: .importAudioFile)) { _ in importAudioFile() }
        .onChange(of: library.recordings) { _, recordings in
            if !tagFilter.isEmpty,
               !library.existingTags.contains(where: {
                   $0.localizedCaseInsensitiveCompare(tagFilter) == .orderedSame
               }) {
                tagFilter = ""
            }
            if let selection, visibleRecordings.contains(where: { $0.id == selection }) { return }
            selection = visibleRecordings.first?.id
        }
        .onChange(of: tagFilter) { _, _ in
            if let selection, visibleRecordings.contains(where: { $0.id == selection }) { return }
            selection = visibleRecordings.first?.id
        }
        .onChange(of: coordinator.activeRecording?.id) { _, activeRecordingID in
            if let activeRecordingID {
                tagFilter = ""
                selection = activeRecordingID
            }
        }
        .task {
            if selection == nil { selection = visibleRecordings.first?.id }
        }
        .alert("Recorder", isPresented: Binding(
            get: { coordinator.presentedError != nil },
            set: { if !$0 { coordinator.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { coordinator.presentedError = nil }
        } message: {
            Text(coordinator.presentedError ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Delete Recording Folder?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { recording in
            Button("Delete Folder", role: .destructive) {
                delete(recording)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { recording in
            Text("This permanently deletes “\(recording.title)” and its entire folder, including the original media and transcript. This cannot be undone.")
        }
    }

    private func reveal(_ recording: RecordingManifest) {
        let folder = library.folderURL(for: recording.id)
        let file = recording.fileURL(for: recording.mediaFile, in: folder) ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func canDelete(_ recording: RecordingManifest) -> Bool {
        coordinator.activeRecording?.id != recording.id
            && ![.previewing, .recording, .finalizing, .transcribing].contains(recording.state)
    }

    private func delete(_ recording: RecordingManifest) {
        guard canDelete(recording) else {
            pendingDeletion = nil
            coordinator.presentedError = "Wait for the recording or transcription to finish before deleting its folder."
            return
        }
        do {
            try library.delete(recording)
            if selection == recording.id {
                selection = visibleRecordings.first?.id
            }
        } catch {
            coordinator.presentedError = "Could not delete the recording folder: \(error.localizedDescription)"
        }
        pendingDeletion = nil
    }

    private func importAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio File"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            if let imported = await coordinator.importAudioFile(from: url) {
                selection = imported.id
            }
        }
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var library: RecordingLibrary
    let recording: RecordingManifest

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 70, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: icon)
                    Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    if let tag = recording.tag {
                        Text("• \(tag)")
                    }
                    if recording.duration > 0 {
                        Text("• \(TranscriptDocument.timestamp(recording.duration))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if recording.state == .transcribing {
                    Label("Transcribing", systemImage: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else if recording.state == .previewing {
                    Label("Starting", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else if recording.state == .recording {
                    Label("Recording", systemImage: "record.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if recording.state == .failed {
                    Label("Needs attention", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var thumbnail: some View {
        let folder = library.folderURL(for: recording.id)
        if let url = recording.fileURL(for: recording.thumbnailFile, in: folder),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: recording.mode == .audio ? "waveform" : icon)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch recording.mode {
        case .audio: "mic.fill"
        case .camera: "video.fill"
        case .screen: "rectangle.on.rectangle"
        }
    }
}

private struct EmptyLibraryView: View {
    let start: (RecordingMode) -> Void
    let importAudio: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Ready to Record", systemImage: "record.circle")
        } description: {
            Text("Capture audio, camera video, your screen, or import audio to transcribe entirely on this Mac.")
        } actions: {
            HStack {
                Button("Import Audio") { importAudio() }
                Button("Record Audio") { start(.audio) }
                Button("Record Movie") { start(.camera) }
                Button("Record Screen") { start(.screen) }
            }
        }
    }
}
