import Foundation
import SpeakerKit
import WhisperKit

/// Transcribes a meeting in Finnish or English. With a call track, the mic track is the user's
/// own voice and only the call track is split by speaker; without one, or when the meeting was
/// held in one room beside a call, the mic track is split instead.
public struct MeetingTranscriber {
    public static let whisperModel = "openai_whisper-large-v3"

    public static var defaultModelsFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Litteroi/models")
    }

    public var modelsFolder: URL

    public init(modelsFolder: URL = MeetingTranscriber.defaultModelsFolder) {
        self.modelsFolder = modelsFolder
    }

    public func transcribe(
        mic: URL,
        call: URL?,
        span: TimeInterval? = nil,
        progress: (String) -> Void = { _ in },
        warning: (String) -> Void = { _ in }
    ) async throws -> Transcript {
        progress("Ladataan Whisper-malli (\(Self.whisperModel))")
        let whisper = try await loadWhisper()

        var micAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: mic.path)
        let callAudio = try call.map { try AudioProcessor.loadAudioAsFloatArray(fromPath: $0.path) }
        var micSpeakers: DiarizationResult?
        var room: RoomMeeting?
        if let callAudio, Self.hasSound(callAudio), RoomMeeting.callIsBrief(callAudio, of: max(micAudio.count, callAudio.count)) {
            progress("Erotellaan mikrofonin puhujat")
            let speakers = try await diarized(micAudio)
            micSpeakers = speakers
            room = RoomMeeting(mic: micAudio, call: callAudio, speech: Self.speech(of: speakers))
        }
        guard let callAudio, Self.hasSound(callAudio), room == nil else {
            let speakers: DiarizationResult
            if let micSpeakers {
                speakers = micSpeakers
            } else {
                progress("Erotellaan puhujat")
                speakers = try await diarized(micAudio)
            }
            let micChunks = try await chunked(micAudio, at: Self.turnStarts(of: speakers), with: whisper)
            let (results, language) = try await transcribed([("Litteroidaan mikrofoni", micChunks)], with: whisper, progress: progress)
            var utterances = Self.labelled(results[0], by: speakers, in: language)
            let note = room?.note(me: SpeakerLabels.me(in: language))
            if let note { warning(note) }
            if let own = room?.own {
                utterances = SpeakerLabels.renamed(utterances, from: .speakerId(own), to: SpeakerLabels.me(in: language), in: language)
            }
            return Transcript(utterances: utterances, room: note)
        }
        if let mismatch = Self.lengthWarning(mic: micAudio.count, call: callAudio.count, span: span) {
            warning(mismatch)
        }

        progress("Poistetaan puhelun kaiku mikrofonista")
        if let cleaned = EchoCanceller.cancel(mic: micAudio, call: callAudio) {
            micAudio = cleaned
        }
        progress("Erotellaan puhujat")
        let speakers = try await diarized(callAudio)
        let (results, language) = try await transcribed(
            [("Litteroidaan mikrofoni", try await chunked(micAudio, with: whisper)),
             ("Litteroidaan puhelu", try await chunked(callAudio, at: Self.turnStarts(of: speakers), with: whisper))],
            with: whisper,
            progress: progress
        )
        let pieces = SpeakerLabels.ownPieces(from: results[0], in: language)
        let theirs = SpeakerLabels.split(Self.labelled(results[1], by: speakers, in: language), at: pieces.map(\.start))
        let mine = SpeakerLabels.split(EchoCanceller.droppingEcho(pieces, heardIn: theirs), at: theirs.map(\.start))
        return Transcript(utterances: SpeakerLabels.merged((mine + theirs).sorted { $0.start < $1.start }))
    }

    /// The word times of a transcript made before they were kept: transcribes the recording again
    /// and gives each utterance of `transcript` its words, leaving its text and times as they are,
    /// since the corrected transcript and the questions quote them.
    public func addingWords(
        to transcript: Transcript,
        mic: URL,
        call: URL?,
        progress: (String) -> Void = { _ in }
    ) async throws -> Transcript {
        transcript.addingWords(from: try await transcribe(mic: mic, call: call, progress: progress), own: SpeakerLabels.own)
    }

    /// Downloads the model and tokenizer on the first run and loads them from disk after that.
    /// WhisperKit fetches the tokenizer again on every load when `tokenizer.json` is missing, and
    /// the file its fetch saved went missing between runs, so the tokenizer is fetched here.
    func loadWhisper() async throws -> WhisperKit {
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

    /// Splits the audio at silences into windows of at most 30 s. WhisperKit 1.1.1's
    /// `transcribe(audioArray:)` with `.vad` chunking returns only one of the chunks, and it drops
    /// failed chunks without an error, so the chunking is done here.
    private func chunked(_ audio: [Float], with whisper: WhisperKit) async throws -> [AudioChunk] {
        try await VADAudioChunker().chunkAll(
            audioArray: audio,
            maxChunkLength: whisper.featureExtractor.windowSamples ?? Constants.defaultWindowSamples,
            decodeOptions: Self.options(in: nil)
        )
    }

    /// Cuts the audio where the speaker changes, then each turn at silences, so a window holds one
    /// speaker and so one language. Whisper names a window's language from how it starts, and
    /// windows cut only at pauses lost the English of a speaker who answered a Finnish one.
    private func chunked(_ audio: [Float], at turns: [Float], with whisper: WhisperKit) async throws -> [AudioChunk] {
        let cuts = turns.map { min(audio.count, Int($0 * Float(WhisperKit.sampleRate))) }
        var chunks: [AudioChunk] = []
        for (start, end) in zip([0] + cuts, cuts + [audio.count]) where start < end {
            let turn = try await chunked(Array(audio[start..<end]), with: whisper)
            chunks += turn.map { AudioChunk(seekOffsetIndex: start + $0.seekOffsetIndex, audioSamples: $0.audioSamples) }
        }
        return chunks
    }

    /// The second at which each speaker's turn starts: halfway through the pause before it, or
    /// where its speech starts when it talks over the previous speaker. Speech under 1 s, such as
    /// a "joo" while another speaks, stays inside the turn around it.
    static func turnStarts(of speech: [(speaker: Int, start: Float, end: Float)]) -> [Float] {
        let turns = speech.filter { $0.end - $0.start >= 1 }.sorted { $0.start < $1.start }
        return zip(turns, turns.dropFirst()).compactMap { previous, next in
            guard next.speaker != previous.speaker else { return nil }
            return next.start > previous.end ? (previous.end + next.start) / 2 : next.start
        }
    }

    static func turnStarts(of diarization: DiarizationResult) -> [Float] {
        turnStarts(of: speech(of: diarization))
    }

    static func speech(of diarization: DiarizationResult) -> [(speaker: Int, start: Float, end: Float)] {
        diarization.segments.compactMap { segment in
            segment.speaker.speakerId.map { (speaker: $0, start: segment.startTime, end: segment.endTime) }
        }
    }

    /// Whisper names the language of each window as it transcribes it, so a meeting that switches
    /// between Finnish and English keeps both. The meeting's language, for the speaker labels and
    /// for windows Whisper cannot tell, is the one most of the speech is in. A window that came out
    /// in another language than that is transcribed again in it when Whisper named neither Finnish
    /// nor English, or when it is under 5 s, too short to tell from.
    private func transcribed(
        _ tracks: [(step: String, chunks: [AudioChunk])],
        with whisper: WhisperKit,
        progress: (String) -> Void
    ) async throws -> (tracks: [[TranscriptionResult]], language: Language) {
        var windows: [[[TranscriptionResult]]] = []
        for track in tracks {
            progress(track.step)
            windows.append(try await transcribed(track.chunks, in: track.chunks.map { _ in nil }, with: whisper))
        }
        let heard = zip(tracks, windows).flatMap { track, results in
            zip(track.chunks, results).map { (language: $1.first?.language, seconds: Self.seconds($0)) }
        }
        let language = Self.mainLanguage(of: heard)

        var results: [[TranscriptionResult]] = []
        for (track, var trackWindows) in zip(tracks, windows) {
            let again = trackWindows.indices.filter {
                Self.needsAnotherPass(trackWindows[$0].first?.language, seconds: Self.seconds(track.chunks[$0]), in: language)
            }
            if !again.isEmpty {
                let redone = try await transcribed(again.map { track.chunks[$0] }, in: again.map { _ in language }, with: whisper)
                for (index, result) in zip(again, redone) {
                    trackWindows[index] = result
                }
            }
            results.append(VADAudioChunker().updateSeekOffsetsForResults(
                chunkedResults: trackWindows.map { .success($0) },
                audioChunks: track.chunks
            ))
        }
        return (results, language)
    }

    static func mainLanguage(of windows: [(language: String?, seconds: Float)]) -> Language {
        func seconds(in language: Language) -> Float {
            windows.filter { $0.language == language.rawValue }.map(\.seconds).reduce(0, +)
        }
        return seconds(in: .en) > seconds(in: .fi) ? .en : .fi
    }

    static func needsAnotherPass(_ heard: String?, seconds: Float, in language: Language) -> Bool {
        heard != language.rawValue && (heard.flatMap(Language.init(rawValue:)) == nil || seconds < 5)
    }

    static func seconds(_ chunk: AudioChunk) -> Float {
        Float(chunk.audioSamples.count) / Float(WhisperKit.sampleRate)
    }

    /// Each window in its own language, or in the one Whisper hears in it when that is nil.
    private func transcribed(_ chunks: [AudioChunk], in languages: [Language?], with whisper: WhisperKit) async throws -> [[TranscriptionResult]] {
        let results = await whisper.transcribeWithOptions(
            audioArrays: chunks.map(\.audioSamples),
            decodeOptionsArray: languages.map(Self.options(in:)),
            seekOffsets: chunks.map(\.seekOffsetIndex)
        )
        return try results.map { try $0.get() }
    }

    /// WhisperKit's own first-token threshold empties a window that starts mid-sentence, so it
    /// is off; OpenAI's Whisper has no such check.
    static func options(in language: Language?) -> DecodingOptions {
        DecodingOptions(
            language: language?.rawValue,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            suppressBlank: true,
            firstTokenLogProbThreshold: nil
        )
    }

    /// A call track counts only with at least 10 s of sound, so a track that stayed silent
    /// because no call was on, or that holds only a notification sound, leaves the meeting to
    /// the mic track.
    static func hasSound(_ audio: [Float], sampleRate: Int = 16_000) -> Bool {
        let frameLength = sampleRate / 10
        var loudFrames = 0
        var start = 0
        while start + frameLength <= audio.count {
            var sum: Float = 0
            for sample in audio[start..<start + frameLength] {
                sum += sample * sample
            }
            if (sum / Float(frameLength)).squareRoot() > 0.005 {
                loudFrames += 1
                if loudFrames >= 100 { return true }
            }
            start += frameLength
        }
        return false
    }

    /// Both tracks run from the start of the recording to its end, the call's a few seconds late
    /// at most, so when their lengths differ, the one farther from the recording's wall-clock span
    /// is off, and so is the other when it too is far from it. A mic track short of the span stopped
    /// midway, as on 18.11.2026; a track longer than it, or a short call track, was most likely
    /// recorded at the wrong rate, which plays it too slow or too fast and puts its timestamps off.
    /// Without the span, as for audio files given by hand, the warning cannot say which track is off.
    static func lengthWarning(mic: Int, call: Int, span: TimeInterval?, sampleRate: Int = 16_000) -> String? {
        let micSeconds = mic / sampleRate
        let callSeconds = call / sampleRate
        let tolerance = max(10, max(micSeconds, callSeconds) / 10)
        guard abs(callSeconds - micSeconds) > tolerance else { return nil }
        guard let span else {
            return "Puhelun raita on \(callSeconds) s ja mikrofonin \(micSeconds) s, vaikka molempien pitäisi kestää koko "
                + "nauhoituksen ajan. Lyhyempi lakkasi luultavasti kesken, tai puhelu on nauhoitettu väärällä näytetaajuudella, "
                + "jolloin se soi liian nopeasti tai hitaasti ja sen aikaleimat ovat väärin."
        }
        let spanSeconds = Int(span.rounded())
        let micMiss = abs(micSeconds - spanSeconds)
        let callMiss = abs(callSeconds - spanSeconds)
        let micOff = micMiss >= callMiss || micMiss > tolerance
        let callOff = callMiss > micMiss || callMiss > tolerance
        var sentences: [String] = []
        if micOff {
            sentences.append("Mikrofonin raita on \(micSeconds) s, vaikka nauhoitus kesti \(spanSeconds) s.")
            sentences.append(micSeconds < spanSeconds
                ? "Mikrofoni lakkasi luultavasti nauhoittamasta kesken, joten litteraatista puuttuu sen jälkeen mikrofoniin puhuttu."
                : "Mikrofoni on luultavasti nauhoitettu väärällä näytetaajuudella, joten se soi liian hitaasti ja sen aikaleimat ovat väärin.")
        }
        if callOff {
            sentences.append("Puhelun raita on \(callSeconds) s, vaikka nauhoitus kesti \(spanSeconds) s.")
            sentences.append(callSeconds > spanSeconds
                ? "Puhelu on luultavasti nauhoitettu väärällä näytetaajuudella, joten se soi liian hitaasti ja sen aikaleimat ovat väärin."
                : "Puhelu on luultavasti nauhoitettu väärällä näytetaajuudella, jolloin se soi liian nopeasti ja sen aikaleimat ovat "
                    + "väärin, tai sen nauhoitus lakkasi kesken.")
        }
        if !callOff {
            sentences.append("Puhelun raita on kunnossa, \(callSeconds) s.")
        } else if !micOff {
            sentences.append("Mikrofonin raita on kunnossa, \(micSeconds) s.")
        }
        return sentences.joined(separator: " ")
    }

    private func diarized(_ audio: [Float]) async throws -> DiarizationResult {
        let speakerKit = try await SpeakerKit(PyannoteConfig(
            downloadBase: modelsFolder.path,
            verbose: false,
            logLevel: .error
        ))
        return try await speakerKit.diarize(audioArray: audio)
    }

    private static func labelled(_ results: [TranscriptionResult], by diarization: DiarizationResult, in language: Language) -> [Utterance] {
        SpeakerLabels.utterances(from: diarization.addSpeakerInfo(to: results).flatMap { $0 }, in: language)
    }
}
