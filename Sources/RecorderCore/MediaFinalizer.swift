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
            let microphoneURL = destinationDirectory.appendingPathComponent("microphone.m4a")
            let systemURL = destinationDirectory.appendingPathComponent("system.m4a")

            let microphoneSource: URL? = if let microphone = artifacts.microphoneStemURL,
               fileManager.fileExists(atPath: microphone.path),
               try await hasAudioTrack(microphone) {
                microphone
            } else {
                nil
            }
            let systemSource: URL? = if let system = artifacts.systemStemURL,
               fileManager.fileExists(atPath: system.path),
               try await hasAudioTrack(system) {
                system
            } else {
                nil
            }

            let finalizedMicrophoneURL: URL?
            let finalizedSystemURL: URL?
            if let microphoneSource, let systemSource {
                try replaceCopy(from: microphoneSource, to: microphoneURL)
                try replaceCopy(from: systemSource, to: systemURL)
                try await mixAudioTracks(
                    [microphoneURL, systemURL],
                    destinationURL: mediaURL
                )
                finalizedMicrophoneURL = microphoneURL
                finalizedSystemURL = systemURL
            } else if let microphoneSource {
                try replaceCopy(from: microphoneSource, to: mediaURL)
                finalizedMicrophoneURL = mediaURL
                finalizedSystemURL = nil
            } else if let systemSource {
                try replaceCopy(from: systemSource, to: mediaURL)
                finalizedMicrophoneURL = nil
                finalizedSystemURL = mediaURL
            } else {
                try replaceCopy(from: artifacts.primaryMediaURL, to: mediaURL)
                finalizedMicrophoneURL = configuration.capturesMicrophone ? mediaURL : nil
                finalizedSystemURL = configuration.capturesSystemAudio ? mediaURL : nil
            }
            let duration = try await mediaDuration(mediaURL)
            return FinalizedMedia(
                mediaURL: mediaURL,
                audioURL: mediaURL,
                microphoneStemURL: finalizedMicrophoneURL,
                systemStemURL: finalizedSystemURL,
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

    private func mixAudioTracks(_ sourceURLs: [URL], destinationURL: URL) async throws {
        let composition = AVMutableComposition()
        for sourceURL in sourceURLs {
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let targetTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let duration = try await asset.load(.duration)
            try targetTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }
        guard !(try await composition.loadTracks(withMediaType: .audio)).isEmpty else {
            throw RecorderError.missingMedia
        }
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.finalizationFailed("The microphone and system audio could not be mixed.")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .m4a
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
