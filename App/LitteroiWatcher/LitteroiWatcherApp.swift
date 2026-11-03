import AppKit
import Carbon.HIToolbox
import LitteroiMeetings
import LitteroiWatch
import SwiftUI

@main
struct LitteroiWatcherApp: App {
    @NSApplicationDelegateAdaptor(WatcherDelegate.self) private var delegate
    @ObservedObject private var watcher = CallWatcher.shared

    var body: some Scene {
        MenuBarExtra {
            Text(watcher.status)
            if watcher.untranscribed > 0 {
                Text("\(watcher.untranscribed) nauhoitusta litteroimatta")
            }
            if watcher.recording {
                Button("Näytä nauhoitus") { CallWatcher.openLitteroi() }
            } else {
                Button("Nauhoita Litteroilla") { CallWatcher.shared.startRecording() }
            }
            Text("Control-Optio-L aloittaa tai lopettaa nauhoituksen")
            Button("Avaa Litteroi-kansio") { CallWatcher.openMeetings() }
        } label: {
            HStack {
                Image(systemName: watcher.recording ? "record.circle" : watcher.call == nil ? "waveform" : "waveform.badge.mic")
                if watcher.untranscribed > 0 {
                    Text(watcher.untranscribed, format: .number)
                }
            }
        }
    }
}

/// Runs in the menu bar from login on, and launchd starts it again whenever it exits. Once a call
/// app has held the microphone for a few seconds, a prompt offers to record; it never records on
/// its own, since the participants have to be told first. Once the call app has let go of the
/// microphone for a few seconds, a recording it started for that call gets a prompt offering to
/// stop it. It also counts the recordings not transcribed yet and deletes the audio of meetings
/// finished long ago.
@MainActor
final class CallWatcher: ObservableObject {
    static let shared = CallWatcher()

    @Published private(set) var call: String?
    @Published private(set) var recording = false
    @Published private(set) var untranscribed = 0
    private var detector = CallDetector()
    private var timer: Timer?
    private var nextCleanup = Date.distantPast
    private var startingForCallUntil = Date.distantPast
    private var recordingForCall = false

    func start() {
        RecordShortcut.register()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { CallWatcher.shared.poll() }
        }
    }

    /// Checked against the clock rather than a long timer, which pauses while the Mac sleeps.
    private func poll() {
        if Date.now >= nextCleanup {
            MeetingFolder.deleteOldAudio()
            nextCleanup = .now + 60 * 60
        }
        let pending = MeetingFolder.pending().count
        // While Litteroi runs, the newest of them is the meeting it records.
        let untranscribed = Self.litteroiRunning ? max(pending - 1, 0) : pending
        if self.untranscribed != untranscribed {
            self.untranscribed = untranscribed
        }
        let micUsers = AudioProcesses.micUsers()
        if recording != micUsers.contains(CallDetector.litteroi) {
            recording.toggle()
            recordingForCall = recording && Date.now < startingForCallUntil
            CallPrompt.close()
        }
        switch detector.update(micUsers: micUsers) {
        case .started(let app, let litteroiRecording):
            call = app
            if !litteroiRecording {
                CallPrompt.show(title: String(localized: "Palaveri alkoi (\(app))"),
                                message: String(localized: "Litteroidaanko? Kerro osallistujille ennen nauhoitusta."),
                                action: "Nauhoita") { CallWatcher.shared.startRecording() }
            }
        case .quiet:
            if recording, recordingForCall, let call {
                CallPrompt.show(title: String(localized: "Palaveri päättyi (\(call))"),
                                message: String(localized: "Litteroi nauhoittaa yhä. Lopetetaanko ja tallennetaan?"),
                                action: "Lopeta ja tallenna") { CallWatcher.stopRecording() }
            }
        case .resumed:
            if recording {
                CallPrompt.close()
            }
        case .ended:
            if !recording {
                CallPrompt.close()
            }
            call = nil
        case nil:
            break
        }
    }

    var status: String {
        if recording {
            return String(localized: "Litteroi nauhoittaa")
        }
        if let call {
            return String(localized: "Palaveri käynnissä (\(call))")
        }
        return String(localized: "Odottaa palaveria")
    }

    /// A recording opened during a call is for that call, so its end offers to stop it.
    func startRecording() {
        if call != nil {
            startingForCallUntil = .now + 30
        }
        Self.openLitteroi()
    }

    /// Litteroi saves the recording when it quits.
    static func stopRecording() {
        NSRunningApplication.runningApplications(withBundleIdentifier: CallDetector.litteroi).first?.terminate()
    }

    func toggleRecording() {
        CallPrompt.close()
        if Self.litteroiRunning {
            Self.stopRecording()
        } else {
            startRecording()
        }
    }

    private static var litteroiRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: CallDetector.litteroi).isEmpty
    }

    /// The watcher lives in Litteroi.app/Contents/Library/LoginItems.
    static func openLitteroi() {
        var litteroi = Bundle.main.bundleURL
        for _ in 1...4 {
            litteroi.deleteLastPathComponent()
        }
        NSWorkspace.shared.openApplication(at: litteroi, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openMeetings() {
        try? FileManager.default.createDirectory(at: MeetingFolder.defaultRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingFolder.defaultRoot)
    }
}

/// Control-Option-L starts a recording from any app, or stops the one going on. A Carbon hot key
/// needs no accessibility permission, unlike a global key event monitor.
enum RecordShortcut {
    private static var hotKey: EventHotKeyRef?

    static func register() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { CallWatcher.shared.toggleRecording() }
            return noErr
        }, 1, &pressed, nil, nil)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x4C54_5249), id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr {
            NSLog("LitteroiWatcher: Control-Option-L not registered: \(status)")
        }
    }
}

final class WatcherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { CallWatcher.shared.start() }
    }
}
