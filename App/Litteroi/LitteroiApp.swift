import AppKit
import Combine
import LitteroiCore
import ServiceManagement
import SwiftUI

@main
struct LitteroiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// `Litteroi --register-watcher`, which scripts/update.sh runs after an install, starts the
    /// call watcher without recording.
    init() {
        if CommandLine.arguments.contains("--register-watcher") {
            AppDelegate.registerCallWatcher(afterInstall: true)
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

/// Starts recording at launch. Started by the call watcher, it has no window and no Dock icon, so
/// the meeting stays in front, and the watcher in the menu bar shows the recording and stops it.
/// The window and the Dock icon show when the user opens Litteroi, such as from Spotlight, when
/// something went wrong, when macOS filters the microphone and when the watcher is not running.
/// Quitting saves the recording.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let watcherID = "fi.taitounited.litteroi.watcher"
    private var window: NSWindow?
    private let fromWatcher = CommandLine.arguments.contains("--from-watcher")
    private var micModeWatch: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(fromWatcher ? .accessory : .regular)
    }

    /// The call watcher opens the app with `--video` to record the screens too, and switches them
    /// on and off midway with a notification. Opened by the user, it records them too.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerCallWatcher()
        for mode in [MeetingFolder.RecordingMode.audio, .audioAndVideo] {
            DistributedNotificationCenter.default().addObserver(forName: mode.notification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.setScreens(mode == .audioAndVideo) }
            }
        }
        micModeWatch = AppModel.shared.$micIsFiltered.filter { $0 }.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.openRecordingWindow() }
        }
        Task {
            let screens = !fromWatcher || CommandLine.arguments.contains("--video")
            await AppModel.shared.startRecording(screens: screens)
            if AppModel.shared.needsAttention || !Self.watcherRunning || !fromWatcher {
                openRecordingWindow()
            } else if window == nil, NSApp.isActive {
                NSApp.hide(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openRecordingWindow()
        return false
    }

    /// The screen videos are finished asynchronously, so quitting waits for them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isRecording else { return .terminateNow }
        Task {
            await AppModel.shared.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func openRecordingWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Litteroi"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecordingView(model: AppModel.shared))
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closing the window leaves a recording going; without one there is nothing left to do.
    func windowWillClose(_ notification: Notification) {
        window = nil
        if AppModel.shared.isRecording {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// The call watcher inside the app bundle is a launch agent from the install or the first launch
    /// on: it starts at login, and launchd starts it again whenever it exits, after an update too.
    /// It is registered once, so turning it off in the login items settings sticks; an install
    /// registers a watcher that is on again.
    static func registerCallWatcher(afterInstall: Bool = false) {
        let registered = "callWatcherRegistered"
        let watcher = SMAppService.agent(plistName: "fi.taitounited.litteroi.watcher.plist")
        do {
            if afterInstall, watcher.status == .enabled {
                try registerAgain(watcher)
                return
            }
            guard !UserDefaults.standard.bool(forKey: registered) else { return }
            try watcher.register()
            UserDefaults.standard.set(true, forKey: registered)
        } catch {
            NSLog("Litteroi: call watcher not registered: \(error)")
        }
    }

    /// launchd keeps the signature of the app that registered the watcher and refuses one signed
    /// another way, as when a release replaces a local build. About 10 s after a registration it
    /// has taken the new signature, and registering again then starts the watcher.
    private static func registerAgain(_ watcher: SMAppService) throws {
        for _ in 1...3 {
            try watcher.unregister()
            try watcher.register()
            Thread.sleep(forTimeInterval: 3)
            if watcherRunning {
                return
            }
            Thread.sleep(forTimeInterval: 12)
        }
    }

    private static var watcherRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: watcherID).isEmpty
    }
}
