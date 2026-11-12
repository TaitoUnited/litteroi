import AVFoundation
import Vision

/// Reads the names a call app prints on the participants' tiles from the screen videos, on this
/// Mac with macOS's own text recognition, so the skill can tell who was in the meeting without
/// opening the videos. Only lines shaped like a person's name are kept, and only those seen for a
/// while, as tile names stay up for the whole call while other text on the screen comes and goes.
public enum ScreenNames {
    public struct Seen: Equatable, Sendable {
        public var name: String
        public var first: TimeInterval
        public var last: TimeInterval
        public var samples: Int
    }

    /// One frame every `interval` seconds of each video. A video that cannot be opened, as one a
    /// crash cut off before its first fragment, is passed to `unreadable` and left out; nil when
    /// none could be opened.
    public static func read(_ meeting: MeetingFolder, every interval: TimeInterval = 10,
                            unreadable: (URL) -> Void = { _ in }) async throws -> [Seen]? {
        var seen: [String: Seen] = [:]
        var opened = false
        for screen in meeting.screens {
            let asset = AVURLAsset(url: screen)
            guard let duration = try? await asset.load(.duration).seconds else {
                unreadable(screen)
                continue
            }
            opened = true
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)
            let start = TimeInterval(MeetingFolder.start(of: screen))
            for second in stride(from: 0, to: max(duration, 0.1), by: interval) {
                guard let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
                else { continue }
                let time = start + second
                for name in Set(try lines(in: frame).compactMap(personName)) {
                    var entry = seen[name] ?? Seen(name: name, first: time, last: time, samples: 0)
                    entry.first = min(entry.first, time)
                    entry.last = max(entry.last, time)
                    entry.samples += 1
                    seen[name] = entry
                }
            }
        }
        return opened ? kept(Array(seen.values), interval: interval) : nil
    }

    /// Seen over two minutes or more and in at least a third of the frames read meanwhile, after a
    /// name misread by one letter, such as "Mitia" for "Mitja", is counted with the name.
    static func kept(_ seen: [Seen], interval: TimeInterval) -> [Seen] {
        var merged: [Seen] = []
        for entry in seen.sorted(by: { ($0.samples, $0.name) > ($1.samples, $1.name) }) {
            if let index = merged.firstIndex(where: { misread($0.name, entry.name) }) {
                merged[index].first = min(merged[index].first, entry.first)
                merged[index].last = max(merged[index].last, entry.last)
                merged[index].samples += entry.samples
            } else {
                merged.append(entry)
            }
        }
        return merged.filter {
            let span = $0.last - $0.first
            return $0.samples >= 3 && span >= max(120, 2 * interval) && Double($0.samples) >= (span / interval + 1) / 3
        }
        .sorted { ($0.first, $0.name) < ($1.first, $1.name) }
    }

    private static func misread(_ name: String, _ other: String) -> Bool {
        name.count == other.count && zip(name, other).filter { $0 != $1 }.count == 1
    }

    private static func lines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fi-FI", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        // The menu bar, at the top of each display.
        return (request.results ?? []).filter { $0.boundingBox.minY < 0.96 }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// Words the call apps and the browser print beside or instead of a name.
    private static let labels: Set<String> = [
        "Google", "Meet", "Microsoft", "Teams", "Slack", "Huddle", "Zoom", "Present", "Presenting",
        "Esittää", "Esitys", "Guest", "Vieras", "You", "Sinä", "Host", "Isäntä", "Organizer", "Järjestäjä",
        "Ask", "Gemini", "Copilot", "Enter", "Password", "File", "Edit", "View", "History", "Bookmarks",
        "Profiles", "Tools", "Window", "Help", "Task", "Name", "Nimi",
    ]

    /// Two to four words, each a capital letter and then small ones, such as "Pavel Tahkovuori" or
    /// "Anna-Liisa Mäki", with a call app's "(Guest)" or "(You)" after it dropped.
    static func personName(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let bracket = text.firstIndex(of: "(") {
            text = String(text[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        let words = text.split(separator: " ")
        guard (2...4).contains(words.count), text.count <= 40 else { return nil }
        for word in words {
            guard !labels.contains(String(word)) else { return nil }
            for part in word.split(separator: "-", omittingEmptySubsequences: false) {
                guard let first = part.first, first.isUppercase, part.count >= 2,
                      part.dropFirst().allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "'" })
                else { return nil }
            }
        }
        return words.joined(separator: " ")
    }

    /// `nimet-ruudulla.txt`: one name a line, with when it was first and last on screen and in how
    /// many of the frames read.
    public static func write(_ seen: [Seen], to meeting: MeetingFolder) throws {
        let lines = seen.map { "\($0.name)\t\(Transcript.timestamp(Float($0.first)))\t\(Transcript.timestamp(Float($0.last)))\t\($0.samples)" }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: meeting.screenNames, atomically: true, encoding: .utf8)
    }
}
