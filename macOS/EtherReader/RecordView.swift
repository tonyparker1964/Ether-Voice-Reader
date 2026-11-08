import SwiftUI

struct RecordView: View {
    @ObservedObject var mic: MicManager
    @ObservedObject var engine: VoiceEngine
    @StateObject private var takePlayer = Player()
    @StateObject private var savedPlayer = Player()
    @AppStorage("recordScript") private var script =
        "The morning light moved slowly across the water. I opened the old book, took a breath, and began to read the story aloud, one quiet word at a time."
    @State private var take: URL?
    @State private var takeSeconds: Double = 0
    @State private var takePeak: Float = -160
    @State private var note = ""
    @State private var transcriptDraft = ""

    private let takeURL = FileManager.default.temporaryDirectory.appendingPathComponent("ether-voice-take.caf")
    private let maxSeconds = 30.0

    var body: some View {
        Screen(title: "Record Your Voice",
               subtitle: "Read the script in your natural reading voice, in a quiet room. Aim for 8–15 seconds. Whatever is in the script box becomes the transcript.") {
            Card(title: "Script to read aloud") {
                TextEditor(text: $script)
                    .font(.custom("Georgia", size: 17))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            }

            Card(title: "Record") {
                MicPicker(mic: mic)
                LevelMeter(averageDB: mic.averageDB, peakDB: mic.peakDB)
                if mic.clipping { Notice(text: "Too loud — clipping. Lower the input volume or move back.") }
                if mic.selectedIsBluetooth {
                    Notice(text: "Bluetooth mic selected — expect lower quality. A USB or wired mic is better for your voice sample.")
                }
                HStack(spacing: 14) {
                    if mic.recording {
                        Button { mic.stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }
                            .keyboardShortcut(.space, modifiers: [])
                    } else {
                        Button { startTake() } label: { Label("Start recording", systemImage: "record.circle.fill") }
                            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("\(timeText(mic.recording ? mic.elapsed : takeSeconds)) / \(timeText(maxSeconds))")
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(Theme.gold)
                }
                if !mic.message.isEmpty { Notice(text: mic.message) }
                if take != nil {
                    let verdict = MicManager.verdict(peakDB: takePeak)
                    Notice(text: verdict.text, good: verdict.good)
                    PlayerControls(player: takePlayer)
                    HStack {
                        Button("Use this recording as my voice") { useTake() }
                            .disabled(takeSeconds < 3)
                        Button("Record again") { startTake() }
                    }
                }
                if !note.isEmpty { Text(note).foregroundStyle(Theme.gold) }
            }

            Card(title: "Saved voice") {
                if engine.hasSample {
                    Text(String(format: "Saved %.1f seconds in %@", engine.sampleSeconds, engine.voiceDir.path))
                        .foregroundStyle(Theme.muted)
                    PlayerControls(player: savedPlayer)
                    Text("Exact words spoken in the sample")
                    TextEditor(text: $transcriptDraft)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    Button("Save transcript") {
                        do { try engine.saveTranscript(transcriptDraft); note = "Transcript saved." }
                        catch { note = "Could not save transcript: \(error.localizedDescription)" }
                    }
                    .disabled(transcriptDraft == engine.transcript)
                } else {
                    Text("No voice saved yet.").foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear {
            if !mic.listening { mic.startListening() }
            loadSaved()
        }
        .onDisappear {
            takePlayer.stop()
            savedPlayer.stop()
        }
        .onChange(of: engine.sampleSeconds) { _, _ in loadSaved() }
    }

    private func loadSaved() {
        transcriptDraft = engine.transcript
        if engine.hasSample { savedPlayer.load(engine.sampleURL) } else { savedPlayer.unload() }
    }

    private func startTake() {
        takePlayer.unload()
        take = nil
        note = ""
        mic.record(to: takeURL, maxSeconds: maxSeconds) { url, error in
            guard let url else {
                note = error ?? "Recording failed."
                return
            }
            takeSeconds = MicManager.duration(of: url)
            takePeak = mic.recordPeakDB
            take = url
            takePlayer.load(url)
            if takeSeconds < 3 {
                note = "That was under 3 seconds. Record again and read the whole script."
            } else {
                note = String(format: "Recorded %.1f seconds. Play it back — if it sounds clear, use it as your voice.", takeSeconds)
            }
        }
    }

    private func useTake() {
        guard let take else { return }
        do {
            try engine.saveSample(from: take, transcript: script)
            note = "Saved as your voice. Go to Narrate to hear it read."
            loadSaved()
        } catch {
            note = "Could not save your voice: \(error.localizedDescription)"
        }
    }
}
