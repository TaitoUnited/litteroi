import AVFoundation

/// Copies a meeting's recordings into files the browser plays on its page: both tracks mixed into
/// one AAC file, and each screen video as H.264, since Firefox may not play the recorder's HEVC.
/// A copy newer than its recordings is kept. A screen video that cannot be copied, as one a crash
/// cut off before its first fragment, is passed to `unreadable` and gets no copy.
public enum MeetingMedia {
    public static func export(_ meeting: MeetingFolder, unreadable: (URL) -> Void = { _ in }) async throws {
        let tracks = [meeting.mic, meeting.call].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !tracks.isEmpty, isStale(meeting.listening, from: tracks) {
            let composition = AVMutableComposition()
            for url in tracks {
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            }
            try await export(composition, preset: AVAssetExportPresetAppleM4A, as: .m4a, to: meeting.listening)
        }
        for screen in meeting.screens where isStale(meeting.browserCopy(of: screen), from: [screen]) {
            do {
                try await export(AVURLAsset(url: screen), preset: AVAssetExportPresetHighestQuality, as: .mp4,
                                 to: meeting.browserCopy(of: screen))
            } catch {
                try? FileManager.default.removeItem(at: meeting.browserCopy(of: screen))
                unreadable(screen)
            }
        }
    }

    static func isStale(_ copy: URL, from sources: [URL]) -> Bool {
        func modified(_ url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let copied = modified(copy) else { return true }
        return sources.contains { (modified($0) ?? .distantFuture) > copied }
    }

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: url)
        if #available(macOS 15, *) {
            try await session.export(to: url, as: type)
        } else {
            session.outputURL = url
            session.outputFileType = type
            await session.export()
            if let error = session.error { throw error }
        }
    }
}
