import AVFoundation
import Foundation
import WhisperKit

/// Transcribes a recording while it grows, a window at a time, so the meeting can be read while
/// it runs. Each window is cut at the quietest moment of its last seconds, transcribed once and
/// appended to a Markdown file. The lines carry no speaker: the labels come from the whole
/// meeting, which the full transcription after the recording has.
public struct LiveTranscriber {
    static let sampleRate = WhisperKit.sampleRate
    /// Whisper reads 30 s at a time.
    static let longestWindow = 30 * sampleRate
    /// While the recording runs, a window waits for this much audio, so Whisper can tell its
    /// language and no window costs a whole 30 s pass for a few seconds of speech.
    static let shortestWindow = 15 * sampleRate
    /// A recording whose track has not grown for this long has ended, as when the app crashed.
    static let stalled: TimeInterval = 60

    public var transcriber: MeetingTranscriber

    public init(transcriber: MeetingTranscriber = MeetingTranscriber()) {
        self.transcriber = transcriber
    }

    /// Transcribes `track` from `second` on into `output`, a window as soon as it is recorded, until
    /// `recording` says the recording has stopped or the track stops growing, then the rest.
    public func follow(
        _ track: URL,
        from second: Double = 0,
        into output: URL,
        title: String,
        recording: () -> Bool,
        line: (String) -> Void = { _ in },
        progress: (String) -> Void = { _ in }
    ) async throws {
        progress("Ladataan Whisper-malli (\(MeetingTranscriber.whisperModel))")
        let whisper = try await transcriber.loadWhisper()
        let file = try Self.open(output, title: title, appending: second > 0)
        defer { try? file.close() }

        var done = Int(second * Double(Self.sampleRate))
        var heard: [(language: String?, seconds: Float)] = []
        var length = 0
        var grewAt = Date.now
        progress("Litteroidaan sitä mukaa kuin nauhoitus etenee")
        while true {
            let ongoing = recording() && Date.now.timeIntervalSince(grewAt) < Self.stalled
            let (audio, total) = try Self.samples(of: track, from: done, upTo: Self.longestWindow, ongoing: ongoing)
            if total > length {
                length = total
                grewAt = .now
            }
            guard let cut = Self.cut(audio, final: !ongoing) else {
                if !ongoing { break }
                try await Task.sleep(for: .seconds(5))
                continue
            }
            for text in try await transcribed(Array(audio[..<cut]), at: done, with: whisper, heard: &heard) {
                try file.write(contentsOf: Data((text + "\n\n").utf8))
                line(text)
            }
            done += cut
        }
    }

    /// The Markdown file with its heading, or the one already there when a run picks up midway.
    private static func open(_ output: URL, title: String, appending: Bool) throws -> FileHandle {
        if !appending || !FileManager.default.fileExists(atPath: output.path) {
            try "# Live: \(title)\n\n".write(to: output, atomically: true, encoding: .utf8)
        }
        let file = try FileHandle(forWritingTo: output)
        try file.seekToEnd()
        return file
    }

    /// Up to `count` samples of the track from sample `start` on, and the track's length. A track
    /// being written may end in half a frame, so while the recording runs its last 0.1 s waits.
    static func samples(of track: URL, from start: Int, upTo count: Int, ongoing: Bool) throws -> (samples: [Float], total: Int) {
        let file = try AVAudioFile(forReading: track)
        let format = file.processingFormat
        guard format.sampleRate == Double(sampleRate), format.channelCount == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(track.lastPathComponent) ei ole 16 kHz mono."])
        }
        let total = Int(file.length)
        let available = total - start - (ongoing ? sampleRate / 10 : 0)
        guard available > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(count, available)))
        else { return ([], total) }
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        guard let channel = buffer.floatChannelData?[0] else { return ([], total) }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), total)
    }

    /// Where the next window of `audio` ends. Once the recording is over, the rest is one window
    /// when it fits in 30 s. Otherwise the window ends in the middle of the quietest 0.4 s of its
    /// last 15 s, so no word is cut in two, the later of two as quiet. Nil while the recording
    /// runs and less than 15 s waits, or nothing does.
    static func cut(_ audio: [Float], final: Bool) -> Int? {
        if final, audio.count <= longestWindow {
            return audio.count >= sampleRate / 2 ? audio.count : nil
        }
        guard audio.count >= shortestWindow else { return nil }
        let frame = sampleRate / 10
        let span = 4
        let end = min(audio.count, longestWindow)
        let first = max(5 * sampleRate, end - 15 * sampleRate) / frame
        let frames = end / frame
        let energy = (first..<frames).map { index in
            audio[index * frame..<(index + 1) * frame].reduce(0) { $0 + $1 * $1 }
        }
        var quietest = 0
        var lowest = Float.infinity
        for start in 0...(energy.count - span) {
            let sum = energy[start..<start + span].reduce(0, +)
            if sum <= lowest {
                lowest = sum
                quietest = start
            }
        }
        return (first + quietest) * frame + span * frame / 2
    }

    /// The window's lines with the time of the meeting each starts at. Whisper names the
    /// window's language; a window under 5 s, or one in neither Finnish nor English, is
    /// transcribed again in the language most of the meeting so far is in.
    private func transcribed(
        _ window: [Float],
        at start: Int,
        with whisper: WhisperKit,
        heard: inout [(language: String?, seconds: Float)]
    ) async throws -> [String] {
        let seconds = Float(window.count) / Float(Self.sampleRate)
        var results = try await whisper.transcribe(audioArray: window, decodeOptions: Self.options(in: nil))
        let main = MeetingTranscriber.mainLanguage(of: heard)
        if MeetingTranscriber.needsAnotherPass(results.first?.language, seconds: seconds, in: main) {
            results = try await whisper.transcribe(audioArray: window, decodeOptions: Self.options(in: main))
        }
        heard.append((results.first?.language, seconds))
        return Self.lines(results.flatMap(\.segments).map { ($0.start, $0.text) }, at: Float(start) / Float(Self.sampleRate))
    }

    private static func options(in language: Language?) -> DecodingOptions {
        var options = MeetingTranscriber.options(in: language)
        options.wordTimestamps = false
        return options
    }

    static func lines(_ segments: [(start: Float, text: String)], at offset: Float) -> [String] {
        segments.compactMap { start, text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "[\(Transcript.timestamp(offset + start))] \(text)"
        }
    }
}
