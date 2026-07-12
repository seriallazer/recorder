import Foundation
import FluidAudio

public actor LocalTranscriptionService: Transcribing, ModelManaging {
    public typealias ProgressCallback = @Sendable (_ phase: String, _ fraction: Double) -> Void

    private var asrModels: AsrModels?
    private var diarizer: OfflineDiarizerManager?
    private let progress: ProgressCallback?

    public init(progress: ProgressCallback? = nil) {
        self.progress = progress
    }

    public var modelsAreAvailable: Bool {
        get async {
            await (try? AsrModels.isModelValid(version: .v2, encoderPrecision: .int8)) == true
        }
    }

    public func prepareModels() async throws {
        try await prepareModels(loadDiarizer: true)
    }

    public func prepareModels(loadDiarizer: Bool) async throws {
        if asrModels == nil {
            progress?("Downloading English transcription model", 0)
            let models = try await AsrModels.downloadAndLoad(
                version: .v2,
                encoderPrecision: .int8,
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

        if loadDiarizer, diarizer == nil {
            progress?("Preparing speaker diarization model", 0.78)
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            self.diarizer = diarizer
        }
        progress?("Local models ready", 1)
    }

    public func transcribe(recording: RecordingManifest, folder: URL) async throws -> TranscriptDocument {
        try Task.checkCancellation()

        let tracks: [(url: URL, source: TranscriptSource, fixedSpeaker: String?)]
        if recording.mode == .screen {
            var screenTracks: [(URL, TranscriptSource, String?)] = []
            if let mic = recording.fileURL(for: recording.microphoneStemFile, in: folder) {
                screenTracks.append((mic, .microphone, "You"))
            }
            if let system = recording.fileURL(for: recording.systemStemFile, in: folder) {
                screenTracks.append((system, .system, nil))
            }
            if screenTracks.isEmpty, let audio = recording.fileURL(for: recording.audioFile, in: folder) {
                screenTracks.append((audio, .mixed, nil))
            }
            tracks = screenTracks
        } else if let audio = recording.fileURL(for: recording.audioFile, in: folder) {
            let fixedSpeaker = recording.configuration.capturesMicrophone ? nil : "Audio"
            tracks = [(audio, .microphone, fixedSpeaker)]
        } else {
            throw RecorderError.missingMedia
        }

        guard !tracks.isEmpty else { throw RecorderError.missingMedia }
        let needsDiarizer = tracks.contains { $0.fixedSpeaker == nil }
        try await prepareModels(loadDiarizer: needsDiarizer)

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
        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let asrResult = try await asr.transcribe(url, decoderState: &decoderState)
        await asr.cleanup()
        try Task.checkCancellation()

        let words = words(from: asrResult)
        if let fixedSpeaker {
            return TranscriptAligner.align(words: words, speakers: [], source: source, fixedSpeaker: fixedSpeaker)
        }

        guard let diarizer else {
            throw RecorderError.modelUnavailable("Speaker diarization model was not initialized.")
        }
        let diarization = try await diarizer.process(url)
        let speakers = diarization.segments.map {
            SpeakerInterval(
                speaker: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
        let aligned = TranscriptAligner.align(words: words, speakers: speakers, source: source)
        if aligned.isEmpty, !asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TranscriptAligner.align(
                words: [ASRWord(
                    text: asrResult.text,
                    startTime: 0,
                    endTime: asrResult.duration,
                    confidence: Double(asrResult.confidence)
                )],
                speakers: speakers,
                source: source
            )
        }
        return aligned
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
