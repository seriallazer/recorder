import SwiftUI
import AppKit
import RecorderCore

struct SettingsView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @State private var error: String?
    @AppStorage(RecorderPreferences.diarizationModeKey)
    private var diarizationMode = DiarizationMode.automatic.rawValue
    @AppStorage(RecorderPreferences.expectedSpeakerCountKey)
    private var expectedSpeakerCount = 2
    @AppStorage(RecorderShortcutPreferences.audioSystemAudioKey)
    private var shortcutAudioIncludesSystemAudio = false
    @AppStorage(RecorderShortcutPreferences.screenSystemAudioKey)
    private var shortcutScreenIncludesSystemAudio = true
    @AppStorage(RecorderShortcutPreferences.screenMicrophoneKey)
    private var shortcutScreenIncludesMicrophone = true

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
            Section("Global Recording Shortcut") {
                LabeledContent("Audio") {
                    Text("⌘L").font(.system(.body, design: .monospaced).bold())
                }
                Toggle(
                    "Include meeting/system audio",
                    isOn: $shortcutAudioIncludesSystemAudio
                )

                Divider()
                LabeledContent("Entire screen") {
                    Text("⌘N").font(.system(.body, design: .monospaced).bold())
                }
                Toggle(
                    "Record system audio",
                    isOn: $shortcutScreenIncludesSystemAudio
                )
                Toggle(
                    "Record microphone",
                    isOn: $shortcutScreenIncludesMicrophone
                )

                Divider()
                LabeledContent("Movie/video") {
                    Text("⌘B").font(.system(.body, design: .monospaced).bold())
                }

                Text("While Recorder is running, use any shortcut from any app to start immediately. Press any recording shortcut again to stop, save, and begin transcription automatically. These keys are reserved globally while Recorder is open.")
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
