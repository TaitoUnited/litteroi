import Accelerate
import Foundation

/// A meeting held in one room around the user's Mac while a call ran on it, as on 23.11.2026, when
/// a colleague's laptop was in the call and the user's call track held sound for 4 % of the
/// recording. The mic track then holds everyone, so its speakers are told apart, as without a call.
struct RoomMeeting {
    /// The call track holds sound for less than this share of the recording. Of the 20 meetings
    /// with both tracks on 23.11.2026, the room meeting had 4 % and the others 18 % to 59 %.
    static let callShare: Float = 0.1
    /// A voice counts with this much speech on the mic while the call is silent, in seconds.
    static let voiceSeconds: Float = 30
    /// The user sits at the Mac, so their voice is the one this many dB above every other voice.
    /// On 23.11.2026 the user's was 8 dB above the two others'.
    static let nearer: Float = 6
    /// What the mic hears this long before or after the call's sound may be the call, in frames:
    /// the two recorders start up to 2 s apart.
    static let margin = 20
    static let frame = 1_600
    /// The level over which 100 ms of a track holds sound, as in `MeetingTranscriber.hasSound`.
    static let loud: Float = 0.005

    /// The speaker whose voice is nearest the mic, the user's, when one stands out, and by how
    /// many dB it does.
    var own: Int?
    var lead: Float
    var voices: Int
    /// How long the call track holds sound and how long the recording is, in seconds.
    var callSeconds: Int
    var seconds: Int

    /// Whether the call track holds sound for a small enough part of a recording of `samples`.
    static func callIsBrief(_ call: [Float], of samples: Int) -> Bool {
        Float(levels(call).filter { $0 > loud }.count) < callShare * Float(samples / frame)
    }

    /// Nil unless the mic holds two voices or more while the call is silent. `speech` is who
    /// speaks when on the mic track.
    init?(mic: [Float], call: [Float], speech: [(speaker: Int, start: Float, end: Float)]) {
        let micLevels = Self.levels(mic)
        let callLoud = Self.levels(call).map { $0 > Self.loud }
        let heard = Self.voices(of: speech, levels: micLevels, callLoud: callLoud)
        guard heard.count >= 2 else { return nil }
        let nearest = heard.max { $0.level < $1.level }!
        lead = nearest.level - heard.filter { $0.speaker != nearest.speaker }.map(\.level).max()!
        own = lead >= Self.nearer ? nearest.speaker : nil
        voices = heard.count
        callSeconds = callLoud.filter { $0 }.count / 10
        seconds = max(micLevels.count, callLoud.count) / 10
    }

    /// What the transcript says of the meeting under its title, `me` being the user's label.
    func note(me: String) -> String {
        "Huonepalaveri: puhelun raidalla on ääntä vain \(callSeconds) s nauhoituksen \(seconds) s:sta, ja sen ollessa "
            + "hiljaa mikrofoniin puhuu \(voices) ääntä. Puhujat on siksi eroteltu mikrofonin raidalta, ja puhelun raita on "
            + "jätetty pois. "
            + (own == nil
                ? "Mikään ääni ei kuulu mikrofoniin selvästi muita kovempaa, joten käyttäjän omaa ääntä ei ole nimetty."
                : "Nimen \(me) sai ääni, joka kuuluu mikrofoniin \(Int(lead.rounded())) dB muita kovempaa, eli luultavasti "
                    + "sitä lähinnä istunut.")
    }

    /// Each speaker with `voiceSeconds` or more of speech on the mic while the call is silent, and
    /// the median level of that speech in dB.
    static func voices(
        of speech: [(speaker: Int, start: Float, end: Float)],
        levels: [Float],
        callLoud: [Bool]
    ) -> [(speaker: Int, seconds: Float, level: Float)] {
        var nearCall = [Bool](repeating: false, count: levels.count)
        for index in callLoud.indices where callLoud[index] {
            for near in max(0, index - margin)..<min(levels.count, index + margin + 1) {
                nearCall[near] = true
            }
        }
        var heard: [Int: [Float]] = [:]
        for turn in speech {
            let first = max(0, Int(turn.start * 10))
            let last = min(levels.count, Int((turn.end * 10).rounded(.up)))
            guard first < last else { continue }
            for index in first..<last where !nearCall[index] {
                heard[turn.speaker, default: []].append(20 * log10(max(levels[index], 1e-6)))
            }
        }
        return heard.filter { Float($0.value.count) / 10 >= voiceSeconds }
            .map { (speaker: $0.key, seconds: Float($0.value.count) / 10, level: $0.value.sorted()[$0.value.count / 2]) }
            .sorted { $0.speaker < $1.speaker }
    }

    /// The RMS of each 100 ms of the audio.
    static func levels(_ audio: [Float]) -> [Float] {
        audio.withUnsafeBufferPointer { samples in
            stride(from: 0, to: samples.count - frame + 1, by: frame).map {
                vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: samples[$0..<$0 + frame]))
            }
        }
    }
}
