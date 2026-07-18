import XCTest
@testable import RecorderCore

final class DiarizationTests: XCTestCase {
    func testStableAudioPlanKeepsMicrophoneLabel() throws {
        let recording = makeRecording(mode: .audio, microphone: "recording.m4a")
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: .stable
        )

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].fixedSpeaker, "You")
        XCTAssertNil(tracks[0].expectedSpeakerCount)
    }

    func testEnhancedMixedAudioRequestsExpectedSpeakers() throws {
        let recording = makeRecording(mode: .audio, microphone: "recording.m4a")
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: DiarizationOptions(isEnabled: true, expectedSpeakerCount: 2)
        )

        XCTAssertNil(tracks[0].fixedSpeaker)
        XCTAssertEqual(tracks[0].fallbackSpeaker, "You")
        XCTAssertEqual(tracks[0].expectedSpeakerCount, 2)
    }

    func testTwoPartySeparateChannelsAvoidModelAndUseExactAttribution() throws {
        let recording = makeRecording(
            mode: .screen,
            microphone: "microphone.m4a",
            system: "system.m4a"
        )
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: DiarizationOptions(isEnabled: true, expectedSpeakerCount: 2)
        )

        XCTAssertEqual(tracks.map(\.fixedSpeaker), ["You", "Interviewer"])
        XCTAssertTrue(tracks.allSatisfy { $0.expectedSpeakerCount == nil })
    }

    func testPanelDiarizesOnlyRemoteSystemChannel() throws {
        let recording = makeRecording(
            mode: .screen,
            microphone: "microphone.m4a",
            system: "system.m4a"
        )
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: DiarizationOptions(isEnabled: true, expectedSpeakerCount: 3)
        )

        XCTAssertEqual(tracks[0].fixedSpeaker, "You")
        XCTAssertNil(tracks[1].fixedSpeaker)
        XCTAssertEqual(tracks[1].expectedSpeakerCount, 2)
        XCTAssertEqual(tracks[1].speakerPrefix, "Interviewer")
    }

    func testCrashSafeServiceTurnsHelperFailureIntoError() async throws {
        let service = CrashSafeDiarizationService(helperURL: URL(fileURLWithPath: "/usr/bin/false"))
        do {
            _ = try await service.diarize(URL(fileURLWithPath: "/tmp/audio.m4a"), expectedSpeakerCount: 2)
            XCTFail("Expected helper failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stable labels"))
        }
    }

    func testCrashSafeServiceContainsNativeHelperSignal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("crash.sh")
        try Data("#!/bin/sh\nkill -BUS $$\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let service = CrashSafeDiarizationService(helperURL: helper)
        do {
            _ = try await service.diarize(URL(fileURLWithPath: "/tmp/audio.m4a"), expectedSpeakerCount: 2)
            XCTFail("Expected isolated helper signal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stable labels"))
        }
    }

    func testCrashSafeServiceDecodesSuccessfulHelperOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.sh")
        let script = """
        #!/bin/sh
        printf '{"segments":[{"speaker":"S1","startTime":1.5,"endTime":3.0}]}' > "$2"
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let service = CrashSafeDiarizationService(helperURL: helper)
        let intervals = try await service.diarize(
            URL(fileURLWithPath: "/tmp/audio.m4a"),
            expectedSpeakerCount: 2
        )

        XCTAssertEqual(intervals, [SpeakerInterval(speaker: "S1", startTime: 1.5, endTime: 3)])
    }

    func testCancellingDiarizationTerminatesHelperWithoutFallingBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("slow.sh")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let service = CrashSafeDiarizationService(helperURL: helper)
        let task = Task {
            try await service.diarize(
                URL(fileURLWithPath: "/tmp/audio.m4a"),
                expectedSpeakerCount: 2
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeRecording(
        mode: RecordingMode,
        microphone: String?,
        system: String? = nil
    ) -> RecordingManifest {
        var recording = RecordingManifest(
            title: "Test",
            mode: mode,
            configuration: CaptureConfiguration(
                mode: mode,
                capturesSystemAudio: system != nil,
                capturesMicrophone: microphone != nil
            )
        )
        recording.audioFile = microphone ?? system
        recording.microphoneStemFile = microphone
        recording.systemStemFile = system
        return recording
    }
}
