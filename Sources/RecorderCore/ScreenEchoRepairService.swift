import Foundation
@preconcurrency import AVFoundation

public struct ScreenEchoRepairResult: Sendable, Equatable {
    public var applied: Bool
    public var alreadyClean: Bool
    public var detectedDelay: TimeInterval?
    public var confidence: Double?

    public init(
        applied: Bool,
        alreadyClean: Bool = false,
        detectedDelay: TimeInterval? = nil,
        confidence: Double? = nil
    ) {
        self.applied = applied
        self.alreadyClean = alreadyClean
        self.detectedDelay = detectedDelay
        self.confidence = confidence
    }
}

public struct ScreenEchoRepairService: Sendable {
    public init() {}

    public func repair(folder: URL) async throws -> ScreenEchoRepairResult {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder.recorder.decode(RecordingManifest.self, from: data)
        guard manifest.mode == .screen else {
            throw RecorderError.invalidState("Echo repair only supports screen recordings.")
        }
        guard manifest.state == .ready else {
            throw RecorderError.invalidState("Wait until recording and transcription work has finished.")
        }
        if manifest.echoCancellationApplied == true {
            return ScreenEchoRepairResult(applied: false, alreadyClean: true)
        }
        guard let recordingURL = manifest.fileURL(for: manifest.mediaFile, in: folder),
              let microphoneURL = manifest.fileURL(for: manifest.microphoneStemFile, in: folder),
              let systemURL = manifest.fileURL(for: manifest.systemStemFile, in: folder) else {
            throw RecorderError.missingMedia
        }
        let audioURL = manifest.fileURL(for: manifest.audioFile, in: folder)
            ?? folder.appendingPathComponent("audio.m4a")
        for url in [recordingURL, microphoneURL, systemURL] where !FileManager.default.fileExists(atPath: url.path) {
            throw RecorderError.missingMedia
        }

        guard let plan = try await ScreenEchoCleanupAnalyzer.makePlan(
            systemURL: systemURL,
            microphoneURL: microphoneURL
        ) else {
            return ScreenEchoRepairResult(applied: false)
        }
        try await ScreenEchoMediaProcessor.apply(
            plan: plan,
            sourceVideoURL: recordingURL,
            recordingURL: recordingURL,
            audioURL: audioURL,
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationDirectory: folder
        )

        manifest.echoCancellationApplied = true
        manifest.audioFile = audioURL.lastPathComponent
        manifest.updatedAt = Date()
        try JSONEncoder.recorder.encode(manifest).write(to: manifestURL, options: .atomic)
        return ScreenEchoRepairResult(
            applied: true,
            detectedDelay: plan.delay,
            confidence: plan.confidence
        )
    }
}

enum ScreenEchoMediaProcessor {
    static func apply(
        plan: ScreenEchoCleanupPlan,
        sourceVideoURL: URL,
        recordingURL: URL,
        audioURL: URL,
        microphoneURL: URL,
        systemURL: URL,
        destinationDirectory: URL
    ) async throws {
        let fileManager = FileManager.default
        let cleanedMicrophone = destinationDirectory.appendingPathComponent(".microphone.echo-cleaned.tmp.m4a")
        let cleanedRecording = destinationDirectory.appendingPathComponent(".recording.echo-cleaned.tmp.mov")
        let cleanedAudio = destinationDirectory.appendingPathComponent(".audio.echo-cleaned.tmp.m4a")
        let originalMicrophone = destinationDirectory.appendingPathComponent("microphone.pre-echo-cleanup.m4a")
        let originalRecording = destinationDirectory.appendingPathComponent("recording.pre-echo-cleanup.mov")
        let originalAudio = destinationDirectory.appendingPathComponent("audio.pre-echo-cleanup.m4a")
        defer {
            try? fileManager.removeItem(at: cleanedMicrophone)
            try? fileManager.removeItem(at: cleanedRecording)
            try? fileManager.removeItem(at: cleanedAudio)
        }

        try await exportDuckedMicrophone(
            sourceURL: microphoneURL,
            intervals: plan.duckingIntervals,
            destinationURL: cleanedMicrophone
        )
        try await mixScreenMedia(
            videoURL: sourceVideoURL,
            systemURL: systemURL,
            microphoneURL: cleanedMicrophone,
            destinationURL: cleanedRecording
        )
        try await exportAudio(from: cleanedRecording, to: cleanedAudio)

        let sourceHasVideo = try await hasVideoTrack(sourceVideoURL)
        let cleanedMicrophoneHasAudio = try await hasAudioTrack(cleanedMicrophone)
        let cleanedRecordingHasAudio = try await hasAudioTrack(cleanedRecording)
        let cleanedRecordingHasVideo = try await hasVideoTrack(cleanedRecording)
        guard cleanedMicrophoneHasAudio,
              cleanedRecordingHasAudio,
              !sourceHasVideo || cleanedRecordingHasVideo else {
            throw RecorderError.finalizationFailed("Automatic echo cleanup produced invalid media.")
        }

        try preserveCopyIfMissing(from: microphoneURL, to: originalMicrophone)
        try preserveCopyIfMissing(from: recordingURL, to: originalRecording)
        if fileManager.fileExists(atPath: audioURL.path) {
            try preserveCopyIfMissing(from: audioURL, to: originalAudio)
        } else {
            try? await exportAudio(from: originalRecording, to: originalAudio)
        }

        do {
            try replaceMove(from: cleanedMicrophone, to: microphoneURL)
            try replaceMove(from: cleanedRecording, to: recordingURL)
            try replaceMove(from: cleanedAudio, to: audioURL)
        } catch {
            try? replaceCopy(from: originalMicrophone, to: microphoneURL)
            try? replaceCopy(from: originalRecording, to: recordingURL)
            if fileManager.fileExists(atPath: originalAudio.path) {
                try? replaceCopy(from: originalAudio, to: audioURL)
            }
            throw error
        }
    }

