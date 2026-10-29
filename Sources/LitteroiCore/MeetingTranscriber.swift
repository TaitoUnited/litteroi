import Foundation
import SpeakerKit
import WhisperKit

/// Transcribes a meeting in Finnish. With a call track, the mic track is the user's own voice
/// and only the call track is split by speaker; without one, the mic track is split instead.
public struct MeetingTranscriber {
    public static let whisperModel = "openai_whisper-large-v3"

    public static var defaultModelsFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Litteroi/models")
    }

    public var modelsFolder: URL

    public init(modelsFolder: URL = MeetingTranscriber.defaultModelsFolder) {
        self.modelsFolder = modelsFolder
    }

    public func transcribe(mic: URL, call: URL?, progress: (String) -> Void = { _ in }) async throws -> Transcript {
        progress("Ladataan Whisper-malli (\(Self.whisperModel))")
        let whisper = try await loadWhisper()

        let micAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: mic.path)
        progress("Litteroidaan mikrofoni")
        let micResults = try await transcribed(micAudio, with: whisper)

        guard let call else {
            progress("Erotellaan puhujat")
            return Transcript(utterances: try await diarized(audio: micAudio, results: micResults))
        }

        let callAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: call.path)
        progress("Litteroidaan puhelu")
        let callResults = try await transcribed(callAudio, with: whisper)
        progress("Erotellaan puhujat")
        let theirs = try await diarized(audio: callAudio, results: callResults)
        let mine = SpeakerLabels.ownUtterances(from: micResults)
        return Transcript(utterances: (mine + theirs).sorted { $0.start < $1.start })
    }

    /// Downloads the model and tokenizer on the first run and loads them from disk after that.
    /// WhisperKit fetches the tokenizer again on every load when `tokenizer.json` is missing, and
    /// the file its fetch saved went missing between runs, so the tokenizer is fetched here.
    private func loadWhisper() async throws -> WhisperKit {
        let hub = HubApiWrapper(downloadBase: modelsFolder)
        let tokenizerRepo = HubApiWrapper.Repo(id: "openai/whisper-large-v3")
        let tokenizer = hub.localRepoLocation(tokenizerRepo).appending(path: "tokenizer.json")
        if !FileManager.default.fileExists(atPath: tokenizer.path) {
            _ = try await hub.snapshot(
                from: tokenizerRepo,
                matching: ["config.json", "tokenizer.json", "tokenizer_config.json"]
            )
        }

        let modelFolder = hub.localRepoLocation(HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml"))
            .appending(path: Self.whisperModel)
        let downloaded = FileManager.default.fileExists(atPath: modelFolder.appending(path: "TextDecoder.mlmodelc").path)
        return try await WhisperKit(WhisperKitConfig(
            model: Self.whisperModel,
            downloadBase: modelsFolder,
            modelFolder: downloaded ? modelFolder.path : nil,
            verbose: false,
            logLevel: .error,
            download: !downloaded
        ))
    }

    /// Splits the audio at silences into windows of at most 30 s and transcribes each one.
    /// WhisperKit 1.1.1's `transcribe(audioArray:)` with `.vad` chunking returns only one of the
    /// chunks, and it drops failed chunks without an error, so the chunking is done here.
    /// WhisperKit's own first-token threshold empties a window that starts mid-sentence, so it
    /// is off; OpenAI's Whisper has no such check.
    private func transcribed(_ audio: [Float], with whisper: WhisperKit) async throws -> [TranscriptionResult] {
        let options = DecodingOptions(
            language: "fi",
            skipSpecialTokens: true,
            wordTimestamps: true,
            suppressBlank: true,
            firstTokenLogProbThreshold: nil
        )
        let chunker = VADAudioChunker()
        let chunks = try await chunker.chunkAll(
            audioArray: audio,
            maxChunkLength: whisper.featureExtractor.windowSamples ?? Constants.defaultWindowSamples,
            decodeOptions: options
        )
        let results = await whisper.transcribeWithOptions(
            audioArrays: chunks.map(\.audioSamples),
            decodeOptionsArray: Array(repeating: options, count: chunks.count),
            seekOffsets: chunks.map(\.seekOffsetIndex)
        )
        for result in results {
            _ = try result.get()
        }
        return chunker.updateSeekOffsetsForResults(chunkedResults: results, audioChunks: chunks)
    }

    private func diarized(audio: [Float], results: [TranscriptionResult]) async throws -> [Utterance] {
        let speakerKit = try await SpeakerKit(PyannoteConfig(
            downloadBase: modelsFolder.path,
            verbose: false,
            logLevel: .error
        ))
        let diarization = try await speakerKit.diarize(audioArray: audio)
        let segments = diarization.addSpeakerInfo(to: results).flatMap { $0 }
        return SpeakerLabels.utterances(from: segments)
    }
}
