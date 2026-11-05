import AppKit
import Carbon.HIToolbox
import LitteroiMeetings
import LitteroiWatch
import SwiftUI

@main
struct LitteroiWatcherApp: App {
    @NSApplicationDelegateAdaptor(WatcherDelegate.self) private var delegate
    @ObservedObject private var watcher = CallWatcher.shared

    /// The icon shows only while meetings wait for the litteroi skill in Claude Code, until
    /// Control-Option-H shows or hides it for good.
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { watcher.showsIcon }, set: { watcher.iconShown = $0 })) {
            Text(watcher.status)
            Text("\(watcher.unfinished) palaveria viimeistelemättä")
            Text("Kirjoita litteroi Claude Codessa")
            if watcher.recording {
                Button("Lopeta ja tallenna") { CallWatcher.stopRecording() }
                if watcher.mode == .audioAndVideo {
                    Button("Nauhoita vain ääni") { CallWatcher.shared.record(.audio) }
                } else {
                    Button("Nauhoita myös näyttö") { CallWatcher.shared.record(.audioAndVideo) }
                }
                Button("Näytä nauhoitus") { CallWatcher.openLitteroi() }
            } else {
                Button("Nauhoita Litteroilla") { CallWatcher.shared.startRecording() }
            }
            Text("Control-Optio-T aloittaa tai lopettaa nauhoituksen")
            Text("Control-Optio-V nauhoittaa myös näytön, Control-Optio-A vain äänen")
            Text("Control-Optio-H piilottaa tai näyttää tämän kuvakkeen")
            Button("Avaa Litteroi-kansio") { CallWatcher.openMeetings() }
        } label: {
            HStack {
                Image(systemName: watcher.recording ? watcher.mode == .audioAndVideo ? "video.circle" : "record.circle" : watcher.call == nil ? "waveform" : "waveform.badge.mic")
                Text(watcher.unfinished, format: .number)
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
    @Published private(set) var mode: MeetingFolder.RecordingMode?
    @Published private(set) var unfinished = 0
    @Published var iconShown = UserDefaults.standard.object(forKey: "iconShown") as? Bool {
        didSet { UserDefaults.standard.set(iconShown, forKey: "iconShown") }
    }
    var showsIcon: Bool { iconShown ?? (unfinished > 0) }

    func toggleIcon() {
        iconShown = !showsIcon
    }
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
        let meetings = MeetingFolder.all()
        let waiting = meetings.filter { $0.stage != .finished }.count
        // While Litteroi runs, the newest of them is the meeting it records.
        let running = Self.litteroiRunning
        let unfinished = running ? max(waiting - 1, 0) : waiting
        if self.unfinished != unfinished {
            self.unfinished = unfinished
        }
        let mode = running ? meetings.last?.recordingMode : nil
        if self.mode != mode {
            self.mode = mode
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
                CallPrompt.show(message: String(localized: "Litteroidaanko?"), actions: [
                    .init(title: "Ääni", key: "A") { CallWatcher.shared.record(.audio) },
                    .init(title: "Kuva", key: "V") { CallWatcher.shared.record(.audioAndVideo) },
                ], dismiss: "Ei")
            }
        case .quiet:
            if recording, recordingForCall, let call {
                CallPrompt.show(title: String(localized: "Palaveri päättyi (\(call))"),
                                message: String(localized: "Lopetetaanko litterointi?"),
                                actions: [.init(title: "Lopeta ja tallenna", key: "T") { CallWatcher.stopRecording() }],
                                dismiss: "Ei nyt")
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
            switch mode {
            case .audio: return String(localized: "Litteroi nauhoittaa ääntä")
            case .audioAndVideo: return String(localized: "Litteroi nauhoittaa ääntä ja näyttöä")
            case nil: return String(localized: "Litteroi nauhoittaa")
            }
        }
        if let call {
            return String(localized: "Palaveri käynnissä (\(call))")
        }
        return String(localized: "Odottaa palaveria")
    }

    /// A recording opened during a call is for that call, so its end offers to stop it. The
    /// screens are recorded only when asked for, since macOS shows a purple item in the menu bar
    /// while they are.
    func startRecording(_ mode: MeetingFolder.RecordingMode = .audio) {
        if call != nil {
            startingForCallUntil = .now + 30
        }
        Self.openLitteroi(activating: false, arguments: ["--from-watcher"] + (mode == .audioAndVideo ? ["--video"] : []))
    }

    /// Starts a recording in that mode, or switches the one going on to it.
    func record(_ mode: MeetingFolder.RecordingMode) {
        CallPrompt.close()
        if Self.litteroiRunning {
            DistributedNotificationCenter.default().postNotificationName(mode.notification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
        } else {
            startRecording(mode)
        }
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

    /// The watcher lives in Litteroi.app/Contents/Library/LoginItems. A recording starts without
    /// taking the keyboard from the call app.
    static func openLitteroi(activating: Bool = true, arguments: [String] = []) {
        var litteroi = Bundle.main.bundleURL
        for _ in 1...4 {
            litteroi.deleteLastPathComponent()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: litteroi, configuration: configuration)
    }

    static func openMeetings() {
        try? FileManager.default.createDirectory(at: MeetingFolder.defaultRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingFolder.defaultRoot)
    }
}

/// Control-Option-T starts a recording from any app, or stops the one going on, Control-Option-V
/// records the screens too and Control-Option-A leaves them out, from the start or midway,
/// Control-Option-H hides or shows the menu bar icon and Control-Option-N dismisses a prompt. Carbon hot keys need no accessibility permission, unlike a
/// global key event monitor. Control-Option-N is held only while a prompt shows, so other apps
/// keep it the rest of the time.
enum RecordShortcut {
    private static var record: EventHotKeyRef?
    private static var dismiss: EventHotKeyRef?
    private static var video: EventHotKeyRef?
    private static var audio: EventHotKeyRef?
    private static var icon: EventHotKeyRef?
    private static let dismissID: UInt32 = 2
    private static let videoID: UInt32 = 3
    private static let audioID: UInt32 = 4
    private static let iconID: UInt32 = 5

    static func register() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            MainActor.assumeIsolated {
                switch key.id {
                case RecordShortcut.dismissID: CallPrompt.close()
                case RecordShortcut.videoID: CallWatcher.shared.record(.audioAndVideo)
                case RecordShortcut.audioID: CallWatcher.shared.record(.audio)
                case RecordShortcut.iconID: CallWatcher.shared.toggleIcon()
                default: CallWatcher.shared.toggleRecording()
                }
            }
            return noErr
        }, 1, &pressed, nil, nil)
        record = hotKey(kVK_ANSI_T, id: 1)
        video = hotKey(kVK_ANSI_V, id: videoID)
        audio = hotKey(kVK_ANSI_A, id: audioID)
        icon = hotKey(kVK_ANSI_H, id: iconID)
    }

    static func registerDismiss() {
        if dismiss == nil {
            dismiss = hotKey(kVK_ANSI_N, id: dismissID)
        }
    }

    static func unregisterDismiss() {
        if let dismiss {
            UnregisterEventHotKey(dismiss)
            self.dismiss = nil
        }
    }

    private static func hotKey(_ key: Int, id: UInt32) -> EventHotKeyRef? {
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: OSType(0x4C54_5249), id: id),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            NSLog("LitteroiWatcher: hot key \(id) not registered: \(status)")
        }
        return hotKey
    }
}

final class WatcherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { CallWatcher.shared.start() }
    }
}
