import Foundation

public enum ShortcutRecordingAction: Equatable, Sendable {
    case start
    case stop
    case blocked(activeMode: RecordingMode)
}

public enum RecorderShortcutPreferences {
    public static let audioSystemAudioKey = "ShortcutAudioIncludesSystemAudio"
    public static let screenSystemAudioKey = "ShortcutScreenIncludesSystemAudio"
    public static let screenMicrophoneKey = "ShortcutScreenIncludesMicrophone"

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
