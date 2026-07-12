import XCTest
@testable import RecorderCore

final class TranscriptAlignerTests: XCTestCase {
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
