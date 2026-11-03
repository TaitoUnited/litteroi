import AppKit
import SwiftUI

struct RecordingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(model.isRecording ? LocalizedStringKey("Nauhoitetaan") : "Ei nauhoiteta")
                    .font(.headline)
                Spacer()
                Text(Self.clock(model.elapsed))
                    .font(.title2.monospacedDigit())
            }

            LevelRow(title: "Mikrofoni", level: model.micLevel)
            LevelRow(title: "Puhelun ääni", level: model.callLevel)

            if let error = model.recordingError {
                Text(error).foregroundStyle(.red)
                Button("Avaa mikrofoniasetukset") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
            if let error = model.callError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }

            Text("Kerro osallistujille, että palaveri nauhoitetaan ja litteroidaan.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("Cmd+W tai Control-Optio-L tallentaa. Litteroi Claude Codessa: litteroi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Lopeta ja tallenna") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

private struct LevelRow: View {
    let title: LocalizedStringKey
    let level: Float

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 100, alignment: .leading)
            ProgressView(value: Double(level))
        }
    }
}
