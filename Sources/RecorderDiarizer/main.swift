import Foundation
@preconcurrency import CoreML
@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio

private struct Output: Codable {
    var segments: [Segment]
}

private struct Segment: Codable {
    var speaker: String
    var startTime: TimeInterval
    var endTime: TimeInterval
}

@main
private struct RecorderDiarizer {
    static func main() async {
        guard CommandLine.arguments.count >= 3 else {
            fail("Usage: RecorderDiarizer <audio> <output-json> [expected-speakers]")
        }

        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedSpeakers = CommandLine.arguments.count > 3
            ? Int(CommandLine.arguments[3])
            : nil

        do {
            let preparedAudio = try await prepareAudio(inputURL)
            defer {
                if preparedAudio != inputURL {
                    try? FileManager.default.removeItem(at: preparedAudio)
                }
            }
            var config = OfflineDiarizerConfig(embeddingBatchSize: 1)
            if let expectedSpeakers, expectedSpeakers > 0 {
                config = config.withSpeakers(exactly: min(max(expectedSpeakers, 1), 6))
            }

            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .cpuAndGPU
            modelConfiguration.allowLowPrecisionAccumulationOnGPU = true

            // FluidAudio intentionally loads FBank as CPU-only. On some Apple M2/
            // macOS 14 combinations that path can fault inside BNNS before Swift can
            // receive an error. Load the remaining models normally, then reopen
            // FBank for CPU+GPU and skip FluidAudio's redundant manager prewarm.
            let loadedModels = try await OfflineDiarizerModels.load(configuration: modelConfiguration)
            let fbankConfiguration = MLModelConfiguration()
            fbankConfiguration.computeUnits = .cpuAndGPU
            fbankConfiguration.allowLowPrecisionAccumulationOnGPU = true
            let fbankURL = OfflineDiarizerModels.defaultModelsDirectory()
                .appendingPathComponent("speaker-diarization/FBank.mlmodelc")
            let fbankModel = try MLModel(contentsOf: fbankURL, configuration: fbankConfiguration)
            let models = OfflineDiarizerModels(
                segmentationModel: loadedModels.segmentationModel,
                fbankModel: fbankModel,
                embeddingModel: loadedModels.embeddingModel,
                pldaRhoModel: loadedModels.pldaRhoModel,
                pldaPsi: loadedModels.pldaPsi,
                compilationDuration: loadedModels.compilationDuration
            )

            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(preparedAudio)
            let output = Output(segments: result.segments.map {
                Segment(
                    speaker: $0.speakerId,
                    startTime: TimeInterval($0.startTimeSeconds),
                    endTime: TimeInterval($0.endTimeSeconds)
                )
            })
            let data = try JSONEncoder().encode(output)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            let nsError = error as NSError
            fail("\(error.localizedDescription) [\(nsError.domain) \(nsError.code)] \(nsError.userInfo)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    private static func prepareAudio(_ inputURL: URL) async throws -> URL {
        if inputURL.pathExtension.lowercased() == "wav" {
            return inputURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderDiarizer-\(UUID().uuidString).wav")
        do {
            let asset = AVURLAsset(url: inputURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw PreparationError.noAudio
            }
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                  let sourceFormat = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  sourceFormat.mSampleRate > 0 else {
                throw PreparationError.unsupportedAudioFormat
            }
            // AVAssetReader reliably decodes compressed audio to PCM, but does not
            // reliably perform sample-rate conversion at the same time. Preserve the
            // source rate here; FluidAudio safely resamples the resulting PCM WAV.
            let sampleRate = UInt32(sourceFormat.mSampleRate.rounded())
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw PreparationError.couldNotCreateBuffer
            }
            reader.add(output)

            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 0, count: 44))
            guard reader.startReading() else {
                throw reader.error ?? PreparationError.couldNotCreateBuffer
            }

            var audioByteCount: UInt64 = 0
            while let sampleBuffer = output.copyNextSampleBuffer() {
                defer { CMSampleBufferInvalidate(sampleBuffer) }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }
                var chunk = Data(count: length)
                let status = chunk.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: bytes.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw PreparationError.couldNotCreateBuffer
                }
                try handle.write(contentsOf: chunk)
                audioByteCount += UInt64(length)
            }
            guard reader.status == .completed, audioByteCount > 0 else {
                throw reader.error ?? PreparationError.noAudio
            }
            guard audioByteCount <= UInt64(UInt32.max - 36) else {
                throw PreparationError.audioTooLong
            }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: wavHeader(
                audioByteCount: UInt32(audioByteCount),
                sampleRate: sampleRate
            ))
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func wavHeader(audioByteCount: UInt32, sampleRate: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(36 + audioByteCount)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3)) // IEEE float PCM
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 4)
        data.appendLittleEndian(UInt16(4))
        data.appendLittleEndian(UInt16(32))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(audioByteCount)
        return data
    }
}

private enum PreparationError: LocalizedError {
    case noAudio
    case couldNotCreateBuffer
    case audioTooLong
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .noAudio: "The recording contained no audio samples."
        case .couldNotCreateBuffer: "The diarization audio buffer could not be created."
        case .audioTooLong: "The recording is too long for temporary WAV conversion."
        case .unsupportedAudioFormat: "The recording's audio format is unsupported."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
