import Foundation
import SpeakerKit
import WhisperKit

enum SpeakerLabels {
    static let me = "Minä"

    static func name(for speaker: SpeakerInfo) -> String {
        switch speaker {
        case .speakerId(let id): "Puhuja \(id + 1)"
        case .multiple: "Päällekkäin"
        case .noMatch: "Tuntematon"
        @unknown default: "Tuntematon"
        }
    }

    static func utterances(from segments: [SpeakerSegment]) -> [Utterance] {
        merged(segments.map {
            Utterance(speaker: name(for: $0.speaker), start: $0.startTime, end: $0.endTime, text: $0.text)
        })
    }

    static func ownUtterances(from results: [TranscriptionResult]) -> [Utterance] {
        merged(results.flatMap(\.segments).map {
            Utterance(speaker: me, start: $0.start, end: $0.end, text: $0.text)
        })
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
