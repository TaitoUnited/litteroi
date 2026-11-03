import AppKit
import SwiftUI

/// A small window at the top right of the screen that offers to start or stop a recording. Unlike
/// a notification it needs no permission and stays until it is answered or the moment passes.
@MainActor
enum CallPrompt {
    private static var panel: NSPanel?

    static func show(title: String, message: String, action: LocalizedStringKey, onAction: @escaping () -> Void) {
        close()
        let view = CallPromptView(title: title, message: message, action: action) {
            close()
            onAction()
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = PromptPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

/// Becomes key without activating the watcher, so a click on a button lands the first time.
private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CallPromptView: View {
    let title: String
    let message: String
    let action: LocalizedStringKey
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Control-Optio-L").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ei nyt") { CallPrompt.close() }
                    Button(action, action: onAction).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
