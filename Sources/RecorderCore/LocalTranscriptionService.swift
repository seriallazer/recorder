import Foundation
import FluidAudio
@preconcurrency import CoreML

public actor LocalTranscriptionService: Transcribing, ModelManaging {
    public typealias ProgressCallback = @Sendable (_ phase: String, _ fraction: Double) -> Void

    private var asrModels: AsrModels?
    private let progress: ProgressCallback?
    private let diarizer: any SpeakerDiarizing

    public init(
        progress: ProgressCallback? = nil,
        diarizer: any SpeakerDiarizing = CrashSafeDiarizationService()
    ) {
        self.progress = progress
        self.diarizer = diarizer
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
        try await transcribe(recording: recording, folder: folder, options: .stable)
    }

    public func transcribe(
        recording: RecordingManifest,
        folder: URL,
        options: DiarizationOptions
    ) async throws -> TranscriptDocument {
        try Task.checkCancellation()

        let tracks = try TranscriptionTrackPlanner.plan(
            recording: recording,
            folder: folder,
            options: options
        )
        guard !tracks.isEmpty else { throw RecorderError.missingMedia }
        try await prepareModels(loadDiarizer: false)

        var allSegments: [TranscriptSegment] = []
        var usedEnhancedDiarization = false
        var fallbackMessages: [String] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let baseProgress = 0.1 + (Double(index) / Double(tracks.count)) * 0.8
            progress?("Transcribing audio track \(index + 1) of \(tracks.count)", baseProgress)
            let result = try await transcribeTrack(
                url: track.url,
                source: track.source,
                fixedSpeaker: track.fixedSpeaker,
                fallbackSpeaker: track.fallbackSpeaker,
                expectedSpeakerCount: track.expectedSpeakerCount,
                speakerPrefix: track.speakerPrefix
            )
            allSegments.append(contentsOf: result.segments)
            usedEnhancedDiarization = usedEnhancedDiarization || result.usedEnhancedDiarization
            if let fallbackMessage = result.fallbackMessage {
                fallbackMessages.append(fallbackMessage)
            }
            let completedProgress = 0.1 + (Double(index + 1) / Double(tracks.count)) * 0.8
            progress?("Finished audio track \(index + 1) of \(tracks.count)", completedProgress)
        }

        progress?("Finalizing transcript", 0.95)
        allSegments.sort { $0.startTime < $1.startTime }
        if tracks.count > 1 {
            allSegments = TranscriptAligner.markingCrossSourceOverlaps(in: allSegments)
        }
        let speakerCount = Set(allSegments.map(\.speaker)).count
        let attribution: SpeakerAttribution
        if usedEnhancedDiarization {
            attribution = .enhancedDiarization
        } else if !fallbackMessages.isEmpty {
            attribution = .stableFallback
        } else if tracks.count > 1 {
            attribution = .channelSeparated
        } else {
            attribution = .singleTrack
        }
        return TranscriptDocument(
            recordingID: recording.id,
            speakerCount: speakerCount,
            speakerAttribution: attribution,
            attributionNote: fallbackMessages.isEmpty
                ? nil
                : "Enhanced diarization could not complete safely. The transcript was preserved with stable labels.",
            segments: allSegments
        )
    }

    private func transcribeTrack(
        url: URL,
        source: TranscriptSource,
        fixedSpeaker: String?,
        fallbackSpeaker: String,
        expectedSpeakerCount: Int?,
        speakerPrefix: String
    ) async throws -> TrackResult {
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
                return TrackResult(segments: fallbackSegments(
                    from: asrResult,
                    source: source,
                    speaker: fixedSpeaker
                ))
            }
            return TrackResult(segments: aligned)
        }

        do {
            progress?("Separating speakers in a crash-safe helper", 0.88)
            let intervals = try await diarizer.diarize(
                url,
                expectedSpeakerCount: expectedSpeakerCount
            ).map { interval in
                SpeakerInterval(
                    speaker: speakerLabel(interval.speaker, prefix: speakerPrefix),
                    startTime: interval.startTime,
                    endTime: interval.endTime
                )
            }
            let aligned = TranscriptAligner.align(words: words, speakers: intervals, source: source)
            guard !aligned.isEmpty else {
                throw RecorderError.transcriptionFailed("Speaker alignment returned no segments.")
            }
            return TrackResult(segments: aligned, usedEnhancedDiarization: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let stable = TranscriptAligner.align(
                words: words,
                speakers: [],
                source: source,
                fixedSpeaker: fallbackSpeaker
            )
            return TrackResult(
                segments: stable.isEmpty
                    ? fallbackSegments(from: asrResult, source: source, speaker: fallbackSpeaker)
                    : stable,
                fallbackMessage: error.localizedDescription
            )
        }
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

    private func speakerLabel(_ rawValue: String, prefix: String) -> String {
        let digits = rawValue.filter(\.isNumber)
        return digits.isEmpty ? prefix : "\(prefix) \(digits)"
    }
}

private struct TrackResult {
    var segments: [TranscriptSegment]
    var usedEnhancedDiarization = false
    var fallbackMessage: String?
}

struct TranscriptionTrackPlan: Hashable, Sendable {
    var url: URL
    var source: TranscriptSource
    var fixedSpeaker: String?
    var fallbackSpeaker: String
    var expectedSpeakerCount: Int?
    var speakerPrefix: String
}

enum TranscriptionTrackPlanner {
    static func plan(
        recording: RecordingManifest,
        folder: URL,
        options: DiarizationOptions
    ) throws -> [TranscriptionTrackPlan] {
        let microphone = recording.fileURL(for: recording.microphoneStemFile, in: folder)
        let system = recording.fileURL(for: recording.systemStemFile, in: folder)

        if let microphone, let system, microphone.standardizedFileURL != system.standardizedFileURL {
            let remoteSpeakerCount = max(1, options.expectedSpeakerCount - 1)
            var tracks = [TranscriptionTrackPlan(
                url: microphone,
                source: .microphone,
                fixedSpeaker: "You",
                fallbackSpeaker: "You",
                expectedSpeakerCount: nil,
                speakerPrefix: "You"
            )]
            if options.isEnabled, remoteSpeakerCount > 1 {
                tracks.append(TranscriptionTrackPlan(
                    url: system,
                    source: .system,
                    fixedSpeaker: nil,
                    fallbackSpeaker: "System Audio",
                    expectedSpeakerCount: remoteSpeakerCount,
                    speakerPrefix: "Interviewer"
                ))
            } else {
                tracks.append(TranscriptionTrackPlan(
                    url: system,
                    source: .system,
                    fixedSpeaker: options.isEnabled ? "Interviewer" : "System Audio",
                    fallbackSpeaker: "System Audio",
                    expectedSpeakerCount: nil,
                    speakerPrefix: "Interviewer"
                ))
            }
            return tracks
        }

        guard let audio = recording.fileURL(for: recording.audioFile, in: folder) else {
            throw RecorderError.missingMedia
        }
        let stableSpeaker = recording.configuration.capturesMicrophone ? "You" : "Audio"
        return [TranscriptionTrackPlan(
            url: audio,
            source: recording.configuration.capturesMicrophone ? .microphone : .mixed,
            fixedSpeaker: options.isEnabled ? nil : stableSpeaker,
            fallbackSpeaker: stableSpeaker,
            expectedSpeakerCount: options.isEnabled ? options.expectedSpeakerCount : nil,
            speakerPrefix: "Speaker"
        )]
    }
}
