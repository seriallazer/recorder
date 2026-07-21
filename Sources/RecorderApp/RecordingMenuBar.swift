import SwiftUI
import RecorderCore

struct RecordingMenuBarLabel: View {
    let recording: RecordingManifest?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "waveform")
                .font(.system(
                    size: 14,
                    weight: recording == nil ? .regular : .black
                ))
                .foregroundStyle(recording == nil ? .secondary : .primary)

            if let suffix {
                Text(suffix)
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 23, height: 17)
        .accessibilityLabel(accessibilityLabel)
    }

    private var suffix: String? {
        switch recording?.mode {
        case .audio: "a"
        case .screen: "s"
        case .camera: "v"
        case nil: nil
        }
    }

    private var accessibilityLabel: String {
        guard let recording else { return "Recorder is idle" }
        return "Recorder is recording \(recording.mode.displayName.lowercased())"
    }
}

struct RecordingMenuBarContent: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var shortcutController: ShortcutRecordingController

    var body: some View {
        if let recording = coordinator.activeRecording {
            Label(statusText(for: recording), systemImage: "waveform")
            Text(TranscriptDocument.timestamp(coordinator.elapsedTime))
                .font(.system(.body, design: .monospaced))
            Divider()
            Button("Stop, Save & Transcribe") {
                Task { await coordinator.stop() }
            }
            .disabled(recording.state == .finalizing)
        } else {
            Label("Recorder is idle", systemImage: "waveform")
            Divider()
            Text("\(shortcutController.registeredShortcuts.audio.displayText)  Audio")
            Text("\(shortcutController.registeredShortcuts.screen.displayText)  Entire screen")
            Text("\(shortcutController.registeredShortcuts.camera.displayText)  Movie/video")
        }
    }

    private func statusText(for recording: RecordingManifest) -> String {
        switch recording.state {
        case .previewing: "Starting \(recording.mode.displayName.lowercased()) recording…"
        case .finalizing: "Finalizing recording…"
        default: "Recording \(recording.mode.displayName.lowercased())"
        }
    }
}
