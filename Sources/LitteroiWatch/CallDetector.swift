/// Tells when a call starts and ends from which apps use the microphone, polled every couple of
/// seconds. A call starts once a call app has held the mic for `startPolls` polls in a row, and
/// ends only after `endPolls` polls without one, so a browser that lets go of the mic while muted
/// does not start a new call on every unmute. A call app that has let go of the mic for
/// `startPolls` polls makes the call quiet, so a recording can be offered to stop within seconds
/// of the call ending; one that takes the mic back resumes the call.
public struct CallDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(app: String, litteroiRecording: Bool)
        case quiet
        case resumed
        case ended
    }

    /// Bundle id prefixes of apps that use the mic for calls, and the name the prompt shows.
    /// A browser counts as a call too, since Meet runs in one.
    public static let callApps: [(prefix: String, name: String)] = [
        ("com.microsoft.teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("us.zoom.xos", "Zoom"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("org.whispersystems.signal-desktop", "Signal"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
    ]

    public static let litteroi = "fi.taitounited.litteroi"

    public private(set) var call: String?
    private let startPolls: Int
    private let endPolls: Int
    private var heldPolls = 0
    private var freePolls = 0

    public init(startPolls: Int = 3, endPolls: Int = 15) {
        self.startPolls = startPolls
        self.endPolls = endPolls
    }

    public mutating func update(micUsers: Set<String>) -> Event? {
        let app = Self.callApps.first { app in micUsers.contains { $0.hasPrefix(app.prefix) } }?.name
        guard let app else {
            heldPolls = 0
            guard call != nil else { return nil }
            freePolls += 1
            guard freePolls >= endPolls else { return freePolls == startPolls ? .quiet : nil }
            call = nil
            return .ended
        }
        let wasQuiet = call != nil && freePolls >= startPolls
        freePolls = 0
        if wasQuiet { return .resumed }
        guard call == nil else { return nil }
        heldPolls += 1
        guard heldPolls >= startPolls else { return nil }
        call = app
        return .started(app: app, litteroiRecording: micUsers.contains(Self.litteroi))
    }
}
