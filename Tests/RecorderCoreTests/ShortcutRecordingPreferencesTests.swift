import XCTest
@testable import RecorderCore

final class ShortcutRecordingPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutRecordingPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToMicrophoneOnlyAudioUsingPreferredInternalMicrophone() {
        let configuration = RecorderShortcutPreferences.configuration(
            for: .audio,
            defaults: defaults,
            microphones: microphones
        )

        XCTAssertEqual(configuration.mode, .audio)
        XCTAssertEqual(configuration.microphoneID, "internal")
        XCTAssertTrue(configuration.capturesMicrophone)
        XCTAssertFalse(configuration.capturesSystemAudio)
    }

    func testDefaultShortcutMappingsUseCommandOptionMNB() {
        let shortcuts = RecorderShortcutPreferences.shortcuts(defaults: defaults)

        XCTAssertEqual(shortcuts.audio.displayText, "⌘⌥M")
        XCTAssertEqual(shortcuts.screen.displayText, "⌘⌥N")
        XCTAssertEqual(shortcuts.camera.displayText, "⌘⌥B")
        XCTAssertTrue(shortcuts.hasUniqueShortcuts)
    }

    func testCustomShortcutMappingsRoundTripAtomically() throws {
        let custom = RecordingShortcutSet(
            audio: RecordingKeyboardShortcut(modifiers: .commandShift, key: "A"),
            screen: RecordingKeyboardShortcut(modifiers: .controlOption, key: "S"),
            camera: RecordingKeyboardShortcut(modifiers: .commandControl, key: "V")
        )

        try RecorderShortcutPreferences.save(shortcuts: custom, defaults: defaults)

        XCTAssertEqual(
            RecorderShortcutPreferences.shortcuts(defaults: defaults),
            custom
        )
    }

    func testDuplicateShortcutMappingsCannotBeSaved() {
        let duplicate = RecordingKeyboardShortcut(
            modifiers: .commandOption,
            key: "M"
        )
        let shortcuts = RecordingShortcutSet(
            audio: duplicate,
            screen: duplicate,
            camera: RecordingKeyboardShortcut(modifiers: .commandOption, key: "B")
        )

        XCTAssertFalse(shortcuts.hasUniqueShortcuts)
        XCTAssertThrowsError(
            try RecorderShortcutPreferences.save(
                shortcuts: shortcuts,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            RecorderShortcutPreferences.shortcuts(defaults: defaults),
            .defaults
        )
    }

    func testShortcutStartsOnlyWhenNoRecordingIsActive() {
        XCTAssertEqual(
            RecorderShortcutPreferences.action(
                activeMode: nil,
                requestedMode: .screen
            ),
            .start
        )
    }

    func testMatchingShortcutStopsItsActiveRecording() {
        for mode in RecordingMode.allCases {
            XCTAssertEqual(
                RecorderShortcutPreferences.action(
                    activeMode: mode,
                    requestedMode: mode
                ),
                .stop
            )
        }
    }

    func testDifferentShortcutCannotStopOrReplaceActiveRecording() {
        XCTAssertEqual(
            RecorderShortcutPreferences.action(
                activeMode: .audio,
                requestedMode: .screen
            ),
            .blocked(activeMode: .audio)
        )
        XCTAssertEqual(
            RecorderShortcutPreferences.action(
                activeMode: .screen,
                requestedMode: .camera
            ),
            .blocked(activeMode: .screen)
        )
        XCTAssertEqual(
            RecorderShortcutPreferences.action(
                activeMode: .camera,
                requestedMode: .audio
            ),
            .blocked(activeMode: .camera)
        )
    }

    func testScreenDefaultsCaptureEntireDisplayWithSystemAndMicrophoneAudio() {
        let configuration = RecorderShortcutPreferences.configuration(
            for: .screen,
            defaults: defaults,
            microphones: microphones
        )

        XCTAssertEqual(configuration.mode, .screen)
        XCTAssertEqual(configuration.screenTarget, .display)
        XCTAssertNil(configuration.displayID)
        XCTAssertTrue(configuration.capturesSystemAudio)
        XCTAssertTrue(configuration.capturesMicrophone)
        XCTAssertEqual(configuration.microphoneID, "internal")
        XCTAssertEqual(configuration.width, 1_920)
        XCTAssertEqual(configuration.height, 1_080)
        XCTAssertEqual(configuration.framesPerSecond, 30)
    }

    func testPersistedAudioOptionsAreHonored() {
        defaults.set(true, forKey: RecorderShortcutPreferences.audioSystemAudioKey)
        var configuration = RecorderShortcutPreferences.configuration(
            for: .audio,
            defaults: defaults,
            microphones: microphones
        )
        XCTAssertTrue(configuration.capturesSystemAudio)

        defaults.set(false, forKey: RecorderShortcutPreferences.screenSystemAudioKey)
        defaults.set(false, forKey: RecorderShortcutPreferences.screenMicrophoneKey)
        configuration = RecorderShortcutPreferences.configuration(
            for: .screen,
            defaults: defaults,
            microphones: microphones
        )
        XCTAssertFalse(configuration.capturesSystemAudio)
        XCTAssertFalse(configuration.capturesMicrophone)
    }

    func testMovieUsesPreferredInternalCameraAndMicrophone() {
        let configuration = RecorderShortcutPreferences.configuration(
            for: .camera,
            defaults: defaults,
            microphones: microphones,
            cameras: [
                MediaDevice(id: "external-camera", name: "USB Camera"),
                MediaDevice(id: "internal-camera", name: "FaceTime HD Camera")
            ]
        )

        XCTAssertEqual(configuration.mode, .camera)
        XCTAssertEqual(configuration.cameraID, "internal-camera")
        XCTAssertEqual(configuration.microphoneID, "internal")
        XCTAssertTrue(configuration.capturesMicrophone)
        XCTAssertFalse(configuration.capturesSystemAudio)
        XCTAssertEqual(configuration.width, 1_920)
        XCTAssertEqual(configuration.height, 1_080)
        XCTAssertEqual(configuration.framesPerSecond, 30)
    }

    private var microphones: [MediaDevice] {
        [
            MediaDevice(id: "usb", name: "USB Microphone"),
            MediaDevice(id: "internal", name: "MacBook Air Microphone")
        ]
    }
}
