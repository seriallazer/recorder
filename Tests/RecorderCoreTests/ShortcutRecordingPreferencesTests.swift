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
            defaults: defaults,
            microphones: microphones
        )

        XCTAssertEqual(RecorderShortcutPreferences.mode(defaults: defaults), .audio)
        XCTAssertEqual(configuration.mode, .audio)
        XCTAssertEqual(configuration.microphoneID, "internal")
        XCTAssertTrue(configuration.capturesMicrophone)
        XCTAssertFalse(configuration.capturesSystemAudio)
    }

    func testScreenDefaultsCaptureEntireDisplayWithSystemAndMicrophoneAudio() {
        defaults.set(
            ShortcutRecordingMode.screen.rawValue,
            forKey: RecorderShortcutPreferences.modeKey
        )

        let configuration = RecorderShortcutPreferences.configuration(
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
            defaults: defaults,
            microphones: microphones
        )
        XCTAssertTrue(configuration.capturesSystemAudio)

        defaults.set(
            ShortcutRecordingMode.screen.rawValue,
            forKey: RecorderShortcutPreferences.modeKey
        )
        defaults.set(false, forKey: RecorderShortcutPreferences.screenSystemAudioKey)
        defaults.set(false, forKey: RecorderShortcutPreferences.screenMicrophoneKey)
        configuration = RecorderShortcutPreferences.configuration(
            defaults: defaults,
            microphones: microphones
        )
        XCTAssertFalse(configuration.capturesSystemAudio)
        XCTAssertFalse(configuration.capturesMicrophone)
    }

    private var microphones: [MediaDevice] {
        [
            MediaDevice(id: "usb", name: "USB Microphone"),
            MediaDevice(id: "internal", name: "MacBook Air Microphone")
        ]
    }
}
