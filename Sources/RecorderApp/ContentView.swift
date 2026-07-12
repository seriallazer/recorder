import SwiftUI
import AppKit
import RecorderCore

struct ContentView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var selection: UUID?
    @State private var setupMode: RecordingMode?

    var selectedRecording: RecordingManifest? {
        library.recordings.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.recordings) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id)
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(recording) }
                            Button("Transcribe Again") { coordinator.transcribe(recording) }
                            Divider()
                            Button("Delete", role: .destructive) { try? library.delete(recording) }
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
                    RecordingDetailView(recording: selectedRecording)
                        .id(selectedRecording.id)
                } else {
                    EmptyLibraryView { setupMode = $0 }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        .onChange(of: library.recordings) { _, recordings in
            if selection == nil { selection = recordings.first?.id }
        }
        .task {
            if selection == nil { selection = library.recordings.first?.id }
        }
        .alert("Recorder", isPresented: Binding(
            get: { coordinator.presentedError != nil },
            set: { if !$0 { coordinator.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { coordinator.presentedError = nil }
        } message: {
            Text(coordinator.presentedError ?? "An unknown error occurred.")
        }
    }

    private func reveal(_ recording: RecordingManifest) {
        let folder = library.folderURL(for: recording.id)
        let file = recording.fileURL(for: recording.mediaFile, in: folder) ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([file])
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

    var body: some View {
        ContentUnavailableView {
            Label("Ready to Record", systemImage: "record.circle")
        } description: {
            Text("Capture audio, camera video, or your screen and transcribe it entirely on this Mac.")
        } actions: {
            HStack {
                Button("Record Audio") { start(.audio) }
                Button("Record Movie") { start(.camera) }
                Button("Record Screen") { start(.screen) }
            }
        }
    }
}
