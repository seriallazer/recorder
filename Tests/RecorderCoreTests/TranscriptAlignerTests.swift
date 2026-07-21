import XCTest
@testable import RecorderCore

final class TranscriptAlignerTests: XCTestCase {
    func testRemovesTimeAlignedEchoSplitAcrossSystemSegments() {
        let segments = [
            TranscriptSegment(
                startTime: 10,
                endTime: 11,
                speaker: "Interviewer",
                text: "I think today",
                source: .system
            ),
            TranscriptSegment(
                startTime: 11,
                endTime: 13,
                speaker: "Interviewer",
                text: "we are doing system design.",
                source: .system
            ),
            TranscriptSegment(
                startTime: 10.08,
                endTime: 13.08,
                speaker: "You",
                text: "I think today we are doing systems design",
                source: .microphone
            )
        ]

        let cleaned = TranscriptAligner.removingCrossSourceEcho(in: segments)

        XCTAssertEqual(cleaned.count, 2)
        XCTAssertTrue(cleaned.allSatisfy { $0.source == .system })
    }

    func testRemovesFuzzyRealWorldCrossChannelEcho() {
        let microphone = TranscriptSegment(
            startTime: 243.36,
            endTime: 248.96,
            speaker: "You",
            text: "You can think of it as like a McDonald's thing, but in the background, you want to show the menu, right?",
            source: .microphone
        )
        let system = TranscriptSegment(
            startTime: 243.36,
            endTime: 248.88,
            speaker: "Interviewer",
            text: "You can just think of it as like a McDonald's thing, but in the background, you want to show the menu, right?",
            source: .system
        )

        XCTAssertEqual(
            TranscriptAligner.removingCrossSourceEcho(in: [microphone, system]),
            [system]
        )
    }

    func testRemovesEchoWhoseASRSegmentationStartsLater() {
        let segments = [
            TranscriptSegment(
                startTime: 20,
                endTime: 24,
                speaker: "Interviewer",
                text: "So basically how would you design",
                source: .system
            ),
            TranscriptSegment(
                startTime: 21,
                endTime: 25.5,
                speaker: "You",
                text: "Basically how would you design a system like this",
                source: .microphone
            ),
            TranscriptSegment(
                startTime: 24,
                endTime: 25.5,
                speaker: "Interviewer",
                text: "a system like this",
                source: .system
            )
        ]

        let cleaned = TranscriptAligner.removingCrossSourceEcho(in: segments)

        XCTAssertEqual(cleaned.count, 2)
        XCTAssertTrue(cleaned.allSatisfy { $0.source == .system })
    }

    func testRemovesShortEchoOnlyWhenDelayIsPlausible() {
        let system = TranscriptSegment(
            startTime: 10,
            endTime: 10.5,
            speaker: "Interviewer",
            text: "Hello",
            source: .system
        )
        let immediateEcho = TranscriptSegment(
            startTime: 10.08,
            endTime: 10.58,
            speaker: "You",
            text: "Hello",
            source: .microphone
        )
        let laterReply = TranscriptSegment(
            startTime: 11,
            endTime: 11.5,
            speaker: "You",
            text: "Hello",
            source: .microphone
        )

        let cleaned = TranscriptAligner.removingCrossSourceEcho(
            in: [system, immediateEcho, laterReply]
        )

        XCTAssertEqual(cleaned, [system, laterReply])
    }

    func testKeepsGenuineCrossChannelInterruption() {
        let segments = [
            TranscriptSegment(
                startTime: 10,
                endTime: 13,
                speaker: "Interviewer",
                text: "Tell me about the data model",
                source: .system
            ),
            TranscriptSegment(
                startTime: 11,
                endTime: 13,
                speaker: "You",
                text: "Sure, let me clarify one thing first",
                source: .microphone
            )
        ]

        XCTAssertEqual(
            TranscriptAligner.removingCrossSourceEcho(in: segments),
            segments
        )
    }

    func testSeparateChannelOverlapsAreMarkedOnBothSegments() {
        let segments = [
            TranscriptSegment(
                startTime: 1,
                endTime: 3,
                speaker: "You",
                text: "hello",
                source: .microphone
            ),
            TranscriptSegment(
                startTime: 2,
                endTime: 4,
                speaker: "Interviewer",
                text: "hi",
                source: .system
            )
        ]

        let marked = TranscriptAligner.markingCrossSourceOverlaps(in: segments)

        XCTAssertTrue(marked.allSatisfy(\.isOverlapping))
    }

    func testTimestampUsesHoursMinutesAndSeconds() {
        XCTAssertEqual(TranscriptDocument.timestamp(3_661.9), "01:01:01")
    }

    func testSpeakerChangesCreateSeparateSegments() {
        let words = [
            ASRWord(text: "Hello", startTime: 0, endTime: 0.5, confidence: 0.9),
            ASRWord(text: "there.", startTime: 0.5, endTime: 1, confidence: 0.8),
            ASRWord(text: "Welcome", startTime: 1.2, endTime: 1.8, confidence: 0.95)
        ]
        let speakers = [
            SpeakerInterval(speaker: "S1", startTime: 0, endTime: 1.05),
            SpeakerInterval(speaker: "S2", startTime: 1.1, endTime: 2)
        ]

        let result = TranscriptAligner.align(words: words, speakers: speakers, source: .mixed)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Speaker 1")
        XCTAssertEqual(result[0].text, "Hello there.")
        XCTAssertEqual(result[1].speaker, "Speaker 2")
    }

    func testOverlappingSpeakersAreFlagged() {
        let words = [ASRWord(text: "Yes", startTime: 1, endTime: 1.5, confidence: 1)]
        let speakers = [
            SpeakerInterval(speaker: "S1", startTime: 0.8, endTime: 1.6),
            SpeakerInterval(speaker: "S2", startTime: 1.1, endTime: 1.7)
        ]
        let result = TranscriptAligner.align(words: words, speakers: speakers, source: .mixed)
        XCTAssertTrue(result[0].isOverlapping)
    }

    func testFixedMicrophoneSpeakerIsYou() {
        let words = [ASRWord(text: "Question", startTime: 2, endTime: 2.5, confidence: 1)]
        let result = TranscriptAligner.align(
            words: words,
            speakers: [],
            source: .microphone,
            fixedSpeaker: "You"
        )
        XCTAssertEqual(result[0].speaker, "You")
    }

    func testImportedAudioSpeakerCanBeFixedWithoutDiarization() {
        let words = [ASRWord(text: "Imported", startTime: 0, endTime: 0.7, confidence: 1)]
        let result = TranscriptAligner.align(
            words: words,
            speakers: [],
            source: .microphone,
            fixedSpeaker: "Audio"
        )
        XCTAssertEqual(result[0].speaker, "Audio")
    }

    func testPlainTextAppliesTrimOffset() {
        let document = TranscriptDocument(
            recordingID: UUID(),
            speakerCount: 1,
            segments: [
                TranscriptSegment(startTime: 10, endTime: 12, speaker: "Speaker 1", text: "Hello")
            ]
        )
        XCTAssertTrue(document.plainText(trimStart: 8, trimEnd: 20).contains("[00:00:02] Speaker 1: Hello"))
    }
}
