import Foundation
@preconcurrency import AVFoundation
import AppKit

enum ThumbnailGenerator {
    static func jpegData(for mediaURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: mediaURL)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        // Unlimited tolerance can return the first keyframe even when a later
        // time was requested. Camera warm-up frames are commonly dark.
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var bestImage: CGImage?
        var bestScore = -Double.infinity
        var firstError: Error?
        for time in candidateTimes(duration: duration) {
            do {
                let image = try await generator.image(at: time).image
                let score = qualityScore(of: image)
                if score > bestScore {
                    bestImage = image
                    bestScore = score
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        guard let bestImage else {
            throw firstError ?? RecorderError.finalizationFailed("No video frame was available for the thumbnail.")
        }
        let bitmap = NSBitmapImageRep(cgImage: bestImage)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else {
            throw RecorderError.finalizationFailed("The thumbnail image could not be encoded.")
        }
        return data
    }

    static func candidateTimes(duration: CMTime) -> [CMTime] {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return [.zero] }
        if seconds < 1 {
            return [CMTime(seconds: seconds / 2, preferredTimescale: 600)]
        }

        let lastUsableTime = max(0.1, seconds - 0.1)
        let fractions = [0.15, 0.35, 0.6, 0.85]
        return fractions.map { fraction in
            CMTime(
                seconds: min(lastUsableTime, max(0.25, seconds * fraction)),
                preferredTimescale: 600
            )
        }
    }

    static func qualityScore(of image: CGImage) -> Double {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return 0 }

        let xStep = max(1, width / 32)
        let yStep = max(1, height / 18)
        var count = 0.0
        var sum = 0.0
        var squaredSum = 0.0
        for y in stride(from: 0, to: height, by: yStep) {
            for x in stride(from: 0, to: width, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                count += 1
                sum += luminance
                squaredSum += luminance * luminance
            }
        }
        guard count > 0 else { return 0 }

        let mean = sum / count
        let variance = max(0, squaredSum / count - mean * mean)
        let contrast = sqrt(variance)
        // Dark frames remain below 1. Any normally exposed frame wins, with
        // contrast favored so a blank white screen is not the default choice.
        guard mean >= 0.08 else { return mean }
        return 1 + contrast * 2 + min(mean, 0.7) * 0.2
    }
}
