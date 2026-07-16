import Foundation
import FluidAudio
@preconcurrency import CoreML

public actor LocalTranscriptionService: Transcribing, ModelManaging {
    public typealias ProgressCallback = @Sendable (_ phase: String, _ fraction: Double) -> Void

    private var asrModels: AsrModels?
    private let progress: ProgressCallback?

    public init(progress: ProgressCallback? = nil) {
        self.progress = progress
    }

    // FluidAudio supports this path for its Parakeet encoder on Apple Silicon.
    // Prefer it for the desktop app because the Neural Engine can reject an
    // otherwise valid ML Program after sustained capture/AV workloads.
    nonisolated static var preferredComputeUnits: MLComputeUnits { .cpuAndGPU }

    public var modelsAreAvailable: Bool {
        get async {
            await (try? AsrModels.isModelValid(version: .v2, encoderPrecision: .int8)) == true
        }
    }

    public func prepareModels() async throws {
        try await prepareModels(loadDiarizer: false)
    }

    public func prepareModels(loadDiarizer: Bool) async throws {
        if asrModels == nil {
            progress?("Downloading English transcription model", 0)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = Self.preferredComputeUnits
            let models = try await AsrModels.downloadAndLoad(
                configuration: configuration,
                version: .v2,
                encoderPrecision: .int8,
                encoderComputeUnits: Self.preferredComputeUnits,
                progressHandler: { [progress] update in
                    let cap = loadDiarizer ? 0.75 : 0.95
                    progress?("Preparing English transcription model", update.fractionCompleted * cap)
                }
            )
            guard try await AsrModels.isModelValid(version: .v2, encoderPrecision: .int8) else {
                throw RecorderError.modelUnavailable("The downloaded ASR model failed validation.")
            }
            self.asrModels = models
        }

        progress?("Local models ready", 1)
    }

    public func transcribe(recording: RecordingManifest, folder: URL) async throws -> TranscriptDocument {
        try Task.checkCancellation()

        let tracks: [(url: URL, source: TranscriptSource, fixedSpeaker: String?)]
        if recording.mode == .audio {
            guard let audio = recording.fileURL(for: recording.audioFile, in: folder) else {
                throw RecorderError.missingMedia
            }
            let fixedSpeaker = recording.configuration.capturesMicrophone ? "You" : "Audio"
            tracks = [(audio, .microphone, fixedSpeaker)]
        } else if recording.mode == .screen {
            var screenTracks: [(URL, TranscriptSource, String?)] = []
            if let mic = recording.fileURL(for: recording.microphoneStemFile, in: folder) {
                screenTracks.append((mic, .microphone, "You"))
            }
            if let system = recording.fileURL(for: recording.systemStemFile, in: folder) {
                screenTracks.append((system, .system, "System Audio"))
            }
            if screenTracks.isEmpty, let audio = recording.fileURL(for: recording.audioFile, in: folder) {
                screenTracks.append((audio, .mixed, "Audio"))
            }
            tracks = screenTracks
        } else if let audio = recording.fileURL(for: recording.audioFile, in: folder) {
            tracks = [(audio, .microphone, "You")]
        } else {
            throw RecorderError.missingMedia
        }

        guard !tracks.isEmpty else { throw RecorderError.missingMedia }
        try await prepareModels(loadDiarizer: false)

        var allSegments: [TranscriptSegment] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let baseProgress = 0.1 + (Double(index) / Double(tracks.count)) * 0.8
            progress?("Transcribing audio track \(index + 1) of \(tracks.count)", baseProgress)
            let result = try await transcribeTrack(
                url: track.url,
                source: track.source,
                fixedSpeaker: track.fixedSpeaker
            )
            allSegments.append(contentsOf: result)
            let completedProgress = 0.1 + (Double(index + 1) / Double(tracks.count)) * 0.8
            progress?("Finished audio track \(index + 1) of \(tracks.count)", completedProgress)
        }

        progress?("Finalizing transcript", 0.95)
        allSegments.sort { $0.startTime < $1.startTime }
        let speakerCount = Set(allSegments.map(\.speaker)).count
        return TranscriptDocument(
            recordingID: recording.id,
            speakerCount: speakerCount,
            segments: allSegments
        )
    }

    private func transcribeTrack(
        url: URL,
        source: TranscriptSource,
        fixedSpeaker: String?
    ) async throws -> [TranscriptSegment] {
        guard let asrModels else {
            throw RecorderError.modelUnavailable("Models were not initialized.")
        }

        // Keep ASR concurrency at one to minimize peak memory on 8 GB machines.
        let asr = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await asr.loadModels(asrModels)
        let asrResult: ASRResult
        do {
            var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            asrResult = try await asr.transcribe(url, decoderState: &decoderState)
            await asr.cleanup()
        } catch {
            await asr.cleanup()
            throw error
        }
        try Task.checkCancellation()

        let words = words(from: asrResult)
        if let fixedSpeaker {
            let aligned = TranscriptAligner.align(
                words: words,
                speakers: [],
                source: source,
                fixedSpeaker: fixedSpeaker
            )
            if aligned.isEmpty {
                return fallbackSegments(from: asrResult, source: source, speaker: fixedSpeaker)
            }
            return aligned
        }

        return fallbackSegments(from: asrResult, source: source, speaker: "Audio")
    }

    private func fallbackSegments(
        from result: ASRResult,
        source: TranscriptSource,
        speaker: String
    ) -> [TranscriptSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [
            TranscriptSegment(
                startTime: 0,
                endTime: result.duration,
                speaker: speaker,
                text: text,
                confidence: Double(result.confidence),
                source: source
            )
        ]
    }

    private func words(from result: ASRResult) -> [ASRWord] {
        let timings = result.tokenTimings ?? []
        let words = buildWordTimings(from: timings)
        return words.map { word in
            let overlappingTokens = timings.filter {
                $0.endTime >= word.startTime && $0.startTime <= word.endTime
            }
            let confidence = overlappingTokens.isEmpty
                ? Double(result.confidence)
                : overlappingTokens.map { Double($0.confidence) }.reduce(0, +) / Double(overlappingTokens.count)
            return ASRWord(
                text: word.word,
                startTime: word.startTime,
                endTime: word.endTime,
                confidence: confidence
            )
        }
    }
}
