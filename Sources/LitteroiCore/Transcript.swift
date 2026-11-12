import Foundation

/// The languages a meeting is transcribed in, by Whisper's codes.
public enum Language: String, Sendable {
    case fi, en
}

/// One word as Whisper heard it, with the seconds of the meeting it runs from and to.
public struct Word: Codable, Equatable, Sendable {
    public var start: Float
    public var end: Float
    public var text: String

    public init(start: Float, end: Float, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Float
    public var end: Float
    public var text: String
    /// When each word was said, which the meeting's page plays a quoted part of the line from. An
    /// utterance can run for minutes, so its start alone is far from most of its words. Nil in a
    /// transcript from before 10.11.2026, until `litteroi-cli words` adds them.
    public var words: [Word]?

    public init(speaker: String, start: Float, end: Float, text: String, words: [Word]? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var utterances: [Utterance]

    public init(utterances: [Utterance]) {
        self.utterances = utterances
    }

    /// This transcript with the word times of `timed`, another transcription of the same
    /// recording, and nothing else of it: each utterance takes the words said on its own track
    /// from its start to its end. `own` holds the labels of the user's track, which `timed` and
    /// this transcript may name differently.
    public func addingWords(from timed: Transcript, own: Set<String>) -> Transcript {
        let split = utterances.contains { own.contains($0.speaker) } && utterances.contains { !own.contains($0.speaker) }
        func track(_ utterance: Utterance) -> Bool { split && own.contains(utterance.speaker) }
        var result = self
        for mine in [true, false] {
            let words = timed.utterances.filter { track($0) == mine }.flatMap { $0.words ?? [] }
                .sorted { $0.start < $1.start }
            var next = 0
            for index in result.utterances.indices where track(result.utterances[index]) == mine {
                let utterance = result.utterances[index]
                while next < words.count, words[next].start < utterance.start - 0.5 { next += 1 }
                var taken: [Word] = []
                while next < words.count, words[next].start <= utterance.end + 0.01 {
                    taken.append(words[next])
                    next += 1
                }
                result.utterances[index].words = taken.isEmpty ? nil : taken
            }
        }
        return result
    }

    public func markdown(title: String) -> String {
        var lines = ["# \(title)", ""]
        for utterance in utterances {
            lines.append("[\(Self.timestamp(utterance.start))] **\(utterance.speaker):** \(utterance.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func write(to folder: URL, title: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try markdown(title: title).write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
        try writeJSON(to: folder.appending(path: "transcript.json"))
    }

    public func writeJSON(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public static func read(_ file: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: file))
    }

    static func timestamp(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
