import Foundation

public enum ShortcutRecordingMode: String, CaseIterable, Identifiable, Sendable {
    case audio
    case screen

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .audio: "Audio"
        case .screen: "Entire Screen"
        }
    }
}

public enum RecorderShortcutPreferences {
    public static let modeKey = "ShortcutRecordingMode"
    public static let audioSystemAudioKey = "ShortcutAudioIncludesSystemAudio"
    public static let screenSystemAudioKey = "ShortcutScreenIncludesSystemAudio"
    public static let screenMicrophoneKey = "ShortcutScreenIncludesMicrophone"

    public static func mode(defaults: UserDefaults = .standard) -> ShortcutRecordingMode {
        defaults.string(forKey: modeKey)
            .flatMap(ShortcutRecordingMode.init(rawValue:))
            ?? .audio
    }

    public static func configuration(
        defaults: UserDefaults = .standard,
        microphones: [MediaDevice] = DeviceCatalog.microphones()
    ) -> CaptureConfiguration {
        let selectedMode = mode(defaults: defaults)
        let microphoneID = DeviceCatalog.preferredMicrophoneID(in: microphones)
        switch selectedMode {
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
