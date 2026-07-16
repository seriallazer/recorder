import XCTest
import AVFoundation
import AppKit
@testable import RecorderCore

final class ThumbnailGeneratorTests: XCTestCase {
    func testCandidateTimesAvoidBeginningAndSampleAcrossRecording() {
        let times = ThumbnailGenerator.candidateTimes(
            duration: CMTime(seconds: 20, preferredTimescale: 600)
        ).map(CMTimeGetSeconds)

        XCTAssertEqual(times.count, 4)
        XCTAssertEqual(times[0], 3, accuracy: 0.001)
        XCTAssertEqual(times[1], 7, accuracy: 0.001)
        XCTAssertEqual(times[2], 12, accuracy: 0.001)
        XCTAssertEqual(times[3], 17, accuracy: 0.001)
    }

    func testInformativeFrameScoresHigherThanBlackOrBlankWhite() throws {
        let black = try makeImage { _, _ in (0, 0, 0) }
        let white = try makeImage { _, _ in (255, 255, 255) }
        let checkerboard = try makeImage { x, y in
            (x / 8 + y / 8).isMultiple(of: 2) ? (20, 20, 20) : (235, 235, 235)
        }

        let blackScore = ThumbnailGenerator.qualityScore(of: black)
        let whiteScore = ThumbnailGenerator.qualityScore(of: white)
        let checkerboardScore = ThumbnailGenerator.qualityScore(of: checkerboard)
        XCTAssertLessThan(blackScore, 1)
        XCTAssertGreaterThan(checkerboardScore, blackScore)
        XCTAssertGreaterThan(checkerboardScore, whiteScore)
    }

    func testGeneratedThumbnailSkipsBlackOpeningFrames() async throws {
        let movieURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-source-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movieURL) }
        try await makeMovie(at: movieURL)

        let jpeg = try await ThumbnailGenerator.jpegData(for: movieURL)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        let image = try XCTUnwrap(bitmap.cgImage)

        XCTAssertGreaterThan(ThumbnailGenerator.qualityScore(of: image), 1)
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 2
                ]
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let buffer = try makePixelBuffer(isBlack: frame < 4)
            XCTAssertTrue(adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2)
            ))
        }
        input.markAsFinished()
        try await writer.finishWritingAsync()
    }

    private func makePixelBuffer(isBlack: Bool) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                64,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<64 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<64 {
                let bright = !isBlack && (x / 8 + y / 8).isMultiple(of: 2)
                let value: UInt8 = bright ? 235 : (isBlack ? 0 : 20)
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func makeImage(
        pixels: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = pixels(x, y)
                let offset = (y * width + x) * 4
                data[offset] = red
                data[offset + 1] = green
                data[offset + 2] = blue
                data[offset + 3] = 255
            }
        }
        return try XCTUnwrap(context.makeImage())
    }
}
