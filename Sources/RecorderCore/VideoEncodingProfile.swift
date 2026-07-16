import Foundation

enum VideoEncodingProfile {
    static func averageBitRate(width: Int, height: Int, framesPerSecond: Int) -> Int {
        let pixelCount = max(1, width) * max(1, height)
        let baseBitRate: Double
        switch pixelCount {
        case ...(1280 * 720):
            baseBitRate = 2_500_000
        case ...(1920 * 1080):
            baseBitRate = 4_000_000
        default:
            baseBitRate = 7_000_000
        }

        let frameRateMultiplier: Double
        if framesPerSecond > 30 {
            frameRateMultiplier = 1.75
        } else if framesPerSecond <= 24 {
            frameRateMultiplier = 0.9
        } else {
            frameRateMultiplier = 1
        }
        return Int(baseBitRate * frameRateMultiplier)
    }
}
