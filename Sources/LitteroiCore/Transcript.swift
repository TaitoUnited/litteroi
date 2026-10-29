import Foundation

public struct Utterance: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Float
    public var end: Float
    public var text: String

    public init(speaker: String, start: Float, end: Float, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var utterances: [Utterance]

    public init(utterances: [Utterance]) {
        self.utterances = utterances
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appending(path: "transcript.json"))
    }

    static func timestamp(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
