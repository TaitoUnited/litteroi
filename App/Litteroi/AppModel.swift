import AppKit
import AVFoundation
import LitteroiCore

/// Records one meeting into `~/Litteroi/<yyyy-mm-dd-hhmm>/`: the microphone, the call and, when
/// asked, every display. The screens can be switched on and off midway. Transcription waits
/// until the user asks Claude Code's litteroi skill for it, so the app quits as soon as the
/// recording is saved.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var isRecording = false
    @Published private(set) var recordsScreens = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var recordingError: String?
    @Published private(set) var callError: String?
    @Published private(set) var screenError: String?

    /// A recording starts without a window, which opens when something went wrong.
    var needsAttention: Bool {
        recordingError != nil || callError != nil || screenError != nil
    }

    private var folder: MeetingFolder?
    private var mic: MicRecorder?
    private var call: SystemAudioRecorder?
    private var screens: ScreenRecorder?
    private var screenSwitch: Task<Void, Never>?
    private var startedAt = Date()
    private var ticker: Timer?
    private var wantsRecording = false

    func startRecording(screens recordScreens: Bool) async {
        guard !isRecording else { return }
        wantsRecording = true
        recordingError = nil
        callError = nil
        screenError = nil
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
        writeRecordingMode()
        setScreens(recordScreens)
        await screenSwitch?.value
    }

    /// Switches are done one after another, so a quick on and off leaves the last one in force.
    func setScreens(_ on: Bool) {
        let previous = screenSwitch
        screenSwitch = Task {
            await previous?.value
            if on {
                await startScreens()
            } else {
                await stopScreens()
            }
        }
    }

    private func startScreens() async {
        guard isRecording, screens == nil, let folder else { return }
        screenError = nil
        let screens = ScreenRecorder()
        self.screens = screens
        do {
            try await screens.start(in: folder, at: Int(Date.now.timeIntervalSince(startedAt).rounded()))
            recordsScreens = true
        } catch {
            screenError = String(localized: "Näyttöjä ei nauhoiteta: \(error.localizedDescription)")
            await screens.stop()
            self.screens = nil
        }
        writeRecordingMode()
    }

    private func stopScreens() async {
        guard let screens else { return }
        self.screens = nil
        recordsScreens = false
        writeRecordingMode()
        await screens.stop()
    }

    /// `litteroi-cli status` and the call watcher read it.
    private func writeRecordingMode() {
        guard let folder else { return }
        let mode: MeetingFolder.RecordingMode = screens == nil ? .audio : .audioAndVideo
        try? mode.rawValue.write(to: folder.recordingModeFile, atomically: true, encoding: .utf8)
    }

    /// Stops the recording and saves every track. One under two seconds is deleted as a slip.
    func stopRecording() async {
        wantsRecording = false
        guard isRecording, let folder else { return }
        ticker?.invalidate()
        mic?.stop()
        call?.stop()
        mic = nil
        call = nil
        isRecording = false
        await screenSwitch?.value
        let screens = self.screens
        self.screens = nil
        recordsScreens = false
        await screens?.stop()
        self.folder = nil
        try? FileManager.default.removeItem(at: folder.recordingModeFile)
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
