import AppKit
import AVFoundation
import LitteroiCore

/// Records one meeting into `~/Litteroi/<yyyy-mm-dd-hhmm>/`. Transcription waits until the user
/// asks Claude Code's litteroi skill for it, so the app quits as soon as the recording is saved.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var recordingError: String?
    @Published private(set) var callError: String?

    private var folder: MeetingFolder?
    private var mic: MicRecorder?
    private var call: SystemAudioRecorder?
    private var startedAt = Date()
    private var ticker: Timer?
    private var wantsRecording = false

    func startRecording() async {
        guard !isRecording else { return }
        wantsRecording = true
        recordingError = nil
        callError = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            recordingError = String(localized: "Mikrofonin käyttö on estetty. Salli se Litteroille järjestelmän asetuksista ja avaa Litteroi uudelleen.")
            return
        }
        guard wantsRecording else { return }

        do {
            let folder = try MeetingFolder.create()
            let mic = try MicRecorder(url: folder.mic)
            try mic.start()
            self.folder = folder
            self.mic = mic
        } catch {
            recordingError = String(localized: "Nauhoitus ei käynnistynyt: \(error.localizedDescription)")
            return
        }
        do {
            let call = try SystemAudioRecorder(url: folder!.call)
            try call.start()
            self.call = call
        } catch {
            callError = String(localized: "Puhelun ääntä ei nauhoiteta: \(error.localizedDescription)")
        }

        isRecording = true
        startedAt = .now
        elapsed = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops the recording and saves both tracks. One under two seconds is deleted as a slip.
    func stopRecording() {
        wantsRecording = false
        guard isRecording, let folder else { return }
        ticker?.invalidate()
        mic?.stop()
        call?.stop()
        mic = nil
        call = nil
        self.folder = nil
        isRecording = false
        if elapsed < 2 {
            try? FileManager.default.removeItem(at: folder.url)
        }
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = mic?.writer.level ?? 0
        callLevel = call?.writer.level ?? 0
    }
}
