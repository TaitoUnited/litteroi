import Accelerate
import AVFoundation
import WhisperKit

/// Copies a meeting's recordings into files the browser plays on its page: both tracks mixed into
/// one AAC file, with a faint mic raised, and each screen video as H.264, since Firefox may not
/// play the recorder's HEVC. A copy newer than its recordings is kept. A screen video that cannot
/// be copied, as one a crash cut off before its first fragment, is passed to `unreadable` and
/// gets no copy.
public enum MeetingMedia {
    public static func export(_ meeting: MeetingFolder, unreadable: (URL) -> Void = { _ in }) async throws {
        let files = FileManager.default
        let tracks = [meeting.mic, meeting.call].filter { files.fileExists(atPath: $0.path) }
        let sources = tracks + [meeting.transcriptJSON].filter { files.fileExists(atPath: $0.path) }
        if !tracks.isEmpty, isStale(meeting.listening, from: sources) {
            try write(mix(meeting), to: meeting.listening)
        }
        for screen in meeting.screens where isStale(meeting.browserCopy(of: screen), from: [screen]) {
            do {
                try await export(AVURLAsset(url: screen), preset: AVAssetExportPresetHighestQuality, as: .mp4,
                                 to: meeting.browserCopy(of: screen))
            } catch {
                try? FileManager.default.removeItem(at: meeting.browserCopy(of: screen))
                unreadable(screen)
            }
        }
    }

    /// Both tracks as one, the mic raised where the transcript's words on it are faint.
    static func mix(_ meeting: MeetingFolder) throws -> [Float] {
        func samples(_ track: URL) throws -> [Float]? {
            FileManager.default.fileExists(atPath: track.path) ? try AudioProcessor.loadAudioAsFloatArray(fromPath: track.path) : nil
        }
        let call = try samples(meeting.call)
        guard var mic = try samples(meeting.mic) else { return call ?? [] }
        if let transcript = try? Transcript.read(meeting.transcriptJSON) {
            mic = Levelling.raised(mic, speech: micSpeech(of: transcript, call: call))
        }
        guard let call else { return Levelling.limited(mic) }
        let length = max(mic.count, call.count)
        func padded(_ track: [Float]) -> [Float] { track + [Float](repeating: 0, count: length - track.count) }
        return Levelling.limited(vDSP.add(padded(mic), padded(call)))
    }

    /// When the lines that come from the mic track were said: the user's own beside a call, and
    /// every line without one or in a room meeting, as `MeetingTranscriber` splits them.
    static func micSpeech(of transcript: Transcript, call: [Float]?) -> [(start: Float, end: Float)] {
        let beside = transcript.room == nil && call.map { MeetingTranscriber.hasSound($0) } == true
        return transcript.utterances.filter { !beside || SpeakerLabels.own.contains($0.speaker) }.flatMap { utterance in
            utterance.words?.map { (start: $0.start, end: $0.end) } ?? [(start: utterance.start, end: utterance.end)]
        }
    }

    /// AAC at 16 kHz, the tracks' own rate. The file is written beside its place and moved there
    /// whole, so a write that fails leaves no half file that looks newer than the tracks.
    static func write(_ audio: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(WhisperKit.sampleRate), channels: 1)!
        let draft = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: draft) }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: draft, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ])
            let chunk = 160_000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            for start in stride(from: 0, to: audio.count, by: chunk) {
                let count = min(chunk, audio.count - start)
                audio.withUnsafeBufferPointer { samples in
                    buffer.floatChannelData![0].update(from: samples.baseAddress! + start, count: count)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
            }
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: draft, to: url)
    }

    static func isStale(_ copy: URL, from sources: [URL]) -> Bool {
        func modified(_ url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let copied = modified(copy) else { return true }
        return sources.contains { (modified($0) ?? .distantFuture) > copied }
    }

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: url)
        if #available(macOS 15, *) {
            try await session.export(to: url, as: type)
        } else {
            session.outputURL = url
            session.outputFileType = type
            await session.export()
            if let error = session.error { throw error }
        }
    }
}
