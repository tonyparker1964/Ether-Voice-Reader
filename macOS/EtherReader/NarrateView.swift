import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NarrateView: View {
    @ObservedObject var engine: VoiceEngine
    @StateObject private var player = Player()
    @AppStorage("narrateText") private var text = ""

    var body: some View {
        Screen(title: "Your Words. Your Voice.",
               subtitle: "Paste a passage or open a text file, then generate it in your voice. Everything runs on this Mac.") {
            if !engine.installed {
                Notice(text: "Install the voice engine first (Voice Engine page).")
            }
            if !engine.hasSample {
                Notice(text: "Record your voice first (Record Voice page).")
            }

            Card(title: "Passage") {
                HStack {
                    Link("Open The Secret Book of John ↗",
                         destination: URL(string: "https://www.gnosis.org/naghamm/apocjn-long.html")!)
                    Spacer()
                    Button("Open text file…") { openFile() }
                    Button("Clear") { text = "" }.disabled(text.isEmpty)
                }
                TextEditor(text: $text)
                    .font(.custom("Georgia", size: 17))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                Text("\(text.count) characters · long passages are read in parts and joined together")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Generate") {
                HStack {
                    if engine.generating {
                        Button("Stop") { engine.cancel() }
                        ProgressView(value: engine.progress).frame(maxWidth: 240)
                    } else {
                        Button {
                            player.stop()
                            engine.speak(text)
                        } label: { Label("Generate in my voice", systemImage: "waveform") }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                if !engine.status.isEmpty { Text(engine.status).foregroundStyle(Theme.gold) }
                Text("The first narration downloads and loads the voice model, which can take several minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                PlayerControls(player: player)
                HStack {
                    Button("Save narration…") { saveNarration() }
                        .disabled(player.loadedURL == nil)
                    Button("Show in Finder") {
                        if let url = player.loadedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(player.loadedURL == nil)
                }
            }
        }
        .onAppear {
            if let last = engine.lastNarration, player.loadedURL == nil { player.load(last) }
        }
        .onDisappear { player.pause() }
        .onChange(of: engine.lastNarration) { _, url in
            if let url, player.load(url) { player.play() }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
        } else if let contents = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = contents
        }
    }

    private func saveNarration() {
        guard let source = player.loadedURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Ether narration.wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            engine.status = "Could not save: \(error.localizedDescription)"
        }
    }
}
