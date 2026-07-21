import SwiftUI
import AVKit
import AppKit
import RecorderCore

struct RecordingDetailView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let recording: RecordingManifest
    let onRequestDelete: (RecordingManifest) -> Void

    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var transcript: TranscriptDocument?
    @State private var player: AVPlayer?
    @State private var showingInfo = false
    @State private var showingRename = false
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
        .sheet(isPresented: $showingRename) {
            RecordingIdentityEditor(recording: recording) { title, tag in
                do {
                    try library.rename(recording, title: title, tag: tag)
                    return true
                } catch {
                    coordinator.presentedError = error.localizedDescription
                    return false
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(recording.title).font(.title2.bold())
                    Button {
                        showingRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename and Tag")
                    .disabled(!canRename)
                }
                Text(headerMetadata)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.state == .transcribing {
                VStack(alignment: .trailing, spacing: 4) {
                    if isIndeterminateTranscriptionPhase {
                        ProgressView().frame(width: 160)
                    } else {
                        ProgressView(value: coordinator.modelProgress).frame(width: 160)
                    }
                    Text(coordinator.modelPhase ?? "Transcribing locally…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { coordinator.cancelTranscription(for: recording.id) }
            } else {
                Button { coordinator.transcribe(recording) } label: {
                    Label(transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.bubble")
                }
            }
            Button {
                showingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Recording Info")
            .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                RecordingInfoPopover(
                    recording: recording,
                    folder: library.folderURL(for: recording.id),
                    organizedURL: recording.organizationPath.map { library.rootURL.appendingPathComponent($0) },
                    canRename: canRename,
                    canDelete: canDelete,
                    onRename: {
                        showingInfo = false
                        DispatchQueue.main.async { showingRename = true }
                    },
                    onRequestDelete: {
                        showingInfo = false
                        onRequestDelete(recording)
                    }
                )
            }
            Menu {
                Button("Reveal in Finder") { reveal() }
                Button("Rename & Tag…") { showingRename = true }
                    .disabled(!canRename)
                Divider()
                Button("Transcribe Automatically") {
                    coordinator.transcribe(recording, options: .automatic)
                }
                .disabled(recording.state == .transcribing)
                Button("Transcribe with Stable Labels") {
                    coordinator.transcribe(recording, options: .stable)
                }
                .disabled(recording.state == .transcribing)
                Button("Transcribe with Enhanced Diarization") {
                    let preferences = RecorderPreferences.diarizationOptions()
                    coordinator.transcribe(recording, options: DiarizationOptions(
                        mode: .enhanced,
                        expectedSpeakerCount: preferences.expectedSpeakerCount
                    ))
                }
                .disabled(recording.state == .transcribing)
                Button("Export Trimmed Copy…") { exportTrimmed() }
                Divider()
                Button("Delete Recording Folder…", role: .destructive) {
                    onRequestDelete(recording)
                }
                .disabled(!canDelete)
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
                        Button { setTrimStartAtPlayhead() } label: {
                            Label("Set Start Here", systemImage: "backward.end")
                        }
                        .help("Use the current playback position as the trim start")
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
                        Button { setTrimEndAtPlayhead() } label: {
                            Label("Set End Here", systemImage: "forward.end")
                        }
                        .help("Use the current playback position as the trim end")
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
                    Slider(
                        value: $trimStart,
                        in: 0...max(0.01, min(trimEnd, recording.duration)),
                        onEditingChanged: { editing in
                            if !editing { seek(to: trimStart) }
                        }
                    )
                    Text("End \(TranscriptDocument.timestamp(trimEnd))")
                    Slider(
                        value: $trimEnd,
                        in: min(recording.duration, max(trimStart, 0))...max(recording.duration, 0.01),
                        onEditingChanged: { editing in
                            if !editing { seek(to: trimEnd) }
                        }
                    )
                }
                HStack {
                    Text("The original is preserved. Export creates a new media file and matching transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        trimStart = 0
                        trimEnd = recording.duration
                        saveTrimMarkers()
                    }
                    Button("Save Markers") { saveTrimMarkers() }
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
                        if let attribution = transcript.speakerAttribution {
                            Text("• \(attribution.displayName)")
                                .foregroundStyle(attribution == .stableFallback ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button("Reveal Text File") { revealTranscript() }
                        Button("Copy File Path") { copyTranscriptPath() }
                    }
                    Divider()
                    if let note = transcript.attributionNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(transcript.segments) { segment in
                        if segment.endTime >= trimStart && segment.startTime <= trimEnd {
                            Button {
                                seek(to: segment.startTime)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(TranscriptDocument.timestamp(max(0, segment.startTime - trimStart)))
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
        let playbackPosition = player?.currentTime()
        trimStart = recording.trimStart
        trimEnd = recording.effectiveTrimEnd
        transcript = coordinator.loadTranscript(for: recording)
        let folder = library.folderURL(for: recording.id)
        if let mediaURL = recording.fileURL(for: recording.mediaFile, in: folder) {
            player = AVPlayer(url: mediaURL)
            if let playbackPosition, playbackPosition.isNumeric {
                player?.seek(to: playbackPosition, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func setTrimStartAtPlayhead() {
        guard let seconds = currentPlaybackSeconds else { return }
        trimStart = min(max(0, seconds), trimEnd)
    }

    private func setTrimEndAtPlayhead() {
        guard let seconds = currentPlaybackSeconds else { return }
        trimEnd = max(trimStart, min(seconds, recording.duration))
    }

    private var currentPlaybackSeconds: TimeInterval? {
        guard let seconds = player.map({ CMTimeGetSeconds($0.currentTime()) }),
              seconds.isFinite else { return nil }
        return seconds
    }

    private func saveTrimMarkers() {
        do {
            try coordinator.updateTrim(
                for: recording,
                start: trimStart,
                end: trimEnd
            )
        } catch {
            coordinator.presentedError = error.localizedDescription
        }
    }

    private func reveal() {
        let folder = library.folderURL(for: recording.id)
        let file = recording.fileURL(for: recording.mediaFile, in: folder) ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private var transcriptURL: URL {
        library.folderURL(for: recording.id).appendingPathComponent("transcript.txt")
    }

    private var isIndeterminateTranscriptionPhase: Bool {
        coordinator.modelPhase?.hasPrefix("Transcribing audio track") == true
    }

    private var canDelete: Bool {
        coordinator.activeRecording?.id != recording.id
            && ![.previewing, .recording, .finalizing, .transcribing].contains(recording.state)
    }

    private var canRename: Bool {
        coordinator.activeRecording?.id != recording.id
            && ![.previewing, .recording, .finalizing, .transcribing].contains(recording.state)
    }

    private var headerMetadata: String {
        var parts = [
            recording.mode.displayName,
            recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if let tag = recording.tag { parts.append(tag) }
        return parts.joined(separator: " • ")
    }

    private func revealTranscript() {
        NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
    }

    private func copyTranscriptPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptURL.path, forType: .string)
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
                try await coordinator.exportTrimmed(
                    recording,
                    to: url,
                    startTime: trimStart,
                    endTime: trimEnd
                )
            } catch {
                coordinator.presentedError = error.localizedDescription
            }
        }
    }
}

private struct RecordingInfoPopover: View {
    let recording: RecordingManifest
    let folder: URL
    let organizedURL: URL?
    let canRename: Bool
    let canDelete: Bool
    let onRename: () -> Void
    let onRequestDelete: () -> Void

    @State private var metadata: RecordingMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recording Info", systemImage: "info.circle.fill")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                infoRow("Size on disk", metadata.map { bytes($0.allocatedSize) } ?? "Calculating…")
                if let metadata {
                    infoRow("Contents", "\(metadata.fileCount) file\(metadata.fileCount == 1 ? "" : "s") • \(bytes(metadata.logicalSize))")
                    if let fileSize = metadata.media?.fileSize {
                        infoRow("Media file", bytes(fileSize))
                    }
                }
                infoRow("Duration", TranscriptDocument.timestamp(metadata?.media?.duration ?? recording.duration))
                if let dimensions {
                    infoRow("Video", dimensions)
                }
                if let videoCodec = metadata?.media?.videoCodec {
                    infoRow("Video codec", videoCodec)
                }
                if let audioDetails {
                    infoRow("Audio", audioDetails)
                }
                infoRow("Audio captured", capturedAudio)
                if let echoCancellationStatus {
                    infoRow("Echo cancellation", echoCancellationStatus)
                }
                if let tag = recording.tag {
                    infoRow("Tag", tag)
                }
                infoRow("Created", recording.createdAt.formatted(date: .abbreviated, time: .standard))
                if let modified = metadata?.latestModificationDate {
                    infoRow("Modified", modified.formatted(date: .abbreviated, time: .standard))
                }
                infoRow("Status", recording.state.rawValue.capitalized)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(organizedURL == nil ? "Storage folder" : "Organized path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text((organizedURL ?? folder).path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            HStack {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([organizedURL ?? folder])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((organizedURL ?? folder).path, forType: .string)
                }
                Button("Rename & Tag…", action: onRename)
                    .disabled(!canRename)
                Spacer()
                Button("Delete Folder…", role: .destructive, action: onRequestDelete)
                    .disabled(!canDelete)
            }
        }
        .padding(18)
        .frame(width: 410)
        .task(id: recording.updatedAt) {
            metadata = await RecordingMetadataReader.loadStorage(folder: folder)
            guard !Task.isCancelled,
                  let mediaURL = recording.fileURL(for: recording.mediaFile, in: folder),
                  FileManager.default.fileExists(atPath: mediaURL.path) else { return }
            let media = await RecordingMetadataReader.loadMedia(at: mediaURL)
            guard !Task.isCancelled else { return }
            metadata?.media = media
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var dimensions: String? {
        guard let width = metadata?.media?.width,
              let height = metadata?.media?.height else { return nil }
        if let frameRate = metadata?.media?.frameRate {
            return "\(width) × \(height) • \(frameRate.formatted(.number.precision(.fractionLength(0...1)))) fps"
        }
        return "\(width) × \(height)"
    }

    private var audioDetails: String? {
        guard let media = metadata?.media else { return nil }
        let channels: String? = switch media.audioChannelCount {
        case 1: "Mono"
        case 2: "Stereo"
        case let count?: "\(count) channels"
        case nil: nil
        }
        let sampleRate = media.audioSampleRate.map {
            "\(($0 / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
        }
        let parts = [media.audioCodec, sampleRate, channels].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private var capturedAudio: String {
        var sources: [String] = []
        if recording.configuration.capturesSystemAudio { sources.append("System") }
        if recording.configuration.capturesMicrophone { sources.append("Microphone") }
        return sources.isEmpty ? "None" : sources.joined(separator: " + ")
    }

    private var echoCancellationStatus: String? {
        guard recording.configuration.capturesSystemAudio,
              recording.configuration.capturesMicrophone else { return nil }
        if recording.echoCancellationApplied == true { return "Applied" }
        if recording.configuration.echoCancellationMode == .off { return "Off" }
        if recording.echoCancellationApplied == false {
            return "Unavailable — raw fallback"
        }
        return "Not recorded"
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct RecordingIdentityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let recording: RecordingManifest
    let onSave: (String, String?) -> Bool

    @State private var title: String
    @State private var tag: String

    init(recording: RecordingManifest, onSave: @escaping (String, String?) -> Bool) {
        self.recording = recording
        self.onSave = onSave
        _title = State(initialValue: recording.title)
        _tag = State(initialValue: recording.tag ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Rename Recording", systemImage: "pencil.and.list.clipboard")
                .font(.title2.bold())

            Form {
                TextField("Title", text: $title)
                TextField("Tag (optional)", text: $tag)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 5) {
                Text("Organized path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pathPreview)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            Text("The media folder stays in place. Recorder creates a Finder symlink at this organized path after active recording or transcription work has finished.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    if onSave(title, normalizedTag.isEmpty ? nil : normalizedTag) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var pathPreview: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let name = sanitized("\(formatter.string(from: recording.createdAt))_\(title)")
        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTag.isEmpty
            ? "Recorder / \(name)"
            : "Recorder / \(sanitized(normalizedTag)) / \(name)"
    }

    private func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") }
        let collapsed = String(scalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "recording" : collapsed
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
