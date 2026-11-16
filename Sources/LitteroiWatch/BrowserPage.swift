import AppKit
import ApplicationServices

/// The page open in a browser's front window, read through the Accessibility API, which needs the
/// user's permission in System Settings > Privacy & Security > Accessibility. Chrome, Edge, Brave,
/// Arc and Safari give the window's URL as its document. Firefox gives it on the web area inside the
/// window, and builds that tree only while a client has set `AXEnhancedUserInterface`, as VoiceOver
/// does, so a read that finds nothing sets it, reads again and sets it back.
///
/// Firefox gives the URL of the front tab only, and marks a tab that plays sound with a button
/// before its title. A call plays the others' voices, so while a tab of any window plays sound, the
/// front tab counts as the call's page only when it is one of them.
public enum BrowserPage {
    /// The browsers among the call apps, by their name there, and the bundle id of the app itself,
    /// not of the helper process that holds the microphone.
    public static let browsers: [String: String] = [
        "Chrome": "com.google.Chrome",
        "Safari": "com.apple.Safari",
        "Firefox": "org.mozilla.firefox",
        "Edge": "com.microsoft.edgemac",
        "Arc": "company.thebrowser.Browser",
        "Brave": "com.brave.Browser",
    ]

    public static var permitted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which opens the Accessibility settings.
    public static func askPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// The URL in the front window of the browser the call app list names `name`, or nil while the
    /// call is in another tab. With `playingSound`, the front tab counts only when it plays sound.
    public static func url(inBrowser name: String, playingSound: Bool = false) async -> URL? {
        guard let browser = application(name) else { return nil }
        switch frontPage(of: browser, playingSound: playingSound) {
        case .page(let url): return url
        case .elsewhere: return nil
        case .unread: break
        }
        let enhanced = "AXEnhancedUserInterface" as CFString
        AXUIElementSetAttributeValue(browser, enhanced, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(browser, enhanced, kCFBooleanFalse) }
        for _ in 1...4 {
            try? await Task.sleep(for: .milliseconds(500))
            switch frontPage(of: browser, playingSound: playingSound) {
            case .page(let url): return url
            case .elsewhere: return nil
            case .unread: continue
            }
        }
        return nil
    }

    /// The title of the browser's front window, which follows its front tab. Firefox gives it
    /// without building its tree, so it is cheap enough to read on every poll.
    public static func frontTitle(inBrowser name: String) -> String? {
        guard let browser = application(name),
              let window = element(attribute(browser, kAXFocusedWindowAttribute))
                ?? element(attribute(browser, kAXMainWindowAttribute))
        else { return nil }
        return attribute(window, kAXTitleAttribute) as? String
    }

    /// The host a list entry names a site by, without www.
    public static func site(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    struct Tab: Equatable {
        var front: Bool
        var playsSound: Bool
    }

    /// Whether the front tab may be read as the call's page.
    static func frontTabHoldsCall(_ tabs: [Tab], playingSound: Bool) -> Bool {
        guard playingSound || tabs.contains(where: \.playsSound) else { return true }
        return tabs.contains { $0.front && $0.playsSound }
    }

    private enum Read {
        case page(URL)
        case elsewhere
        case unread
    }

    private static func application(_ name: String) -> AXUIElement? {
        guard let bundleID = browsers[name],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let browser = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(browser, 1)
        return browser
    }

    private static func frontPage(of browser: AXUIElement, playingSound: Bool) -> Read {
        guard let window = element(attribute(browser, kAXFocusedWindowAttribute))
                ?? element(attribute(browser, kAXMainWindowAttribute))
        else { return .unread }
        let windows = attribute(browser, kAXWindowsAttribute) as? [AXUIElement] ?? [window]
        let tabs = windows.flatMap { other in
            var budget = 2000
            let front = CFEqual(other, window)
            return (tabStrip(in: other, depth: 0, budget: &budget).map(tabs(in:)) ?? [])
                .map { Tab(front: front && $0.front, playsSound: $0.playsSound) }
        }
        if playingSound, tabs.isEmpty {
            return .unread
        }
        guard frontTabHoldsCall(tabs, playingSound: playingSound) else { return .elsewhere }
        if let url = webURL(attribute(window, kAXDocumentAttribute)) {
            return .page(url)
        }
        var budget = 2000
        return webAreaURL(in: window, depth: 0, budget: &budget).map(Read.page) ?? .unread
    }

    /// The browser's own tab strip, leaving out the pages, whose tab lists are roles alike.
    private static func tabStrip(in element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        budget -= 1
        guard depth < 8, budget > 0 else { return nil }
        switch attribute(element, kAXRoleAttribute) as? String {
        case "AXTabGroup": return element
        case "AXWebArea": return nil
        default: break
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let strip = tabStrip(in: child, depth: depth + 1, budget: &budget) {
                return strip
            }
        }
        return nil
    }

    /// Firefox's tabs, also those inside a tab group. A tab's mute button comes before its title,
    /// its close button after.
    private static func tabs(in strip: AXUIElement) -> [Tab] {
        children(of: strip).flatMap { child -> [Tab] in
            guard attribute(child, kAXSubroleAttribute) as? String == "AXTabButton" else {
                return attribute(child, kAXRoleAttribute) as? String == "AXGroup" ? tabs(in: child) : []
            }
            let roles = children(of: child).map { attribute($0, kAXRoleAttribute) as? String }
            let title = roles.firstIndex(of: "AXStaticText")
            return [Tab(front: (attribute(child, kAXSelectedAttribute) as? Bool) == true,
                        playsSound: title.map { roles[..<$0].contains("AXButton") } ?? false)]
        }
    }

    private static func webAreaURL(in element: AXUIElement, depth: Int, budget: inout Int) -> URL? {
        budget -= 1
        guard depth < 20, budget > 0 else { return nil }
        if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" {
            return webURL(attribute(element, "AXURL"))
        }
        for child in children(of: element) {
            if let url = webAreaURL(in: child, depth: depth + 1, budget: &budget) {
                return url
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func webURL(_ value: AnyObject?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        return url.flatMap { site(of: $0) == nil ? nil : $0 }
    }
}
