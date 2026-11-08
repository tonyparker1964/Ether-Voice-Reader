import AppKit
import SwiftUI

struct MicTestView: View {
    @ObservedObject var mic: MicManager
    @StateObject private var player = Player()
    @State private var testPeak: Float?
    @State private var testing = false

    private let testURL = FileManager.default.temporaryDirectory.appendingPathComponent("ether-mic-test.caf")

    var body: some View {
        Screen(title: "Mic Test",
               subtitle: "Check your microphone before you record your voice. Clean, undistorted audio gives the best voice copy.") {
            Card(title: "1 · Choose and listen") {
                MicPicker(mic: mic)
                LevelMeter(averageDB: mic.averageDB, peakDB: mic.peakDB)
                if mic.listening {
                    liveAdvice
                } else {
                    Text("Press Start listening, then speak at your normal reading volume.")
                        .foregroundStyle(Theme.muted)
                }
                HStack {
                    Button(mic.listening ? "Stop listening" : "Start listening") {
                        mic.listening ? mic.stopListening() : mic.startListening()
                    }
                    .disabled(mic.recording)
                    Button("Open Sound input settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if mic.selectedIsBluetooth {
                    Notice(text: "Bluetooth mics (like AirPods) record in low quality and often sound crackly. Use a USB or wired mic for your voice sample if you can.")
                }
                if !mic.message.isEmpty { Notice(text: mic.message) }
            }

            Card(title: "2 · Record a 5-second test") {
                Text("Say a sentence or two in your reading voice. It plays back automatically so you can hear exactly what the app hears.")
                    .foregroundStyle(Theme.muted)
                HStack {
                    Button {
                        startTest()
                    } label: {
                        Label(testing ? "Recording… \(Int(mic.elapsed))s" : "Record 5-second test", systemImage: "record.circle")
                    }
                    .disabled(mic.recording)
                    if testing { ProgressView(value: min(mic.elapsed / 5, 1)).frame(width: 160) }
                }
                if let testPeak {
                    let verdict = MicManager.verdict(peakDB: testPeak)
                    Notice(text: verdict.text, good: verdict.good)
                    Text(String(format: "Loudest moment: %.1f dB", testPeak))
                        .font(.caption).foregroundStyle(.secondary)
                    PlayerControls(player: player)
                }
            }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder private var liveAdvice: some View {
        if mic.clipping {
            Notice(text: "Too loud — clipping. Lower the input volume or move back.")
        } else if mic.peakDB < -45 {
            Text("Listening… speak now.").foregroundStyle(Theme.muted)
        } else {
            Notice(text: "Signal looks healthy.", good: true)
        }
    }

    private func startTest() {
        player.unload()
        testPeak = nil
        testing = true
        mic.record(to: testURL, maxSeconds: 5) { url, error in
            testing = false
            if let url {
                testPeak = mic.recordPeakDB
                if player.load(url) { player.play() }
            } else {
                mic.message = error ?? "The test recording failed."
            }
        }
    }
}
