import SwiftUI
import AVKit
import AppKit
import RecorderCore

struct RecordingDetailView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let recording: RecordingManifest

    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var transcript: TranscriptDocument?
    @State private var player: AVPlayer?
    @State private var playbackRate: Float = 1
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    playerSection
                    trimSection
                    transcriptSection
                }
                .padding(24)
            }
        }
        .task(id: recording.updatedAt) {
            load()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title).font(.title2.bold())
                Text("\(recording.mode.displayName) • \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.state == .transcribing {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: coordinator.modelProgress).frame(width: 160)
                    Text(coordinator.modelPhase ?? "Transcribing locally…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { coordinator.cancelTranscription(for: recording.id) }
            } else {
                Button { coordinator.transcribe(recording) } label: {
                    Label(transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.bubble")
                }
            }
            Menu {
                Button("Reveal in Finder") { reveal() }
                Button("Export Trimmed Copy…") { exportTrimmed() }
                Divider()
                Button("Delete Recording", role: .destructive) { try? library.delete(recording) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(18)
    }

    @ViewBuilder private var playerSection: some View {
        GroupBox("Playback") {
            VStack(spacing: 10) {
                if let player {
                    NativePlayerView(player: player)
                        .frame(minHeight: recording.mode == .audio ? 120 : 330)
                        .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button { seek(to: recording.trimStart) } label: {
                            Label("Trim Start", systemImage: "backward.end")
                        }
                        Spacer()
                        Picker("Speed", selection: $playbackRate) {
                            Text("0.5×").tag(Float(0.5))
                            Text("1×").tag(Float(1))
                            Text("1.5×").tag(Float(1.5))
                            Text("2×").tag(Float(2))
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                        .onChange(of: playbackRate) { _, rate in
                            if player.rate != 0 { player.rate = rate }
                            player.defaultRate = rate
                        }
                        Spacer()
                        Button { seek(to: recording.effectiveTrimEnd) } label: {
                            Label("Trim End", systemImage: "forward.end")
                        }
                    }
                } else {
                    ContentUnavailableView("Media Missing", systemImage: "questionmark.video")
                        .frame(height: 180)
                }
            }
            .padding(8)
        }
    }

    private var trimSection: some View {
        GroupBox("Non-destructive Trim") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Start \(TranscriptDocument.timestamp(trimStart))")
                    Slider(value: $trimStart, in: 0...max(0.01, min(trimEnd, recording.duration)))
                    Text("End \(TranscriptDocument.timestamp(trimEnd))")
                    Slider(value: $trimEnd, in: min(recording.duration, max(trimStart, 0))...max(recording.duration, 0.01))
                }
                HStack {
                    Text("The original is preserved. Export creates a new media file and matching transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        trimStart = 0
                        trimEnd = recording.duration
                        try? coordinator.updateTrim(for: recording, start: trimStart, end: trimEnd)
                    }
                    Button("Save Markers") {
                        try? coordinator.updateTrim(for: recording, start: trimStart, end: trimEnd)
                    }
                    Button("Export…") { exportTrimmed() }
                        .buttonStyle(.borderedProminent)
                        .disabled(exporting || trimEnd <= trimStart)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder private var transcriptSection: some View {
        GroupBox("Local Transcript") {
            VStack(alignment: .leading, spacing: 10) {
                if let transcript {
                    HStack {
                        Label("\(transcript.speakerCount) speaker\(transcript.speakerCount == 1 ? "" : "s") detected", systemImage: "person.2")
                        Spacer()
                        Button("Reveal Text File") {
                            let url = library.folderURL(for: recording.id).appendingPathComponent("transcript.txt")
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Divider()
                    ForEach(transcript.segments) { segment in
                        if segment.endTime >= recording.trimStart && segment.startTime <= recording.effectiveTrimEnd {
                            Button {
                                seek(to: segment.startTime)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(TranscriptDocument.timestamp(max(0, segment.startTime - recording.trimStart)))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                    Text(segment.speaker).fontWeight(.semibold).frame(width: 85, alignment: .leading)
                                    Text(segment.text).frame(maxWidth: .infinity, alignment: .leading)
                                    if segment.isOverlapping {
                                        Image(systemName: "person.2.wave.2").foregroundStyle(.orange).help("Overlapping speech")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                } else if recording.state == .transcribing {
                    HStack { ProgressView(); Text("Transcribing entirely on this Mac…") }
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ContentUnavailableView {
                        Label("No Transcript Yet", systemImage: "text.bubble")
                    } description: {
                        Text("Run the local English transcription and speaker detection models.")
                    } actions: {
                        Button("Transcribe Locally") { coordinator.transcribe(recording) }
                    }
                    .frame(minHeight: 160)
                }
            }
            .padding(8)
        }
    }

    private func load() {
        trimStart = recording.trimStart
        trimEnd = recording.effectiveTrimEnd
        transcript = coordinator.loadTranscript(for: recording)
        let folder = library.folderURL(for: recording.id)
        if let mediaURL = recording.fileURL(for: recording.mediaFile, in: folder) {
            player = AVPlayer(url: mediaURL)
        }
    }

    private func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func reveal() {
        let folder = library.folderURL(for: recording.id)
        let file = recording.fileURL(for: recording.mediaFile, in: folder) ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func exportTrimmed() {
        let panel = NSSavePanel()
        panel.title = "Export Trimmed Recording"
        panel.nameFieldStringValue = "\(recording.title) — Trimmed.\(recording.mode == .audio ? "m4a" : "mov")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                try await coordinator.exportTrimmed(recording, to: url)
            } catch {
                coordinator.presentedError = error.localizedDescription
            }
        }
    }
}

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
