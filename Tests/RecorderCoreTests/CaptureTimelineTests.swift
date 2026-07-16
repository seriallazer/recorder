import XCTest
import CoreMedia
import CoreVideo
import AVFoundation
@testable import RecorderCore

final class CaptureTimelineTests: XCTestCase {
    func testRejectsZeroWarmupFrameAsTimelineOrigin() {
        XCTAssertFalse(CaptureTimeline.isUsableSourceStartTime(.zero))
        XCTAssertTrue(CaptureTimeline.isUsableSourceStartTime(
            CMTime(seconds: 176_820, preferredTimescale: 600)
        ))
    }

    func testNormalizesHostClockAudioOntoCameraTimeline() throws {
        let audioStart = CMTime(seconds: 176_380, preferredTimescale: 48_000)
        let audioSample = CMTime(seconds: 176_388, preferredTimescale: 48_000)
        let cameraStart = CMTime.zero

        let normalized = try XCTUnwrap(CaptureTimeline.normalizedTime(
            audioSample,
            sourceStartTime: audioStart,
            destinationStartTime: cameraStart
        ))

        XCTAssertEqual(CMTimeGetSeconds(normalized), 8, accuracy: 0.000_001)
    }

    func testPreservesNonzeroCameraTimelineOrigin() throws {
        let audioStart = CMTime(seconds: 500, preferredTimescale: 48_000)
        let audioSample = CMTime(seconds: 502.5, preferredTimescale: 48_000)
        let cameraStart = CMTime(seconds: 10, preferredTimescale: 600)

        let normalized = try XCTUnwrap(CaptureTimeline.normalizedTime(
            audioSample,
            sourceStartTime: audioStart,
            destinationStartTime: cameraStart
        ))

        XCTAssertEqual(CMTimeGetSeconds(normalized), 12.5, accuracy: 0.000_001)
    }

    func testRejectsAudioTimestampBeforeItsStart() {
        let normalized = CaptureTimeline.normalizedTime(
            CMTime(seconds: 99, preferredTimescale: 600),
            sourceStartTime: CMTime(seconds: 100, preferredTimescale: 600),
            destinationStartTime: .zero
        )

        XCTAssertNil(normalized)
    }

    func testRetimedHostClockFramesProduceShortDecodableMovie() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-timeline-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let hostClockStart = CMTime(seconds: 176_820, preferredTimescale: 600)
        for frameIndex in 0..<6 {
            let sourceTime = CMTimeAdd(
                hostClockStart,
                CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            )
            let sourceBuffer = try makeVideoSampleBuffer(presentationTime: sourceTime)
            let retimed = try XCTUnwrap(CaptureTimeline.retime(
                sourceBuffer,
                sourceStartTime: hostClockStart,
                destinationStartTime: .zero
            ))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(input.append(retimed))
        }
        input.markAsFinished()
        try await writer.finishWritingAsync()

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
        XCTAssertLessThan(CMTimeGetSeconds(duration), 1)
        XCTAssertEqual(videoTracks.count, 1)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        _ = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
    }

    private func makeVideoSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(pixelStatus, kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(imageBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) {
            memset(baseAddress, 0x7f, CVPixelBufferGetDataSize(imageBuffer))
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}
