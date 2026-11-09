import AppKit
import ApplicationServices

/// The page open in a browser's front window, read through the Accessibility API, which needs the
/// user's permission in System Settings > Privacy & Security > Accessibility. Chrome, Edge, Brave,
/// Arc and Safari give the window's URL as its document. Firefox gives it on the web area inside the
/// window, and builds that tree only while a client has set `AXEnhancedUserInterface`, as VoiceOver
/// does, so a read that finds nothing sets it, reads again and sets it back.
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

    /// The URL in the front window of the browser the call app list names `name`.
    public static func url(inBrowser name: String) async -> URL? {
        guard let bundleID = browsers[name],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let browser = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(browser, 1)
        if let url = frontURL(of: browser) {
            return url
        }
        let enhanced = "AXEnhancedUserInterface" as CFString
        AXUIElementSetAttributeValue(browser, enhanced, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(browser, enhanced, kCFBooleanFalse) }
        for _ in 1...4 {
            try? await Task.sleep(for: .milliseconds(500))
            if let url = frontURL(of: browser) {
                return url
            }
        }
        return nil
    }

    private static func frontURL(of browser: AXUIElement) -> URL? {
        guard let window = element(attribute(browser, kAXFocusedWindowAttribute))
                ?? element(attribute(browser, kAXMainWindowAttribute))
        else { return nil }
        if let url = webURL(attribute(window, kAXDocumentAttribute)) {
            return url
        }
        var budget = 2000
        return webAreaURL(in: window, depth: 0, budget: &budget)
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

    private static func webAreaURL(in element: AXUIElement, depth: Int, budget: inout Int) -> URL? {
        budget -= 1
        guard depth < 20, budget > 0 else { return nil }
        if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" {
            return webURL(attribute(element, "AXURL"))
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let url = webAreaURL(in: child, depth: depth + 1, budget: &budget) {
                return url
            }
        }
        return nil
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
