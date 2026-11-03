import Foundation

/// One meeting under `~/Litteroi/<yyyy-mm-dd-hhmm>/`: the two audio tracks, the transcript and,
/// once Claude has finished it, the corrected transcript and the minutes.
public struct MeetingFolder: Hashable, Sendable {
    public static let defaultRoot = URL.homeDirectory.appending(path: "Litteroi")

    public enum Stage: String, Sendable {
        case recorded = "litteroimatta"
        case transcribed = "litteroitu"
        case finished = "valmis"
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var title: String { url.lastPathComponent }
    public var mic: URL { url.appending(path: "mic.caf") }
    public var call: URL { url.appending(path: "call.caf") }
    public var transcript: URL { url.appending(path: "transcript.md") }
    public var transcriptJSON: URL { url.appending(path: "transcript.json") }
    /// What Claude reads and writes, with the listed names hidden.
    public var claudeFolder: URL { url.appending(path: "claude") }
    /// Puts the hidden names back. Never read by Claude.
    public var key: URL { url.appending(path: "avain.json") }
    public var minutes: URL { url.appending(path: "muistio.md") }

    /// Nil for a folder without a recording. A finished meeting stays finished once its audio
    /// is deleted.
    public var stage: Stage? {
        let files = FileManager.default
        if files.fileExists(atPath: minutes.path) { return .finished }
        if files.fileExists(atPath: transcript.path) { return .transcribed }
        return files.fileExists(atPath: mic.path) ? .recorded : nil
    }

    /// Creates the folder for a meeting that starts at `date`. A second meeting in the same
    /// minute gets a suffix, so no recording is overwritten.
    public static func create(in root: URL = defaultRoot, startingAt date: Date = .now) throws -> MeetingFolder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: date)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for number in 1...99 {
            let url = root.appending(path: number == 1 ? name : "\(name)-\(number)")
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return MeetingFolder(url: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Every meeting with a recording, oldest first.
    public static func all(in root: URL = defaultRoot) -> [MeetingFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .map { MeetingFolder(url: root.appending(path: $0)) }
            .filter { $0.stage != nil }
            .sorted { $0.title < $1.title }
    }

    /// Meetings that have a recording but no transcript yet, oldest first.
    public static func pending(in root: URL = defaultRoot) -> [MeetingFolder] {
        all(in: root).filter { $0.stage == .recorded }
    }

    /// How long the audio of a finished meeting is kept, counted from when its minutes were
    /// written. Transcripts and minutes are kept.
    public static let audioKept: TimeInterval = 14 * 24 * 60 * 60

    /// Deletes both tracks of every meeting whose minutes are older than `audioKept`, and
    /// returns those meetings. A meeting not finished yet keeps its audio.
    @discardableResult
    public static func deleteOldAudio(in root: URL = defaultRoot, now: Date = .now) -> [MeetingFolder] {
        let files = FileManager.default
        return all(in: root).filter { meeting in
            guard meeting.stage == .finished,
                  files.fileExists(atPath: meeting.mic.path) || files.fileExists(atPath: meeting.call.path),
                  let written = try? meeting.minutes.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(written) > audioKept
            else { return false }
            try? files.removeItem(at: meeting.mic)
            try? files.removeItem(at: meeting.call)
            return true
        }
    }
}
