import XCTest
import AVFoundation
@testable import RecorderCore

final class ScreenEchoCleanupTests: XCTestCase {
    func testDetectsDelayedSystemLeakageInMicrophone() throws {
        let sampleRate = 250.0
        let delayFrames = 21
        let system = speechLikeSamples(count: 2_000, seed: 17)
        var microphone = speechLikeSamples(count: system.count, seed: 91).map { $0 * 0.08 }
        for index in 0..<(system.count - delayFrames) {
            microphone[index + delayFrames] += system[index] * 0.65
        }

        let result = try XCTUnwrap(ScreenEchoCleanupAnalyzer.detectedDelay(
            systemSamples: system,
            microphoneSamples: microphone,
            sampleRate: sampleRate
        ))

        XCTAssertEqual(result.delay, 0.084, accuracy: 0.005)
        XCTAssertGreaterThan(result.correlation, 0.8)
    }

    func testUnrelatedMicrophoneDoesNotLookLikeEcho() throws {
        let system = speechLikeSamples(count: 2_000, seed: 3)
        let microphone = speechLikeSamples(count: 2_000, seed: 811)
        let result = try XCTUnwrap(ScreenEchoCleanupAnalyzer.detectedDelay(
            systemSamples: system,
            microphoneSamples: microphone,
            sampleRate: 250
        ))

        XCTAssertLessThan(result.correlation, 0.28)
    }

    func testDuckingIntervalsTrackSystemSpeechAndApplyDelay() {
        let rms: [Float] = [0, 0, 0.04, 0.05, 0.04, 0, 0, 0, 0, 0, 0.05, 0.04, 0.04, 0]
        let intervals = ScreenEchoCleanupAnalyzer.duckingIntervals(
            rmsFrames: rms,
            frameDuration: 0.1,
            delay: 0.08,
            totalDuration: 2
        )

        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, 0.28, accuracy: 0.001)
        XCTAssertEqual(intervals[0].end, 0.58, accuracy: 0.001)
        XCTAssertEqual(intervals[1].start, 1.08, accuracy: 0.001)
        XCTAssertEqual(intervals[1].end, 1.38, accuracy: 0.001)
    }

    func testAutomaticScreenCleanupPreservesOriginalsAndReturnsPlayableMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let working = root.appendingPathComponent("working", isDirectory: true)
        let destination = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleRate = 48_000.0
        let duration = 10.0
        let frameCount = Int(sampleRate * duration)
        let delayFrames = Int(sampleRate * 0.083)
        let lowRateSystem = speechLikeSamples(count: Int(duration * 1_000), seed: 27)
        var system = [Float](repeating: 0, count: frameCount)
        var microphone = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let source = lowRateSystem[min(lowRateSystem.count - 1, frame / 48)] * 0.35
            system[frame] = source
            microphone[frame] = Float(sin(2 * .pi * 317 * Double(frame) / sampleRate)) * 0.015
            if frame >= delayFrames {
                microphone[frame] += system[frame - delayFrames] * 0.6
            }
        }

        let systemURL = working.appendingPathComponent("system.m4a")
        let microphoneURL = working.appendingPathComponent("microphone.m4a")
        try write(samples: system, to: systemURL, sampleRate: sampleRate)
        try write(samples: microphone, to: microphoneURL, sampleRate: sampleRate)

        let finalized = try await NativeMediaFinalizer().finalize(
            artifacts: CaptureArtifacts(
                primaryMediaURL: systemURL,
                microphoneStemURL: microphoneURL,
                echoCancellationApplied: false
            ),
            configuration: CaptureConfiguration(
                mode: .screen,
                capturesSystemAudio: true,
                capturesMicrophone: true,
                echoCancellationMode: .automatic
            ),
            destinationDirectory: destination
        )

        XCTAssertEqual(finalized.echoCancellationApplied, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recording.pre-echo-cleanup.mov").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("microphone.pre-echo-cleanup.m4a").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("audio.pre-echo-cleanup.m4a").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(finalized.microphoneStemURL).path))
        XCTAssertGreaterThan(finalized.duration, 9.5)
        let audioTracks = try await AVURLAsset(url: finalized.mediaURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    func testAutomaticScreenCleanupLeavesUnrelatedTracksUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let working = root.appendingPathComponent("working", isDirectory: true)
        let destination = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 2)
        let system = (0..<frameCount).map {
            Float(sin(2 * .pi * 431 * Double($0) / sampleRate)) * 0.08
        }
        let microphone = (0..<frameCount).map {
            Float(sin(2 * .pi * 719 * Double($0) / sampleRate)) * 0.08
        }
        let systemURL = working.appendingPathComponent("system.m4a")
        let microphoneURL = working.appendingPathComponent("microphone.m4a")
        try write(samples: system, to: systemURL, sampleRate: sampleRate)
        try write(samples: microphone, to: microphoneURL, sampleRate: sampleRate)

        let finalized = try await NativeMediaFinalizer().finalize(
            artifacts: CaptureArtifacts(
                primaryMediaURL: systemURL,
                microphoneStemURL: microphoneURL,
                echoCancellationApplied: false
            ),
            configuration: CaptureConfiguration(
                mode: .screen,
                capturesSystemAudio: true,
                capturesMicrophone: true,
                echoCancellationMode: .automatic
            ),
            destinationDirectory: destination
        )

        XCTAssertEqual(finalized.echoCancellationApplied, false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("recording.pre-echo-cleanup.mov").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.mediaURL.path))
    }

    private func speechLikeSamples(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        var samples = [Float](repeating: 0, count: count)
        var value: Float = 0
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let random = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            value = value * 0.82 + random * 0.18
            let withinSpeechBurst = (index / 700).isMultiple(of: 2)
            samples[index] = withinSpeechBurst ? value * 0.22 : 0
        }
        return samples
    }

    private func write(samples: [Float], to url: URL, sampleRate: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
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
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let destination = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            destination[index] = sample
        }
        try file.write(from: buffer)
    }
}
