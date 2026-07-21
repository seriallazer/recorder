import Foundation

public struct ASRWord: Hashable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct SpeakerInterval: Hashable, Sendable {
    public var speaker: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(speaker: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum TranscriptAligner {
    public static func removingCrossSourceEcho(
        in segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let systemSegments = segments
            .filter { $0.source == .system }
            .sorted { $0.startTime < $1.startTime }
        guard !systemSegments.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.source == .microphone else { return true }
            let microphoneTokens = normalizedTokens(segment.text)
            guard !microphoneTokens.isEmpty else { return true }
            let candidates = systemSegments.filter {
                $0.endTime > segment.startTime - 0.35
                    && $0.startTime < segment.endTime + 0.35
            }
            guard !candidates.isEmpty else { return true }

            if microphoneTokens.count <= 2 {
                let compactEcho = candidates.contains { candidate in
                    let systemTokens = normalizedTokens(candidate.text)
                    let startDelay = segment.startTime - candidate.startTime
                    return microphoneTokens == systemTokens
                        && (-0.04...0.40).contains(startDelay)
                }
                return !compactEcho
            }

            let combinedSystemTokens = candidates.flatMap { normalizedTokens($0.text) }
            let matched = longestCommonSubsequenceLength(
                microphoneTokens,
                combinedSystemTokens
            )
            let microphoneCoverage = Double(matched) / Double(microphoneTokens.count)
            let startsTogether = candidates.contains {
                abs(segment.startTime - $0.startTime) <= 0.65
            }
            let microphoneDuration = max(0.01, segment.endTime - segment.startTime)
            let overlappingDuration = candidates.reduce(0.0) { total, candidate in
                total + max(
                    0,
                    min(segment.endTime, candidate.endTime)
                        - max(segment.startTime, candidate.startTime)
                )
            }
            let temporalCoverage = min(1, overlappingDuration / microphoneDuration)
            let sharesTiming = startsTogether || temporalCoverage >= 0.55
            return !(microphoneCoverage >= 0.65 && sharesTiming)
        }
    }

    public static func markingCrossSourceOverlaps(
        in segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var updated = segments
        for index in updated.indices {
            guard updated[index].source != .mixed else { continue }
            let overlapsOtherSource = updated.indices.contains { candidate in
                guard candidate != index,
                      updated[candidate].source != .mixed,
                      updated[candidate].source != updated[index].source else { return false }
                return updated[candidate].endTime > updated[index].startTime
                    && updated[candidate].startTime < updated[index].endTime
            }
            updated[index].isOverlapping = updated[index].isOverlapping || overlapsOtherSource
        }
        return updated
    }

    public static func align(
        words: [ASRWord],
        speakers: [SpeakerInterval],
        source: TranscriptSource,
        fixedSpeaker: String? = nil,
        maximumPause: TimeInterval = 1.2
    ) -> [TranscriptSegment] {
        let orderedWords = words.sorted { $0.startTime < $1.startTime }
        guard !orderedWords.isEmpty else { return [] }

        struct AssignedWord {
            var word: ASRWord
            var speaker: String
            var overlapping: Bool
        }

        let assigned = orderedWords.map { word -> AssignedWord in
            if let fixedSpeaker {
                return AssignedWord(word: word, speaker: fixedSpeaker, overlapping: false)
            }
            let overlaps = speakers.compactMap { interval -> (SpeakerInterval, TimeInterval)? in
                let duration = max(0, min(word.endTime, interval.endTime) - max(word.startTime, interval.startTime))
                return duration > 0 ? (interval, duration) : nil
            }
            let best = overlaps.max { $0.1 < $1.1 }?.0
            let activeSpeakers = Set(overlaps.map { $0.0.speaker })
            return AssignedWord(
                word: word,
                speaker: best?.speaker ?? nearestSpeaker(to: word, in: speakers) ?? "Speaker 1",
                overlapping: activeSpeakers.count > 1
            )
        }

        var segments: [TranscriptSegment] = []
        var current: [AssignedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .replacingOccurrences(of: " ?", with: "?")
                .replacingOccurrences(of: " !", with: "!")
            let confidence = current.map(\.word.confidence).reduce(0, +) / Double(current.count)
            segments.append(TranscriptSegment(
                startTime: first.word.startTime,
                endTime: last.word.endTime,
                speaker: normalizedSpeaker(first.speaker),
                text: text,
                confidence: confidence,
                source: source,
                isOverlapping: current.contains(where: \.overlapping)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for item in assigned {
            if let previous = current.last {
                let pause = item.word.startTime - previous.word.endTime
                let terminal = previous.word.text.last.map { ".!?".contains($0) } ?? false
                if item.speaker != previous.speaker || pause > maximumPause || terminal {
                    flush()
                }
            }
            current.append(item)
        }
        flush()
        return segments
    }

    private static func nearestSpeaker(to word: ASRWord, in speakers: [SpeakerInterval]) -> String? {
        let midpoint = (word.startTime + word.endTime) / 2
        return speakers.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }?.speaker
    }

    private static func distance(from time: TimeInterval, to interval: SpeakerInterval) -> TimeInterval {
        if time < interval.startTime { return interval.startTime - time }
        if time > interval.endTime { return time - interval.endTime }
        return 0
    }

    private static func normalizedSpeaker(_ value: String) -> String {
        if value == "You" { return value }
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? value : "Speaker \(digits)"
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func longestCommonSubsequenceLength(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = [Int](repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() {
                current[index + 1] = left == right
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
