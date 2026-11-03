import AppKit
import ServiceManagement
import SwiftUI

@main
struct LitteroiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// `Litteroi --register-watcher`, which scripts/update.sh runs after an install, starts the
    /// call watcher without opening the recording window.
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

/// Opens the recording window at launch. Closing it, with Cmd+W or Cmd+Q, saves the recording
/// and quits.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerCallWatcher()
        openRecordingWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openRecordingWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.stopRecording() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func openRecordingWindow() {
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
            Task { await AppModel.shared.startRecording() }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        MainActor.assumeIsolated { AppModel.shared.stopRecording() }
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
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "fi.taitounited.litteroi.watcher").isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 12)
        }
    }
}
