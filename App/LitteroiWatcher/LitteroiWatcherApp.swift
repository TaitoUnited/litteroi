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
        MenuBarExtra(isInserted: Binding(get: { watcher.showsIcon }, set: { if $0 != watcher.showsIcon { watcher.iconShown = $0 } })) {
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
            if !watcher.autoRecorded.isEmpty {
                Menu("Litteroidaan itsestään") {
                    ForEach(watcher.autoRecorded, id: \.self) { source in
                        Button("Poista \(source)") { CallWatcher.shared.removeAutoRecorded(source) }
                    }
                }
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
/// app has held the microphone for a few seconds, a call in an app or site of the auto list is
/// recorded on its own until the call ends, and any other call gets a prompt that offers to record
/// it and to add its app or site to the list. Once the call app has let go of the microphone for a
/// few seconds, a recording the prompt started for that call gets a prompt offering to stop it. It
/// also counts the recordings not transcribed yet and deletes the audio of meetings finished long
/// ago.
@MainActor
final class CallWatcher: ObservableObject {
    static let shared = CallWatcher()

    @Published private(set) var call: String?
    @Published private(set) var recording = false
    @Published private(set) var mode: MeetingFolder.RecordingMode?
    @Published private(set) var unfinished = 0
    @Published private(set) var autoRecorded: [String] = []
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
    private var autoStartingUntil = Date.distantPast
    private var stopsWithCall = false
    private var calls = 0
    private var siteWait: SiteWait?
    private var readingSite = false
    private let autoList = AutoRecordList(file: MeetingFolder.defaultRoot.appending(path: "automaattiset.txt"))

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
        let autoRecorded = autoList.entries
        if self.autoRecorded != autoRecorded {
            self.autoRecorded = autoRecorded
        }
        let micUsers = AudioProcesses.micUsers()
        if recording != micUsers.contains(CallDetector.litteroi) {
            recording.toggle()
            recordingForCall = recording && Date.now < startingForCallUntil
            stopsWithCall = recording && Date.now < autoStartingUntil
            CallPrompt.close()
        }
        switch detector.update(micUsers: micUsers) {
        case .started(let app, let litteroiRecording):
            call = app
            calls += 1
            if !litteroiRecording {
                recordOrOffer(app, call: calls)
            }
        case .quiet:
            if recording, recordingForCall, !stopsWithCall, let call {
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
            if recording, stopsWithCall {
                Self.stopRecording()
            } else if !recording {
                CallPrompt.close()
            }
            call = nil
        case nil:
            break
        }
        waitForSite()
    }

    /// The source is the call app, or for a browser the site of the call's tab. A browser whose site
    /// cannot be read yet, such as while the call's tab is behind another, gets the prompt without
    /// the offer to add it, and its site is read again once the front tab changes.
    private func recordOrOffer(_ app: String, call number: Int) {
        Task {
            let source = await Self.source(of: app)
            guard number == calls, call != nil, !Self.litteroiRunning else { return }
            if source == nil, BrowserPage.browsers[app] != nil, BrowserPage.permitted {
                siteWait = SiteWait(call: number, browser: app, title: BrowserPage.frontTitle(inBrowser: app),
                                    reads: SiteWait.reads)
            }
            if let source, autoList.contains(source) {
                startRecording(.forDisplays, stopsWithCall: true)
            } else {
                offer(source)
            }
        }
    }

    private func offer(_ source: String?) {
        let mode = MeetingFolder.RecordingMode.forDisplays
        var actions: [CallPrompt.Action] = []
        if let source {
            actions.append(.init(title: "Aina", key: "L") { CallWatcher.shared.alwaysRecord(source) })
        }
        actions += [
            .init(title: "Ääni", key: "A") { CallWatcher.shared.record(.audio) },
            .init(title: "Kuva", key: "V") { CallWatcher.shared.record(.audioAndVideo) },
        ]
        let litteroidaanko = String(localized: "Litteroidaanko?")
        CallPrompt.show(title: source == nil ? nil : litteroidaanko,
                        message: source.map { String(localized: "Aina: litteroi jatkossa itsestään (\($0))") } ?? litteroidaanko,
                        actions: actions, dismiss: "Ei",
                        defaultKey: mode == .audioAndVideo ? "V" : "A")
    }

    /// A browser call whose site could not be read. A tab that comes to the front may be quiet for
    /// a moment, so after each change of the front tab the site is read up to `reads` times,
    /// `pollsBetweenReads` polls apart, and only from a front tab that plays sound.
    private struct SiteWait {
        static let reads = 6
        static let pollsBetweenReads = 5
        let call: Int
        let browser: String
        var title: String?
        var reads = 0
        var polls = 0
    }

    /// A site read late is recorded on its own when it is on the list, and otherwise added to the
    /// prompt as Aina while the prompt still shows.
    private func waitForSite() {
        guard var wait = siteWait, !readingSite else { return }
        guard wait.call == calls, call != nil, !recording, !Self.litteroiRunning else {
            siteWait = nil
            return
        }
        let title = BrowserPage.frontTitle(inBrowser: wait.browser)
        if title != wait.title {
            wait = SiteWait(call: wait.call, browser: wait.browser, title: title)
        } else {
            wait.polls += 1
            guard wait.reads < SiteWait.reads, wait.polls >= SiteWait.pollsBetweenReads else {
                siteWait = wait
                return
            }
        }
        wait.reads += 1
        wait.polls = 0
        siteWait = wait
        readingSite = true
        Task {
            let source = await BrowserPage.url(inBrowser: wait.browser, playingSound: true).flatMap(BrowserPage.site(of:))
            readingSite = false
            guard let source, siteWait?.call == calls, call != nil, !Self.litteroiRunning else { return }
            siteWait = nil
            if autoList.contains(source) {
                startRecording(.forDisplays, stopsWithCall: true)
            } else if CallPrompt.isShowing {
                offer(source)
            }
        }
    }

    private static func source(of app: String) async -> String? {
        guard BrowserPage.browsers[app] != nil else { return app }
        guard BrowserPage.permitted else {
            if !UserDefaults.standard.bool(forKey: "askedAccessibility") {
                UserDefaults.standard.set(true, forKey: "askedAccessibility")
                BrowserPage.askPermission()
            }
            return nil
        }
        return await BrowserPage.url(inBrowser: app).flatMap(BrowserPage.site(of:))
    }

    private func alwaysRecord(_ source: String) {
        do {
            try autoList.add(source)
        } catch {
            NSLog("LitteroiWatcher: \(source) not added to the auto list: \(error)")
        }
        autoRecorded = autoList.entries
        if !Self.litteroiRunning {
            startRecording(.forDisplays, stopsWithCall: true)
        }
    }

    func removeAutoRecorded(_ source: String) {
        try? autoList.remove(source)
        autoRecorded = autoList.entries
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

    /// A recording opened during a call is for that call, so its end offers to stop it, or stops
    /// it when the recording started on its own. Unless a mode is asked for, the screens are
    /// recorded only while no external display is connected.
    func startRecording(_ mode: MeetingFolder.RecordingMode = .forDisplays, stopsWithCall: Bool = false) {
        if call != nil {
            startingForCallUntil = .now + 30
            autoStartingUntil = stopsWithCall ? .now + 30 : .distantPast
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
/// Control-Option-H hides or shows the menu bar icon, Control-Option-N dismisses a prompt and
/// Control-Option-L adds a new app or site to the auto list. Carbon hot keys need no accessibility
/// permission, unlike a global key event monitor. Control-Option-N and L are held only while a
/// prompt shows, so other apps keep them the rest of the time.
enum RecordShortcut {
    private static var record: EventHotKeyRef?
    private static var dismiss: EventHotKeyRef?
    private static var always: EventHotKeyRef?
    private static var video: EventHotKeyRef?
    private static var audio: EventHotKeyRef?
    private static var icon: EventHotKeyRef?
    private static let dismissID: UInt32 = 2
    private static let videoID: UInt32 = 3
    private static let audioID: UInt32 = 4
    private static let iconID: UInt32 = 5
    private static let alwaysID: UInt32 = 6

    static func register() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            MainActor.assumeIsolated {
                switch key.id {
                case RecordShortcut.dismissID: CallPrompt.close()
                case RecordShortcut.alwaysID: CallPrompt.run(key: "L")
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

    static func registerPromptKeys(always offersAlways: Bool) {
        if dismiss == nil {
            dismiss = hotKey(kVK_ANSI_N, id: dismissID)
        }
        if offersAlways, always == nil {
            always = hotKey(kVK_ANSI_L, id: alwaysID)
        }
    }

    static func unregisterPromptKeys() {
        for key in [dismiss, always].compactMap({ $0 }) {
            UnregisterEventHotKey(key)
        }
        dismiss = nil
        always = nil
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
