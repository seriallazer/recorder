import Foundation
import AVFoundation

public struct NativeMediaFinalizer: MediaFinalizing {
    public init() {}

    public func finalize(
        artifacts: CaptureArtifacts,
        configuration: CaptureConfiguration,
        destinationDirectory: URL
    ) async throws -> FinalizedMedia {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        switch configuration.mode {
        case .audio:
            let mediaURL = destinationDirectory.appendingPathComponent("recording.m4a")
            try replaceCopy(from: artifacts.primaryMediaURL, to: mediaURL)
            let duration = try await mediaDuration(mediaURL)
            return FinalizedMedia(
                mediaURL: mediaURL,
                audioURL: mediaURL,
                microphoneStemURL: mediaURL,
                systemStemURL: nil,
                duration: duration
            )

        case .camera:
            let mediaURL = destinationDirectory.appendingPathComponent("recording.mov")
            let audioURL = destinationDirectory.appendingPathComponent("audio.m4a")
            try replaceCopy(from: artifacts.primaryMediaURL, to: mediaURL)
            let duration = try await mediaDuration(mediaURL)
            do {
                try await exportAudio(from: mediaURL, to: audioURL)
            } catch RecorderError.missingMedia {
                return FinalizedMedia(
                    mediaURL: mediaURL,
                    audioURL: mediaURL,
                    microphoneStemURL: nil,
                    systemStemURL: nil,
                    duration: duration
                )
            }
            return FinalizedMedia(
                mediaURL: mediaURL,
                audioURL: audioURL,
                microphoneStemURL: audioURL,
                systemStemURL: nil,
                duration: duration
            )

        case .screen:
            let mediaURL = destinationDirectory.appendingPathComponent("recording.mov")
            let audioURL = destinationDirectory.appendingPathComponent("audio.m4a")
            let systemURL = destinationDirectory.appendingPathComponent("system.m4a")
            let microphoneURL = destinationDirectory.appendingPathComponent("microphone.m4a")

            var finalizedMicrophoneURL: URL?
            if let mic = artifacts.microphoneStemURL,
               fileManager.fileExists(atPath: mic.path),
               try await hasAudioTrack(mic) {
                try replaceCopy(from: mic, to: microphoneURL)
                finalizedMicrophoneURL = microphoneURL
            }
            var finalizedSystemURL: URL?
            if configuration.capturesSystemAudio {
                do {
                    try await exportAudio(from: artifacts.primaryMediaURL, to: systemURL)
                    finalizedSystemURL = systemURL
                } catch RecorderError.missingMedia {
                    // A silent source may produce no system-audio samples. The
                    // screen video is still valid and must be preserved.
                }
            }

            if let finalizedMicrophoneURL {
                try await mixScreenMedia(
                    videoURL: artifacts.primaryMediaURL,
                    microphoneURL: finalizedMicrophoneURL,
                    destinationURL: mediaURL
                )
            } else {
                try replaceCopy(from: artifacts.primaryMediaURL, to: mediaURL)
            }

            let duration = try await mediaDuration(mediaURL)
            let finalizedAudioURL: URL
            do {
                try await exportAudio(from: mediaURL, to: audioURL)
                finalizedAudioURL = audioURL
            } catch RecorderError.missingMedia {
                finalizedAudioURL = mediaURL
            }
            return FinalizedMedia(
                mediaURL: mediaURL,
                audioURL: finalizedAudioURL,
                microphoneStemURL: finalizedMicrophoneURL,
                systemStemURL: finalizedSystemURL,
                duration: duration
            )
        }
    }

    public func exportTrimmed(
        sourceURL: URL,
        destinationURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws {
        guard endTime > startTime else {
            throw RecorderError.finalizationFailed("The trim end must be after the trim start.")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.finalizationFailed("A trim exporter could not be created.")
        }
        let type: AVFileType = destinationURL.pathExtension.lowercased() == "m4a" ? .m4a : .mov
        exporter.outputURL = destinationURL
        exporter.outputFileType = type
        exporter.shouldOptimizeForNetworkUse = false
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )
        try await exporter.exportAsync()
    }

    private func mixScreenMedia(videoURL: URL, microphoneURL: URL, destinationURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let micAsset = AVURLAsset(url: microphoneURL)
        let composition = AVMutableComposition()
        let duration = try await videoAsset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        if let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try targetVideo.insertTimeRange(fullRange, of: sourceVideo, at: .zero)
            targetVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }

        var audioParameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudio in try await videoAsset.loadTracks(withMediaType: .audio) {
            if let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try target.insertTimeRange(fullRange, of: sourceAudio, at: .zero)
                let parameters = AVMutableAudioMixInputParameters(track: target)
                parameters.setVolume(1, at: .zero)
                audioParameters.append(parameters)
            }
        }

        if let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let micDuration = try await micAsset.load(.duration)
            let insertedDuration = CMTimeMinimum(duration, micDuration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: insertedDuration), of: micTrack, at: .zero)
            let parameters = AVMutableAudioMixInputParameters(track: target)
            parameters.setVolume(1, at: .zero)
            audioParameters.append(parameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.finalizationFailed("The screen recording could not be mixed.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mov
        exporter.audioMix = audioMix
        try await exporter.exportAsync()
    }

    private func exportAudio(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw RecorderError.missingMedia
        }
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.finalizationFailed("The audio companion could not be created.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .m4a
        try await exporter.exportAsync()
    }

    private func mediaDuration(_ url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return max(0, duration.seconds)
    }

    private func hasAudioTrack(_ url: URL) async throws -> Bool {
        !(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty
    }

    private func replaceCopy(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                if self.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.error ?? RecorderError.finalizationFailed("The media export did not complete."))
                }
            }
        }
    }
}
