import Foundation
import SpeakerKit
import WhisperKit

/// Labels in the meeting's language, since Claude and the user read them in the transcript.
enum SpeakerLabels {
    /// The user's own track carries their first name, as the user asked, in either language.
    static func me(in language: Language, fullName: String = NSFullUserName()) -> String {
        fullName.split(separator: " ").first.map(String.init) ?? (language == .fi ? "Minä" : "Me")
    }

    /// Every label the user's own track has carried: `Minä` and `Me` until 5.11.2026.
    static var own: Set<String> { [me(in: .fi), me(in: .en), "Minä", "Me"] }

    static func name(for speaker: SpeakerInfo, in language: Language) -> String {
        let fi = language == .fi
        switch speaker {
        case .speakerId(let id): return (fi ? "Puhuja " : "Speaker ") + String(id + 1)
        case .multiple: return fi ? "Päällekkäin" : "Overlapping"
        case .noMatch: return fi ? "Tuntematon" : "Unknown"
        @unknown default: return fi ? "Tuntematon" : "Unknown"
        }
    }

    /// The lines of one speaker under another label, as the user's own voice in a room meeting.
    static func renamed(_ utterances: [Utterance], from speaker: SpeakerInfo, to label: String, in language: Language) -> [Utterance] {
        let old = name(for: speaker, in: language)
        return merged(utterances.map { utterance in
            var utterance = utterance
            if utterance.speaker == old { utterance.speaker = label }
            return utterance
        })
    }

    static func utterances(from segments: [SpeakerSegment], in language: Language) -> [Utterance] {
        merged(segments.map {
            Utterance(speaker: name(for: $0.speaker, in: language), start: $0.startTime, end: $0.endTime, text: $0.text,
                      words: words($0.speakerWords.map(\.wordTiming)))
        })
    }

    static func words(_ timings: [WordTiming]?) -> [Word]? {
        timings?.compactMap { timing in
            let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Word(start: timing.start, end: timing.end, text: text)
        }
    }

    /// One piece per Whisper segment, joined only once the call's lines are in between.
    static func ownPieces(from results: [TranscriptionResult], in language: Language) -> [Utterance] {
        results.flatMap(\.segments).map {
            Utterance(speaker: me(in: language), start: $0.start, end: $0.end, text: $0.text, words: words($0.words))
        }
    }

    /// Cuts each utterance at the first sentence end after a line of the other track starts inside
    /// it. A call with one speaker is otherwise one utterance from its first turn to its last, and
    /// every line of the user's own sorts after its start and merges into one line too.
    static func split(_ utterances: [Utterance], at starts: [Float]) -> [Utterance] {
        utterances.flatMap { utterance -> [Utterance] in
            guard let words = utterance.words, words.count > 1 else { return [utterance] }
            let cuts = Set(starts.filter { $0 > utterance.start && $0 < utterance.end }.compactMap { start in
                words.indices.dropFirst().first { words[$0].start >= start && endsSentence(words[$0 - 1].text) }
            }).sorted()
            guard !cuts.isEmpty else { return [utterance] }
            let bounds = [0] + cuts + [words.count]
            return zip(bounds, bounds.dropFirst()).map { from, to in
                let part = Array(words[from..<to])
                return Utterance(speaker: utterance.speaker,
                                 start: from == 0 ? utterance.start : part.map(\.start).min()!,
                                 end: to == words.count ? utterance.end : part.map(\.end).max()!,
                                 text: part.map(\.text).joined(separator: " "), words: part)
            }
        }
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.last.map { ".?!…".contains($0) } ?? false
    }

    /// Joins consecutive pieces from the same speaker into one utterance and drops empty ones.
    static func merged(_ pieces: [Utterance]) -> [Utterance] {
        var result: [Utterance] = []
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = result.last, last.speaker == piece.speaker {
                last.text += " " + text
                last.end = piece.end
                if last.words != nil || piece.words != nil { last.words = (last.words ?? []) + (piece.words ?? []) }
                result[result.count - 1] = last
            } else {
                result.append(Utterance(speaker: piece.speaker, start: piece.start, end: piece.end, text: text, words: piece.words))
            }
        }
        return result
    }
}
