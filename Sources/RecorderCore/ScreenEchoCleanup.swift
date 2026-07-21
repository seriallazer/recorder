import Foundation
@preconcurrency import AVFoundation
import Accelerate

struct EchoDuckingInterval: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

struct ScreenEchoCleanupPlan: Sendable, Equatable {
    var delay: TimeInterval
    var confidence: Double
    var duckingIntervals: [EchoDuckingInterval]
}

struct ScreenEchoDetection: Sendable, Equatable {
    var delay: TimeInterval
    var confidence: Double
}

enum ScreenEchoCleanupAnalyzer {
    // Preserve enough speech-band detail to correlate a room-filtered speaker
    // signal while Accelerate keeps the sliding analysis inexpensive.
    private static let analysisSampleRate = 1_000.0
    private static let maximumDelay = 0.5
    private static let windowDuration = 8.0

    static func makePlan(
        systemURL: URL,
        microphoneURL: URL
    ) async throws -> ScreenEchoCleanupPlan? {
        try await Task.detached(priority: .utility) {
            try makePlanSynchronously(systemURL: systemURL, microphoneURL: microphoneURL)
        }.value
    }

    static func detectedDelay(
        systemSamples: [Float],
        microphoneSamples: [Float],
        sampleRate: Double,
        maximumDelay: TimeInterval = 0.5
    ) -> (delay: TimeInterval, correlation: Double)? {
        guard systemSamples.count >= 200,
              microphoneSamples.count >= 200,
              sampleRate > 0 else { return nil }

        let system = centered(systemSamples)
        let microphone = centered(microphoneSamples)
        let maximumLag = min(
            Int((maximumDelay * sampleRate).rounded()),
            min(system.count, microphone.count) / 3
        )
        guard maximumLag > 0 else { return nil }

        var bestLag = 0
        var bestCorrelation = -Double.infinity
        for lag in (-maximumLag)...maximumLag {
            let systemStart = max(0, -lag)
            let microphoneStart = max(0, lag)
            let count = min(system.count - systemStart, microphone.count - microphoneStart)
            guard count >= 100 else { continue }

            var dot: Float = 0
            var systemEnergy: Float = 0
            var microphoneEnergy: Float = 0
            system.withUnsafeBufferPointer { systemBuffer in
                microphone.withUnsafeBufferPointer { microphoneBuffer in
                    guard let systemBase = systemBuffer.baseAddress,
                          let microphoneBase = microphoneBuffer.baseAddress else { return }
                    vDSP_dotpr(
                        systemBase.advanced(by: systemStart), 1,
                        microphoneBase.advanced(by: microphoneStart), 1,
                        &dot, vDSP_Length(count)
                    )
                    vDSP_svesq(
                        systemBase.advanced(by: systemStart), 1,
                        &systemEnergy, vDSP_Length(count)
                    )
                    vDSP_svesq(
                        microphoneBase.advanced(by: microphoneStart), 1,
                        &microphoneEnergy, vDSP_Length(count)
                    )
                }
            }
            let denominator = sqrt(Double(systemEnergy) * Double(microphoneEnergy))
            guard denominator > 1e-9 else { continue }
            let correlation = Double(dot) / denominator
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        guard bestCorrelation.isFinite else { return nil }
        return (Double(bestLag) / sampleRate, bestCorrelation)
    }

    static func duckingIntervals(
        rmsFrames: [Float],
        frameDuration: TimeInterval,
        delay: TimeInterval,
        totalDuration: TimeInterval
    ) -> [EchoDuckingInterval] {
        guard !rmsFrames.isEmpty, frameDuration > 0, totalDuration > 0 else { return [] }
        let peak = rmsFrames.max() ?? 0
        guard peak >= 0.008 else { return [] }
        let threshold = max(0.008, min(0.02, peak * 0.18))
        let minimumActiveFrames = max(1, Int((0.06 / frameDuration).rounded(.up)))
        let mergeGapFrames = max(1, Int((0.24 / frameDuration).rounded(.up)))

        var rawRanges: [Range<Int>] = []
        var activeStart: Int?
        var lastActive: Int?
        for (index, rms) in rmsFrames.enumerated() {
            if rms >= threshold {
                if activeStart == nil { activeStart = index }
                lastActive = index
            } else if let start = activeStart,
                      let last = lastActive,
                      index - last > mergeGapFrames {
                if last - start + 1 >= minimumActiveFrames {
                    rawRanges.append(start..<(last + 1))
                }
                activeStart = nil
                lastActive = nil
            }
        }
        if let start = activeStart, let last = lastActive,
           last - start + 1 >= minimumActiveFrames {
            rawRanges.append(start..<(last + 1))
        }

        return rawRanges.compactMap { range in
            let shiftedStart = Double(range.lowerBound) * frameDuration + delay
            let shiftedEnd = Double(range.upperBound) * frameDuration + delay
            let start = max(0, shiftedStart)
            let end = min(totalDuration, shiftedEnd)
            return end > start ? EchoDuckingInterval(start: start, end: end) : nil
        }
    }

    private static func makePlanSynchronously(
        systemURL: URL,
        microphoneURL: URL
    ) throws -> ScreenEchoCleanupPlan? {
        let systemFile = try AVAudioFile(forReading: systemURL)
        let microphoneFile = try AVAudioFile(forReading: microphoneURL)
        let rmsFrames = try systemRMSFrames(from: systemFile, frameDuration: 0.02)
        guard let stable = try detectLeakageSynchronously(
            systemFile: systemFile,
            microphoneFile: microphoneFile,
            rmsFrames: rmsFrames
        ) else { return nil }

        let microphoneDuration = Double(microphoneFile.length) / microphoneFile.processingFormat.sampleRate
        let intervals = duckingIntervals(
            rmsFrames: rmsFrames,
            frameDuration: 0.02,
            delay: stable.delay,
            totalDuration: microphoneDuration
        )
        guard !intervals.isEmpty else { return nil }
        return ScreenEchoCleanupPlan(
            delay: stable.delay,
            confidence: stable.confidence,
            duckingIntervals: intervals
        )
    }

    private static func detectLeakageSynchronously(
        systemFile: AVAudioFile,
        microphoneFile: AVAudioFile,
        rmsFrames: [Float]
    ) throws -> ScreenEchoDetection? {
        let systemDuration = Double(systemFile.length) / systemFile.processingFormat.sampleRate
        let microphoneDuration = Double(microphoneFile.length) / microphoneFile.processingFormat.sampleRate
        let commonDuration = min(systemDuration, microphoneDuration)
        guard commonDuration >= 2 else { return nil }
        let duration = min(windowDuration, commonDuration)
        let starts = analysisStarts(
            rmsFrames: rmsFrames,
            frameDuration: 0.02,
            windowDuration: duration,
            totalDuration: commonDuration
        )
        var candidates: [(delay: TimeInterval, correlation: Double)] = []

        for start in starts {
            let systemSamples = try readMonoSamples(
                from: systemFile,
                start: start,
                duration: duration,
                targetSampleRate: analysisSampleRate
            )
            guard rootMeanSquare(systemSamples) >= 0.008 else { continue }
            let microphoneSamples = try readMonoSamples(
                from: microphoneFile,
                start: start,
                duration: duration,
                targetSampleRate: analysisSampleRate
            )
            if let candidate = detectedDelay(
                systemSamples: systemSamples,
                microphoneSamples: microphoneSamples,
                sampleRate: analysisSampleRate,
                maximumDelay: maximumDelay
            ), candidate.correlation >= 0.28 {
                candidates.append(candidate)
            }
        }

        guard let stable = stableCandidate(from: candidates) else { return nil }
        return ScreenEchoDetection(
            delay: stable.delay,
            confidence: stable.correlation
        )
    }

    private static func analysisStarts(
        rmsFrames: [Float],
        frameDuration: TimeInterval,
        windowDuration: TimeInterval,
        totalDuration: TimeInterval
    ) -> [TimeInterval] {
        guard !rmsFrames.isEmpty else { return [0] }
        let windowFrames = min(
            rmsFrames.count,
            max(1, Int((windowDuration / frameDuration).rounded()))
        )
        let step = max(1, windowFrames / 4)
        var prefix = [Double](repeating: 0, count: rmsFrames.count + 1)
        for index in rmsFrames.indices {
            let value = Double(rmsFrames[index])
            prefix[index + 1] = prefix[index] + value * value
        }
        var scored: [(index: Int, score: Double)] = []
        var index = 0
        while index + windowFrames <= rmsFrames.count {
            let energy = prefix[index + windowFrames] - prefix[index]
            scored.append((index, energy / Double(windowFrames)))
            index += step
        }
        if scored.isEmpty { scored.append((0, prefix.last ?? 0)) }
        scored.sort { $0.score > $1.score }

        var selected: [Int] = []
        for candidate in scored where candidate.score >= 0.000_064 {
            guard selected.allSatisfy({ abs($0 - candidate.index) >= windowFrames / 2 }) else {
                continue
            }
            selected.append(candidate.index)
            if selected.count == 5 { break }
        }
        if selected.isEmpty {
            let maximumStart = max(0, totalDuration - windowDuration)
            return totalDuration <= windowDuration
                ? [0]
                : [0.08, 0.28, 0.48, 0.68, 0.88].map { maximumStart * $0 }
        }
        return selected.map {
            min(max(0, Double($0) * frameDuration), max(0, totalDuration - windowDuration))
        }.sorted()
    }

    private static func stableCandidate(
        from candidates: [(delay: TimeInterval, correlation: Double)]
    ) -> (delay: TimeInterval, correlation: Double)? {
        guard !candidates.isEmpty else { return nil }
        var bestGroup: [(delay: TimeInterval, correlation: Double)] = []
        var bestScore = 0.0
        for candidate in candidates {
            let group = candidates.filter { abs($0.delay - candidate.delay) <= 0.03 }
            let score = group.reduce(0) { $0 + $1.correlation }
            if score > bestScore {
                bestScore = score
                bestGroup = group
            }
        }
        guard !bestGroup.isEmpty else { return nil }
        let sortedDelays = bestGroup.map(\.delay).sorted()
        let delay = sortedDelays[sortedDelays.count / 2]
        let correlation = bestGroup.reduce(0) { $0 + $1.correlation } / Double(bestGroup.count)
        let sufficientlyStable = bestGroup.count >= 2 && correlation >= 0.30
        let exceptionallyStrong = bestGroup.count == 1 && correlation >= 0.55
        return sufficientlyStable || exceptionallyStrong ? (delay, correlation) : nil
    }

    private static func readMonoSamples(
        from file: AVAudioFile,
        start: TimeInterval,
        duration: TimeInterval,
        targetSampleRate: Double
    ) throws -> [Float] {
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        let startFrame = max(0, AVAudioFramePosition((start * sourceRate).rounded()))
        let availableFrames = max(0, file.length - startFrame)
        let requestedFrames = min(
            availableFrames,
            AVAudioFramePosition((duration * sourceRate).rounded())
        )
        guard requestedFrames > 0 else { return [] }
        file.framePosition = startFrame
        let frameCount = AVAudioFrameCount(min(requestedFrames, AVAudioFramePosition(UInt32.max)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RecorderError.finalizationFailed("Echo analysis could not allocate an audio buffer.")
        }
        try file.read(into: buffer, frameCount: frameCount)
        guard let channels = buffer.floatChannelData else {
            throw RecorderError.finalizationFailed("Echo analysis requires floating-point audio.")
        }

        let inputCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard inputCount > 0, channelCount > 0 else { return [] }
        let outputCount = max(1, Int(Double(inputCount) * targetSampleRate / sourceRate))
        var output = [Float](repeating: 0, count: outputCount)
        for outputIndex in 0..<outputCount {
            let sourceStart = Int(Double(outputIndex) * sourceRate / targetSampleRate)
            let sourceEnd = min(
                inputCount,
                max(sourceStart + 1, Int(Double(outputIndex + 1) * sourceRate / targetSampleRate))
            )
            var sum: Float = 0
            var count = 0
            for sourceIndex in sourceStart..<sourceEnd {
                for channel in 0..<channelCount {
                    sum += channels[channel][sourceIndex]
                    count += 1
                }
            }
            output[outputIndex] = count > 0 ? sum / Float(count) : 0
        }
        return output
    }

    private static func systemRMSFrames(
        from file: AVAudioFile,
        frameDuration: TimeInterval
    ) throws -> [Float] {
        let format = file.processingFormat
        let framesPerWindow = max(1, Int((format.sampleRate * frameDuration).rounded()))
        let chunkFrames = AVAudioFrameCount(max(framesPerWindow, 131_072))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw RecorderError.finalizationFailed("Echo cleanup could not allocate an audio buffer.")
        }
        file.framePosition = 0
        var result: [Float] = []
        var carry: [Float] = []
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            let count = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: count)
            mono.withUnsafeMutableBufferPointer { output in
                guard let outputBase = output.baseAddress else { return }
                if channelCount == 1 {
                    outputBase.update(from: channels[0], count: count)
                } else {
                    vDSP_vadd(
                        channels[0], 1,
                        channels[1], 1,
                        outputBase, 1,
                        vDSP_Length(count)
                    )
                    if channelCount > 2 {
                        for channel in 2..<channelCount {
                            vDSP_vadd(
                                outputBase, 1,
                                channels[channel], 1,
                                outputBase, 1,
                                vDSP_Length(count)
                            )
                        }
                    }
                    var scale = Float(1) / Float(channelCount)
                    vDSP_vsmul(
                        outputBase, 1,
                        &scale,
                        outputBase, 1,
                        vDSP_Length(count)
                    )
                }
            }

            if !carry.isEmpty {
                let needed = framesPerWindow - carry.count
                let copied = min(needed, mono.count)
                carry.append(contentsOf: mono.prefix(copied))
                if carry.count == framesPerWindow {
                    result.append(rms(of: carry))
                    carry.removeAll(keepingCapacity: true)
                }
                mono.removeFirst(copied)
            }

            mono.withUnsafeBufferPointer { samples in
                guard let base = samples.baseAddress else { return }
                var offset = 0
                while offset + framesPerWindow <= samples.count {
                    var energy: Float = 0
                    vDSP_svesq(
                        base.advanced(by: offset), 1,
                        &energy, vDSP_Length(framesPerWindow)
                    )
                    result.append(sqrt(energy / Float(framesPerWindow)))
                    offset += framesPerWindow
                }
                if offset < samples.count {
                    carry.append(contentsOf: UnsafeBufferPointer(
                        start: base.advanced(by: offset),
                        count: samples.count - offset
                    ))
                }
            }
        }
        if !carry.isEmpty {
            result.append(rms(of: carry))
        }
        return result
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_svesq(base, 1, &energy, vDSP_Length(samples.count))
        }
        return sqrt(energy / Float(samples.count))
    }

    private static func centered(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        return samples.map { Float(Double($0) - mean) }
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(energy / Double(samples.count))
    }
}
