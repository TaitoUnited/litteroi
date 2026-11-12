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
