import XCTest
import AVFoundation
@testable import RecorderCore

final class AudioFinalizerTests: XCTestCase {
    func testMeetingAudioPreservesStemsAndCreatesPlayableMix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let working = root.appendingPathComponent("working")
        let destination = root.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let microphone = working.appendingPathComponent("microphone.m4a")
        let system = working.appendingPathComponent("system.m4a")
        try writeTone(to: microphone, frequency: 440)
        try writeTone(to: system, frequency: 660)

        let finalized = try await NativeMediaFinalizer().finalize(
            artifacts: CaptureArtifacts(
                primaryMediaURL: microphone,
                microphoneStemURL: microphone,
                systemStemURL: system,
                echoCancellationApplied: true
            ),
            configuration: CaptureConfiguration(
                mode: .audio,
                capturesSystemAudio: true,
                capturesMicrophone: true
            ),
            destinationDirectory: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(finalized.microphoneStemURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(finalized.systemStemURL).path))
        XCTAssertGreaterThan(finalized.duration, 0.9)
        XCTAssertEqual(finalized.echoCancellationApplied, true)
        let tracks = try await AVURLAsset(url: finalized.mediaURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
    }

    func testMicrophoneOnlyAudioDoesNotDuplicateStem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let microphone = root.appendingPathComponent("microphone.m4a")
        let destination = root.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTone(to: microphone, frequency: 440)

        let finalized = try await NativeMediaFinalizer().finalize(
            artifacts: CaptureArtifacts(primaryMediaURL: microphone, microphoneStemURL: microphone),
            configuration: CaptureConfiguration(
                mode: .audio,
                capturesSystemAudio: false,
                capturesMicrophone: true
            ),
            destinationDirectory: destination
        )

        XCTAssertEqual(finalized.microphoneStemURL, finalized.mediaURL)
        XCTAssertNil(finalized.systemStemURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("microphone.m4a").path))
    }

    func testTrimmedExportUsesRequestedTimeRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let destination = root.appendingPathComponent("trimmed.m4a")
        try writeTone(to: source, frequency: 440, duration: 2)

        try await NativeMediaFinalizer().exportTrimmed(
            sourceURL: source,
            destinationURL: destination,
            startTime: 0.5,
            endTime: 1.25
        )

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 0.75, accuracy: 0.08)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    private func writeTone(to url: URL, frequency: Double, duration: Double = 1) throws {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.1)
        }
        try file.write(from: buffer)
    }
}
