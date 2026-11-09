import AppKit
import SwiftUI

/// A small window at the top right of the screen that offers to start or stop a recording. Unlike
/// a notification it needs no permission and stays until it is answered or the moment passes.
/// Each button shows its Control-Option hot key, and Control-Option-N dismisses it.
@MainActor
enum CallPrompt {
    struct Action {
        let title: LocalizedStringKey
        let key: String
        let run: () -> Void
    }

    private static var panel: NSPanel?
    private static var actions: [Action] = []

    /// The action with `defaultKey`, or else the first, is the default one, taken with Return.
    static func show(title: String? = nil, message: String, actions: [Action], dismiss: LocalizedStringKey,
                     defaultKey: String? = nil) {
        close()
        let actions = actions.map { action in
            Action(title: action.title, key: action.key) {
                close()
                action.run()
            }
        }
        let defaultIndex = actions.firstIndex { $0.key == defaultKey } ?? 0
        let view = CallPromptView(title: title, message: message, actions: actions, defaultIndex: defaultIndex,
                                  dismiss: dismiss)
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
        self.actions = actions
        RecordShortcut.registerPromptKeys(always: actions.contains { $0.key == "L" })
    }

    /// Runs the action of the prompt showing that has this hot key.
    static func run(key: String) {
        actions.first { $0.key == key }?.run()
    }

    static func close() {
        panel?.close()
        panel = nil
        actions = []
        RecordShortcut.unregisterPromptKeys()
    }
}

/// Becomes key without activating the watcher, so a click on a button lands the first time.
private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CallPromptView: View {
    let title: String?
    let message: String
    let actions: [CallPrompt.Action]
    let defaultIndex: Int
    let dismiss: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(message).font(.headline)
                }
                HStack {
                    ForEach(actions.indices, id: \.self) { index in
                        Button(action: actions[index].run) {
                            ShortcutLabel(title: actions[index].title, key: actions[index].key)
                        }
                        .keyboardShortcut(index == defaultIndex ? .defaultAction : nil)
                    }
                    Button { CallPrompt.close() } label: { ShortcutLabel(title: dismiss, key: "N") }
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(minWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A button title followed by its Control-Option hot key.
private struct ShortcutLabel: View {
    let title: LocalizedStringKey
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(verbatim: "\u{2303}\u{2325}\(key)")
                .foregroundStyle(.secondary)
        }
    }
}