    private static func exportDuckedMicrophone(
        sourceURL: URL,
        intervals: [EchoDuckingInterval],
        destinationURL: URL
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RecorderError.missingMedia
        }
        let composition = AVMutableComposition()
        guard let targetTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.finalizationFailed("The microphone cleanup track could not be created.")
        }
        try targetTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )

        let parameters = AVMutableAudioMixInputParameters(track: targetTrack)
        parameters.setVolume(1, at: .zero)
        let totalDuration = max(0, duration.seconds)
        for interval in intervals {
            let attackStart = max(0, interval.start - 0.04)
            let attackEnd = min(totalDuration, max(attackStart, interval.start + 0.004))
            let releaseStart = min(totalDuration, max(attackEnd, interval.end))
            let releaseEnd = min(totalDuration, releaseStart + 0.22)
            if attackEnd > attackStart {
                parameters.setVolumeRamp(
                    fromStartVolume: 1,
                    toEndVolume: 0.12,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: attackStart, preferredTimescale: 48_000),
                        end: CMTime(seconds: attackEnd, preferredTimescale: 48_000)
                    )
                )
            } else {
                parameters.setVolume(0.12, at: CMTime(seconds: attackStart, preferredTimescale: 48_000))
            }
            parameters.setVolume(0.12, at: CMTime(seconds: releaseStart, preferredTimescale: 48_000))
            if releaseEnd > releaseStart {
                parameters.setVolumeRamp(
                    fromStartVolume: 0.12,
                    toEndVolume: 1,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: releaseStart, preferredTimescale: 48_000),
                        end: CMTime(seconds: releaseEnd, preferredTimescale: 48_000)
                    )
                )
            }
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.finalizationFailed("The cleaned microphone audio could not be created.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .m4a
        exporter.audioMix = audioMix
        try await exporter.exportEchoRepair()
    }

    private static func mixScreenMedia(
        videoURL: URL,
        systemURL: URL,
        microphoneURL: URL,
        destinationURL: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        let videoDuration = try await videoAsset.load(.duration)

        if let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let targetVideo = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try targetVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: sourceVideo,
                at: .zero
            )
            targetVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }

        var parameters: [AVMutableAudioMixInputParameters] = []
        for sourceURL in [systemURL, microphoneURL] {
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let targetTrack = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let sourceDuration = try await asset.load(.duration)
            let duration = CMTimeMinimum(videoDuration, sourceDuration)
            try targetTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
            let input = AVMutableAudioMixInputParameters(track: targetTrack)
            input.setVolume(1, at: .zero)
            parameters.append(input)
        }
        guard !parameters.isEmpty else { throw RecorderError.missingMedia }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RecorderError.finalizationFailed("The cleaned screen recording could not be created.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mov
        exporter.audioMix = audioMix
        try await exporter.exportEchoRepair()
    }

    private static func exportAudio(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw RecorderError.missingMedia
        }
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.finalizationFailed("The cleaned audio companion could not be created.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .m4a
        try await exporter.exportEchoRepair()
    }

    private static func hasAudioTrack(_ url: URL) async throws -> Bool {
        !(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty
    }

    private static func hasVideoTrack(_ url: URL) async throws -> Bool {
        !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty
    }

    private static func preserveCopyIfMissing(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func replaceCopy(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func replaceMove(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

private extension AVAssetExportSession {
    func exportEchoRepair() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                if self.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.error ?? RecorderError.finalizationFailed(
                        "The echo-cleanup export did not complete."
                    ))
                }
            }
        }
    }
}
