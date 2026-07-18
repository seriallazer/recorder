import XCTest
@testable import RecorderCore

final class DiarizationTests: XCTestCase {
    func testDefaultPreferencesUseAutomaticMode() {
        let suite = "RecorderDiarizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecorderPreferences.diarizationOptions(defaults: defaults).mode, .automatic)
    }

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

    func testAutomaticMixedAudioRequestsRepresentativeSampling() throws {
        let recording = makeRecording(mode: .audio, microphone: "recording.m4a")
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: .automatic
        )

        XCTAssertNil(tracks[0].fixedSpeaker)
        XCTAssertNil(tracks[0].expectedSpeakerCount)
        XCTAssertTrue(tracks[0].automaticallySelectSpeakers)
        XCTAssertEqual(tracks[0].automaticSingleSpeaker, "You")
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

    func testAutomaticSeparateChannelsSamplesOnlyRemoteTrack() throws {
        let recording = makeRecording(
            mode: .screen,
            microphone: "microphone.m4a",
            system: "system.m4a"
        )
        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: URL(fileURLWithPath: "/tmp/recording"),
            options: .automatic
        )

        XCTAssertEqual(tracks[0].fixedSpeaker, "You")
        XCTAssertFalse(tracks[0].automaticallySelectSpeakers)
        XCTAssertNil(tracks[1].fixedSpeaker)
        XCTAssertTrue(tracks[1].automaticallySelectSpeakers)
        XCTAssertEqual(tracks[1].automaticSingleSpeaker, "Interviewer")
    }

    func testMeaningfulSpeakerClassifierIgnoresTinyOutlier() {
        let intervals = [
            SpeakerInterval(speaker: "S1", startTime: 0, endTime: 100),
            SpeakerInterval(speaker: "S2", startTime: 100, endTime: 115),
            SpeakerInterval(speaker: "S3", startTime: 115, endTime: 117)
        ]

        XCTAssertEqual(SpeakerModeClassifier.meaningfulSpeakerCount(in: intervals), 2)
    }

    func testRepresentativeRangesAreDistributedAcrossLongAudio() {
        let ranges = RepresentativeAudioSampler.candidateRanges(for: 3_600)

        XCTAssertEqual(ranges.count, 8)
        XCTAssertTrue(ranges.allSatisfy { $0.duration == 20 })
        XCTAssertLessThan(ranges[0].start, 200)
        XCTAssertGreaterThan(ranges[7].start, 3_300)
    }

    func testShortAudioUsesWholeFileForAutomaticAnalysis() {
        XCTAssertEqual(
            RepresentativeAudioSampler.candidateRanges(for: 120),
            [RepresentativeSampleRange(start: 0, duration: 120)]
        )
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
        let temporaryPathMarker = directory.appendingPathComponent("temporary-path.txt")
        let script = """
        #!/bin/sh
        printf '%s' "$TMPDIR" > "$1"
        touch "$TMPDIR/native-crash-leftover"
        kill -BUS $$
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let service = CrashSafeDiarizationService(helperURL: helper)
        do {
            _ = try await service.diarize(temporaryPathMarker, expectedSpeakerCount: 2)
            XCTFail("Expected isolated helper signal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stable labels"))
        }
        let helperTemporaryPath = try String(contentsOf: temporaryPathMarker, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperTemporaryPath))
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
