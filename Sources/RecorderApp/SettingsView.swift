import SwiftUI
import AppKit
import RecorderCore

struct SettingsView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @State private var error: String?

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
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 280)
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
