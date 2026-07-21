import SwiftUI
import AppKit
import RecorderCore

struct SettingsView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var shortcutController: ShortcutRecordingController
    @State private var error: String?
    @AppStorage(RecorderPreferences.diarizationModeKey)
    private var diarizationMode = DiarizationMode.automatic.rawValue
    @AppStorage(RecorderPreferences.expectedSpeakerCountKey)
    private var expectedSpeakerCount = 2
    @AppStorage(RecorderPreferences.echoCancellationModeKey)
    private var echoCancellationMode = EchoCancellationMode.automatic.rawValue
    @AppStorage(RecorderShortcutPreferences.audioSystemAudioKey)
    private var shortcutAudioIncludesSystemAudio = false
    @AppStorage(RecorderShortcutPreferences.screenSystemAudioKey)
    private var shortcutScreenIncludesSystemAudio = true
    @AppStorage(RecorderShortcutPreferences.screenMicrophoneKey)
    private var shortcutScreenIncludesMicrophone = true
    @State private var shortcutSet = RecorderShortcutPreferences.shortcuts()
    @State private var shortcutSaveMessage: String?
    @State private var shortcutSaveFailed = false

    var body: some View {
        Form {
            Section("Recording Library") {
                Text(library.rootURL.path).textSelection(.enabled)
                HStack {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Reveal in Finder") { NSWorkspace.shared.open(library.rootURL) }
                }
                Text("Original recordings, audio companions, manifests, and transcripts are stored here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label("Transcription and speaker detection run locally.", systemImage: "lock.shield")
                Text("Network access is used only when downloading the Core ML models for the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker Echo") {
                Picker("Echo cancellation", selection: $echoCancellationMode) {
                    ForEach(EchoCancellationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Auto uses Apple's voice processing for compatible audio-only captures. Screen recording keeps stable, separate raw microphone and system tracks because live voice processing can conflict with ScreenCaptureKit. Off preserves completely raw microphone audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Global Recording Shortcut") {
                ShortcutEditorRow(
                    title: "Audio",
                    shortcut: shortcutBinding(for: .audio)
                )
                Toggle(
                    "Include meeting/system audio",
                    isOn: $shortcutAudioIncludesSystemAudio
                )

                Divider()
                ShortcutEditorRow(
                    title: "Entire screen",
                    shortcut: shortcutBinding(for: .screen)
                )
                Toggle(
                    "Record system audio",
                    isOn: $shortcutScreenIncludesSystemAudio
                )
                Toggle(
                    "Record microphone",
                    isOn: $shortcutScreenIncludesMicrophone
                )

                Divider()
                ShortcutEditorRow(
                    title: "Movie/video",
                    shortcut: shortcutBinding(for: .camera)
                )

                HStack {
                    Button("Apply Shortcuts") { saveShortcuts(shortcutSet) }
                        .disabled(!shortcutSet.hasUniqueShortcuts)
                    Button("Restore Defaults") {
                        shortcutSet = .defaults
                        saveShortcuts(.defaults)
                    }
                    if let shortcutSaveMessage {
                        Text(shortcutSaveMessage)
                            .font(.caption)
                            .foregroundStyle(shortcutSaveFailed ? .red : .secondary)
                    }
                }

                if !shortcutSet.hasUniqueShortcuts {
                    Label(
                        "Each recording mode must use a different shortcut.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text("While Recorder is running, use a shortcut from any app to start immediately. Press the same shortcut again to stop, save, and begin transcription automatically. Other recording modes remain blocked until capture finishes. These keys are reserved globally while Recorder is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Speaker Attribution") {
                Picker("Transcription mode", selection: $diarizationMode) {
                    ForEach(DiarizationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Stepper(
                    "Expected speakers: \(expectedSpeakerCount)",
                    value: $expectedSpeakerCount,
                    in: 2...6
                )
                .disabled(diarizationMode != DiarizationMode.enhanced.rawValue)
                Text("Auto samples short sections across mixed audio, then chooses stable labels for one voice or enhanced diarization for multiple voices. Separate microphone and system-audio tracks are preferred. Model failures always fall back safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 650)
        .alert("Could Not Change Library", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func shortcutBinding(
        for mode: RecordingMode
    ) -> Binding<RecordingKeyboardShortcut> {
        Binding(
            get: { shortcutSet[mode] },
            set: {
                shortcutSet[mode] = $0
                shortcutSaveMessage = nil
            }
        )
    }

    private func saveShortcuts(_ shortcuts: RecordingShortcutSet) {
        do {
            try shortcutController.apply(shortcuts: shortcuts)
            shortcutSaveMessage = "Applied"
            shortcutSaveFailed = false
        } catch {
            shortcutSaveMessage = error.localizedDescription
            shortcutSaveFailed = true
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.setRootURL(url) } catch { self.error = error.localizedDescription }
    }
}

private struct ShortcutEditorRow: View {
    let title: String
    @Binding var shortcut: RecordingKeyboardShortcut

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker("Modifiers", selection: $shortcut.modifiers) {
                    ForEach(RecordingShortcutModifiers.allCases) { modifiers in
                        Text(modifiers.displayName).tag(modifiers)
                    }
                }
                .labelsHidden()
                .frame(width: 205)

                Picker("Key", selection: $shortcut.key) {
                    ForEach(RecordingKeyboardShortcut.availableKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 62)

                Text(shortcut.displayText)
                    .font(.system(.body, design: .monospaced).bold())
                    .frame(width: 55, alignment: .trailing)
            }
        }
    }
}
