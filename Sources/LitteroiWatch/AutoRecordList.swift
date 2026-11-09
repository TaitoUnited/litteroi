import Foundation

/// The apps and sites whose calls Litteroi records on its own, one a line in
/// `~/Litteroi/automaattiset.txt`: a call app's name, such as Teams, or a site's host, such as
/// meet.google.com. A line starting with # is a comment. The user adds one from the prompt that a
/// new app or site gets, and removes one from the watcher's menu or in the file.
public struct AutoRecordList: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public var entries: [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public func contains(_ source: String) -> Bool {
        entries.contains { Self.same($0, source) }
    }

    public func add(_ source: String) throws {
        guard !contains(source) else { return }
        try write(lines + [source])
    }

    public func remove(_ source: String) throws {
        try write(lines.filter { !Self.same($0.trimmingCharacters(in: .whitespaces), source) })
    }

    private var lines: [String] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.map { $0 + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
    }

    private static func same(_ entry: String, _ source: String) -> Bool {
        entry.caseInsensitiveCompare(source) == .orderedSame
    }
}
