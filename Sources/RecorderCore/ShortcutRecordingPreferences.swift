import Foundation

public enum ShortcutRecordingAction: Equatable, Sendable {
    case start
    case stop
    case blocked(activeMode: RecordingMode)
}

public enum RecordingShortcutModifiers: String, Codable, CaseIterable, Identifiable, Sendable {
    case command
    case commandOption
    case commandShift
    case commandControl
    case commandOptionShift
    case commandOptionControl
    case controlOption

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .command: "Command"
        case .commandOption: "Command + Option"
        case .commandShift: "Command + Shift"
        case .commandControl: "Command + Control"
        case .commandOptionShift: "Command + Option + Shift"
        case .commandOptionControl: "Command + Option + Control"
        case .controlOption: "Control + Option"
        }
    }

    public var symbols: String {
        switch self {
        case .command: "⌘"
        case .commandOption: "⌘⌥"
        case .commandShift: "⌘⇧"
        case .commandControl: "⌘⌃"
        case .commandOptionShift: "⌘⌥⇧"
        case .commandOptionControl: "⌘⌥⌃"
        case .controlOption: "⌃⌥"
        }
    }
}

public struct RecordingKeyboardShortcut: Codable, Hashable, Sendable {
    public var modifiers: RecordingShortcutModifiers
    public var key: String

    public init(modifiers: RecordingShortcutModifiers, key: String) {
        self.modifiers = modifiers
        self.key = Self.normalizedKey(key)
    }

    public var displayText: String {
        modifiers.symbols + key.uppercased()
    }

    public var isValid: Bool {
        Self.availableKeys.contains(key.uppercased())
    }

    public static let availableKeys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    private static func normalizedKey(_ key: String) -> String {
        let normalized = key.uppercased()
        return availableKeys.contains(normalized) ? normalized : "M"
    }
}

public struct RecordingShortcutSet: Codable, Hashable, Sendable {
    public var audio: RecordingKeyboardShortcut
    public var screen: RecordingKeyboardShortcut
    public var camera: RecordingKeyboardShortcut

    public init(
        audio: RecordingKeyboardShortcut,
        screen: RecordingKeyboardShortcut,
        camera: RecordingKeyboardShortcut
    ) {
        self.audio = audio
        self.screen = screen
        self.camera = camera
    }

    public subscript(mode: RecordingMode) -> RecordingKeyboardShortcut {
        get {
            switch mode {
            case .audio: audio
            case .screen: screen
            case .camera: camera
            }
        }
        set {
            switch mode {
            case .audio: audio = newValue
            case .screen: screen = newValue
            case .camera: camera = newValue
            }
        }
    }

    public var hasUniqueShortcuts: Bool {
        audio.isValid
            && screen.isValid
            && camera.isValid
            && Set([audio, screen, camera]).count == 3
    }

    public static let defaults = RecordingShortcutSet(
        audio: RecordingKeyboardShortcut(modifiers: .commandOption, key: "M"),
        screen: RecordingKeyboardShortcut(modifiers: .commandOption, key: "N"),
        camera: RecordingKeyboardShortcut(modifiers: .commandOption, key: "B")
    )
}

public enum RecorderShortcutPreferences {
    public static let shortcutSetKey = "GlobalRecordingShortcuts"
    public static let audioSystemAudioKey = "ShortcutAudioIncludesSystemAudio"
    public static let screenSystemAudioKey = "ShortcutScreenIncludesSystemAudio"
    public static let screenMicrophoneKey = "ShortcutScreenIncludesMicrophone"

    public static func shortcuts(
        defaults: UserDefaults = .standard
    ) -> RecordingShortcutSet {
        guard let data = defaults.data(forKey: shortcutSetKey),
              let shortcuts = try? JSONDecoder().decode(
                RecordingShortcutSet.self,
                from: data
              ),
              shortcuts.hasUniqueShortcuts else {
            return .defaults
        }
        return shortcuts
    }

    public static func save(
        shortcuts: RecordingShortcutSet,
        defaults: UserDefaults = .standard
    ) throws {
        guard shortcuts.hasUniqueShortcuts else {
            throw ShortcutPreferenceError.duplicateShortcuts
        }
        defaults.set(
            try JSONEncoder().encode(shortcuts),
            forKey: shortcutSetKey
        )
    }

    public static func action(
        activeMode: RecordingMode?,
        requestedMode: RecordingMode
    ) -> ShortcutRecordingAction {
        guard let activeMode else { return .start }
        return activeMode == requestedMode
            ? .stop
            : .blocked(activeMode: activeMode)
    }

    public static func configuration(
        for mode: RecordingMode,
        defaults: UserDefaults = .standard,
        microphones: [MediaDevice] = DeviceCatalog.microphones(),
        cameras: [MediaDevice] = DeviceCatalog.cameras()
    ) -> CaptureConfiguration {
        let microphoneID = DeviceCatalog.preferredMicrophoneID(in: microphones)
        switch mode {
        case .audio:
            return CaptureConfiguration(
                mode: .audio,
                microphoneID: microphoneID,
                capturesSystemAudio: bool(
                    defaults,
                    key: audioSystemAudioKey,
                    defaultValue: false
                ),
                capturesMicrophone: true
            )
        case .screen:
            return CaptureConfiguration(
                mode: .screen,
                microphoneID: microphoneID,
                displayID: nil,
                screenTarget: .display,
                capturesSystemAudio: bool(
                    defaults,
                    key: screenSystemAudioKey,
                    defaultValue: true
                ),
                capturesMicrophone: bool(
                    defaults,
                    key: screenMicrophoneKey,
                    defaultValue: true
                ),
                width: 1920,
                height: 1080,
                framesPerSecond: 30
            )
        case .camera:
            return CaptureConfiguration(
                mode: .camera,
                microphoneID: microphoneID,
                cameraID: DeviceCatalog.preferredCameraID(in: cameras),
                capturesSystemAudio: false,
                capturesMicrophone: true,
                width: 1920,
                height: 1080,
                framesPerSecond: 30
            )
        }
    }

    private static func bool(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

public enum ShortcutPreferenceError: LocalizedError {
    case duplicateShortcuts

    public var errorDescription: String? {
        "Each recording mode must use a different shortcut."
    }
}
