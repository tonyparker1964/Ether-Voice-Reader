import AppKit
import SwiftUI

struct EngineView: View {
    @ObservedObject var engine: VoiceEngine

    var body: some View {
        Screen(title: "Voice Engine",
               subtitle: "Narration uses the Qwen3-TTS voice model running on Apple Silicon with MLX. It installs once, then works offline.") {
            Card(title: "Status") {
                if engine.installed {
                    Notice(text: "The voice engine is installed.", good: true)
                } else {
                    Notice(text: "Not installed yet. Installing needs internet and several GB of free space.")
                }
                HStack {
                    Button(engine.installed ? "Reinstall" : "Install voice engine") { engine.install() }
                        .disabled(engine.installing || engine.generating)
                    if engine.installing { ProgressView().controlSize(.small); Text("Installing…") }
                }
                Text("Requires Python 3.10 or newer (3.11 recommended) from python.org or Homebrew.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Storage") {
                Text(engine.root.path).textSelection(.enabled).foregroundStyle(Theme.gold)
                Text("The voice engine, the downloaded model, your voice sample and your narrations are kept here.")
                    .foregroundStyle(Theme.muted)
                if !engine.rootIsOnExternalDrive {
                    if engine.externalDriveMounted {
                        Button("Use the MAC Mini 2 drive") {
                            engine.root = VoiceEngine.externalDrive.appendingPathComponent("Ether Reader")
                        }
                    } else {
                        Text("The MAC Mini 2 drive isn't connected, so this Mac's internal drive is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Choose folder…") { chooseFolder() }
                        .disabled(engine.installing || engine.generating)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: engine.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(engine.root)
                    }
                }
                Text("Changing the folder means installing the engine and recording your voice again there (or moving the files yourself).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Engine messages") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.log.isEmpty ? "Messages from installation and narration appear here." : engine.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 260)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: engine.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Button("Copy messages") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.log, forType: .string)
                }
                .disabled(engine.log.isEmpty)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if engine.externalDriveMounted { panel.directoryURL = VoiceEngine.externalDrive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.root = url
    }
}
