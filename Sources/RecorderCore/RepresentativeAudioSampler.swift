import Foundation
@preconcurrency import AVFoundation

struct RepresentativeAudioSample: Sendable {
    var url: URL
    var isTemporary: Bool

    func removeIfNeeded() {
        if isTemporary { try? FileManager.default.removeItem(at: url) }
    }
}

struct RepresentativeSampleRange: Hashable, Sendable {
    var start: TimeInterval
    var duration: TimeInterval
}

enum RepresentativeAudioSampler {
    static let segmentDuration: TimeInterval = 20
    static let segmentCount = 8

    static func makeSample(from sourceURL: URL) async throws -> RepresentativeAudioSample {
        let asset = AVURLAsset(url: sourceURL)
        let duration = max(0, try await asset.load(.duration).seconds)
        let ranges = candidateRanges(for: duration)
        guard ranges.count > 1,
              let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return RepresentativeAudioSample(url: sourceURL, isTemporary: false)
        }

        let composition = AVMutableComposition()
        guard let destinationTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.transcriptionFailed("A representative audio sample could not be created.")
        }

        var insertionTime = CMTime.zero
        for range in ranges {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 600),
                duration: CMTime(seconds: range.duration, preferredTimescale: 600)
            )
            try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: insertionTime)
            insertionTime = insertionTime + timeRange.duration
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderSpeakerSample-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.transcriptionFailed("A representative audio sample could not be encoded.")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        do {
            try await export(exporter)
            return RepresentativeAudioSample(url: outputURL, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func candidateRanges(for duration: TimeInterval) -> [RepresentativeSampleRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        let totalSampleDuration = segmentDuration * Double(segmentCount)
        guard duration > totalSampleDuration + segmentDuration else {
            return [RepresentativeSampleRange(start: 0, duration: duration)]
        }

        return (0..<segmentCount).map { index in
            let fraction = 0.05 + (0.90 * Double(index) / Double(segmentCount - 1))
            let centeredStart = duration * fraction - segmentDuration / 2
            let start = min(max(0, centeredStart), duration - segmentDuration)
            return RepresentativeSampleRange(start: start, duration: segmentDuration)
        }
    }

    private static func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: exporter.error ?? RecorderError.transcriptionFailed(
                        "The representative audio sample could not be exported."
                    ))
                }
            }
        }
    }
}
