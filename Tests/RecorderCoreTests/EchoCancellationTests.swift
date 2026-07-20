import XCTest
import AVFoundation
@testable import RecorderCore

final class EchoCancellationTests: XCTestCase {
    func testEchoCancellationDefaultsToAutomatic() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(
            RecorderPreferences.echoCancellationMode(defaults: defaults),
            .automatic
        )
    }

    func testEchoCancellationCanBeDisabled() {
        let defaults = isolatedDefaults()
        defaults.set(
            EchoCancellationMode.off.rawValue,
            forKey: RecorderPreferences.echoCancellationModeKey
        )
        XCTAssertEqual(
            RecorderPreferences.echoCancellationMode(defaults: defaults),
            .off
        )
    }

    func testAutomaticPolicyRequiresDualSourceCaptureAndDefaultMicrophone() {
        let eligible = CaptureConfiguration(
            mode: .screen,
            microphoneID: "default-mic",
            capturesSystemAudio: true,
            capturesMicrophone: true,
            echoCancellationMode: .automatic
        )
        XCTAssertTrue(EchoCancellationPolicy.shouldAttempt(
            configuration: eligible,
            defaultMicrophoneID: "default-mic"
        ))

        var configuration = eligible
        configuration.microphoneID = "external-mic"
        XCTAssertFalse(EchoCancellationPolicy.shouldAttempt(
            configuration: configuration,
            defaultMicrophoneID: "default-mic"
        ))

        configuration = eligible
        configuration.capturesSystemAudio = false
        XCTAssertFalse(EchoCancellationPolicy.shouldAttempt(
            configuration: configuration,
            defaultMicrophoneID: "default-mic"
        ))

        configuration = eligible
        configuration.echoCancellationMode = .off
        XCTAssertFalse(EchoCancellationPolicy.shouldAttempt(
            configuration: configuration,
            defaultMicrophoneID: "default-mic"
        ))
    }

    func testOlderCaptureConfigurationWithoutEchoFieldStillDecodes() throws {
        let original = CaptureConfiguration(
            mode: .screen,
            capturesSystemAudio: true,
            capturesMicrophone: true,
            echoCancellationMode: .automatic
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "echoCancellationMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            CaptureConfiguration.self,
            from: legacyData
        )
        XCTAssertNil(decoded.echoCancellationMode)
    }

    func testPCMBufferLevelMeterRecognizesVoiceLevelSignal() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)
        )
        buffer.frameLength = 1_024
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1_024 {
            samples[index] = sin(Float(index) * 0.1) * 0.1
        }

        XCTAssertGreaterThan(AudioLevelMeter.normalizedLevel(from: buffer), 0.5)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "EchoCancellationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
