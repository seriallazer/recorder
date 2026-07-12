import SwiftUI
import RecorderCore

extension Notification.Name {
    static let newAudioRecording = Notification.Name("Recorder.newAudioRecording")
    static let newMovieRecording = Notification.Name("Recorder.newMovieRecording")
    static let newScreenRecording = Notification.Name("Recorder.newScreenRecording")
    static let importAudioFile = Notification.Name("Recorder.importAudioFile")
}

@main
struct RecorderApplication: App {
    @StateObject private var library: RecordingLibrary
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let library = RecordingLibrary()
        _library = StateObject(wrappedValue: library)
        _coordinator = StateObject(wrappedValue: RecordingCoordinator(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(coordinator)
                .frame(minWidth: 980, minHeight: 650)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Audio Recording") {
                    NotificationCenter.default.post(name: .newAudioRecording, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Movie Recording") {
                    NotificationCenter.default.post(name: .newMovieRecording, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                Button("New Screen Recording") {
                    NotificationCenter.default.post(name: .newScreenRecording, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import Audio File…") {
                    NotificationCenter.default.post(name: .importAudioFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }
}
