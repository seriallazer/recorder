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
    @State private var cleanupSummary = LibraryCleanupSummary()
    @State private var includeRollbackMedia = false
    @State private var showingCleanupConfirmation = false
    @State private var cleanupMessage: String?

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

                Divider()
                LabeledContent("Safe temporary items") {
                    Text("\(cleanupSummary.temporaryItemCount) • \(bytes(cleanupSummary.temporaryBytes))")
                }
                if cleanupSummary.rollbackItemCount > 0 {
                    Toggle(isOn: $includeRollbackMedia) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also remove echo-cleanup originals")
                            Text("\(cleanupSummary.rollbackItemCount) rollback files • \(bytes(cleanupSummary.rollbackBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Refresh Cleanup Size") { refreshCleanupSummary() }
                    Button("Delete Selected Items…", role: .destructive) {
                        showingCleanupConfirmation = true
                    }
                    .disabled(selectedCleanupItemCount == 0)
                    if let cleanupMessage {
                        Text(cleanupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Safe cleanup excludes active, failed, or recoverable recordings and never removes manifests, current media, stems, transcripts, thumbnails, or exports. Echo-cleanup originals are removed only when selected above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Auto uses Apple's voice processing for compatible audio-only captures. Screen recording keeps capture stable, then detects and removes speaker leakage from its separate tracks after recording. When cleanup is applied, the original movie, audio, and microphone track are retained as rollback files. Off preserves completely raw microphone audio.")
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
        .frame(width: 640, height: 700)
        .task { refreshCleanupSummary() }
        .onChange(of: library.rootURL) { _, _ in refreshCleanupSummary() }
        .confirmationDialog(
            "Delete Selected Temporary Items?",
            isPresented: $showingCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedCleanupItemCount) Items", role: .destructive) {
                cleanTemporaryFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reclaims about \(bytes(selectedCleanupBytes)). Completed-recording leftovers will be deleted permanently. Your current media and transcripts are not included.")
        }
        .alert("Recorder Settings", isPresented: Binding(
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

    private var selectedCleanupItemCount: Int {
        cleanupSummary.temporaryItemCount
            + (includeRollbackMedia ? cleanupSummary.rollbackItemCount : 0)
    }

    private var selectedCleanupBytes: Int64 {
        cleanupSummary.temporaryBytes
            + (includeRollbackMedia ? cleanupSummary.rollbackBytes : 0)
    }

    private func refreshCleanupSummary() {
        cleanupSummary = library.cleanupSummary()
        if cleanupSummary.rollbackItemCount == 0 {
            includeRollbackMedia = false
        }
    }

    private func cleanTemporaryFiles() {
        do {
            let result = try library.cleanTemporaryFiles(includeRollbackMedia: includeRollbackMedia)
            cleanupMessage = "Removed \(result.removedItemCount) items • \(bytes(result.reclaimedBytes))"
            refreshCleanupSummary()
        } catch {
            self.error = "Could not clean temporary files: \(error.localizedDescription)"
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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
