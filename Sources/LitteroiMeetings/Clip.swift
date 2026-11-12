import Foundation

/// The seconds of the meeting between which the part of a line that a question quotes is said.
/// A line carries the time its utterance starts, and an utterance can run for minutes, so the
/// page plays a quoted part from its own first word. Without word times the clip is the line
/// from its start, with no end.
struct Clip: Equatable {
    var start: Double
    var end: Double?
}

/// A transcript line's times and words as `transcript.json` holds them.
public struct TimedLine: Decodable, Sendable {
    public struct Word: Decodable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var start: Double
    public var end: Double
    public var words: [Word]?

    public init(start: Double, end: Double, words: [Word]? = nil) {
        self.start = start
        self.end = end
        self.words = words
    }

    /// The lines of a meeting's `transcript.json`, none when it cannot be read.
    public static func read(_ file: URL) -> [TimedLine] {
        struct Transcript: Decodable { var utterances: [TimedLine] }
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode(Transcript.self, from: data))?.utterances ?? []
    }

    /// Where `quote` is said on the line that starts at `second`: the line as the corrected
    /// transcript words it, cut to its parts that matter with `...`. Whisper's words differ from
    /// the corrected ones, so each part is matched to the stretch of words most like it, in order.
    static func clip(of quote: String, at second: Int, in lines: [TimedLine]) -> Clip? {
        lines.filter { Int($0.start) == second }
            .compactMap { $0.clip(of: quote) }
            .max { $0.score < $1.score }?.clip
    }

    func clip(of quote: String) -> (clip: Clip, score: Int)? {
        guard let words, !words.isEmpty else { return nil }
        // A word such as "AWS-tunnuksista" is two tokens of one word.
        let heard = words.indices.flatMap { index in Self.tokens(words[index].text).map { (token: $0, word: index) } }
        let parts = quote.replacing("…", with: "...").replacing(#/\[[^\]]*\]/#, with: " ")
            .split(separator: "...").map { Self.tokens(String($0)) }.filter { !$0.isEmpty }
        var from = 0
        var first: Int?
        var last: Int?
        var score = 0
        for part in parts {
            guard let match = Self.fit(part, into: heard[from...].map(\.token)) else { continue }
            first = first ?? heard[from + match.first].word
            last = heard[from + match.last].word
            score += match.score
            from += match.last + 1
        }
        guard let first, let last else { return nil }
        return (Clip(start: words[first].start, end: words[last].end), score)
    }

    static func tokens(_ text: String) -> [[Character]] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(Array.init)
    }

    /// The stretch of `heard` that reads most like `part`, all of `part` against any run of
    /// `heard`: the indices of its first and last token. Nil when under half of `part` is there.
    static func fit(_ part: [[Character]], into heard: [[Character]]) -> (first: Int, last: Int, score: Int)? {
        guard !part.isEmpty, !heard.isEmpty else { return nil }
        // score[i][j]: the first i tokens of the part, ending at token j of the heard ones.
        var score = [[Int]](repeating: [Int](repeating: 0, count: heard.count + 1), count: part.count + 1)
        for i in 1...part.count {
            score[i][0] = -i
            for j in 1...heard.count {
                score[i][j] = max(score[i - 1][j - 1] + likeness(part[i - 1], heard[j - 1]),
                                  score[i - 1][j] - 1, score[i][j - 1] - 1)
            }
        }
        var j = (1...heard.count).max { score[part.count][$0] < score[part.count][$1] }!
        // max(by:) returns the last of equal ones, and the earliest stretch is the one quoted.
        j = (1...j).first { score[part.count][$0] == score[part.count][j] }!
        let best = score[part.count][j]
        guard best * 2 >= part.count else { return nil }
        var i = part.count
        var first: Int?
        var last: Int?
        while i > 0, j > 0 {
            if score[i][j] == score[i - 1][j - 1] + likeness(part[i - 1], heard[j - 1]) {
                last = last ?? j - 1
                first = j - 1
                i -= 1
                j -= 1
            } else if score[i][j] == score[i - 1][j] - 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        guard let first, let last else { return nil }
        return (first, last, best)
    }

    /// 2 for the same token, 1 for one a letter or two off, as a corrected ending is, else -1.
    static func likeness(_ a: [Character], _ b: [Character]) -> Int {
        if a == b { return 2 }
        let shorter = min(a.count, b.count)
        guard shorter >= 4, abs(a.count - b.count) <= 2 else { return -1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let next = min(previous + (a[i - 1] == b[j - 1] ? 0 : 1), row[j] + 1, row[j - 1] + 1)
                previous = row[j]
                row[j] = next
            }
        }
        return row[b.count] <= (shorter >= 7 ? 2 : 1) ? 1 : -1
    }
}
