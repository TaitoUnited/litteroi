import Foundation
import SpeakerKit
import WhisperKit

/// Labels in the meeting's language, since Claude and the user read them in the transcript.
enum SpeakerLabels {
    static func me(in language: Language) -> String {
        language == .fi ? "Minä" : "Me"
    }

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
            Utterance(speaker: name(for: $0.speaker, in: language), start: $0.startTime, end: $0.endTime, text: $0.text)
        })
    }

    /// One piece per Whisper segment, joined only once the call's lines are in between.
    static func ownPieces(from results: [TranscriptionResult], in language: Language) -> [Utterance] {
        results.flatMap(\.segments).map {
            Utterance(speaker: me(in: language), start: $0.start, end: $0.end, text: $0.text)
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
                result[result.count - 1] = last
            } else {
                result.append(Utterance(speaker: piece.speaker, start: piece.start, end: piece.end, text: text))
            }
        }
        return result
    }
}
