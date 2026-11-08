import AppKit
import SwiftUI

enum Theme {
    static let gold = Color(red: 0.84, green: 0.72, blue: 0.48)
    static let background = Color(red: 0.063, green: 0.11, blue: 0.106)
    static let card = Color(red: 0.094, green: 0.16, blue: 0.14)
    static let muted = Color(red: 0.72, green: 0.78, blue: 0.74)
}

enum AppPage: String, CaseIterable, Identifiable, Hashable {
    case micTest = "Mic Test"
    case record = "Record Voice"
    case narrate = "Narrate"
    case engine = "Voice Engine"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .micTest: return "waveform"
        case .record: return "mic.fill"
        case .narrate: return "book.fill"
        case .engine: return "cpu"
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = VoiceEngine()
    @StateObject private var mic = MicManager()
    @State private var section: AppPage? = .micTest

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(AppPage.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    StatusDot(ok: engine.installed, text: engine.installed ? "Engine installed" : "Engine not installed")
                    StatusDot(ok: engine.hasSample, text: engine.hasSample ? "Voice saved" : "No voice yet")
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch section ?? .micTest {
                case .micTest: MicTestView(mic: mic)
                case .record: RecordView(mic: mic, engine: engine)
                case .narrate: NarrateView(engine: engine)
                case .engine: EngineView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(minWidth: 900, minHeight: 640)
        .tint(Theme.gold)
    }
}

// MARK: Shared components

struct StatusDot: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Page layout: title, subtitle and scrolling content.
struct Screen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ETHER / READER")
                    .font(.caption).kerning(2).foregroundStyle(Theme.gold)
                Text(title).font(.custom("Georgia", size: 34))
                Text(subtitle).foregroundStyle(Theme.muted)
                content
            }
            .padding(28)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.custom("Georgia", size: 21))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
    }
}

struct Notice: View {
    let text: String
    var good = false
    var body: some View {
        Label(text, systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(good ? Color.green : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Horizontal level meter: green → yellow → red, with a peak marker.
struct LevelMeter: View {
    let averageDB: Float
    let peakDB: Float

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * fraction(averageDB))
                        }
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * fraction(peakDB) - 2))
                        .opacity(peakDB > -60 ? 1 : 0)
                }
                .animation(.linear(duration: 0.05), value: averageDB)
            }
            .frame(height: 14)
            HStack {
                Text("−60 dB"); Spacer(); Text("−30"); Spacer(); Text("−12"); Spacer(); Text("0 dB")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MicPicker: View {
    @ObservedObject var mic: MicManager

    var body: some View {
        HStack {
            Picker("Microphone", selection: Binding(get: { mic.selectedID }, set: { mic.select($0) })) {
                if mic.devices.isEmpty { Text("No microphone found").tag("") }
                ForEach(mic.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .frame(maxWidth: 420)
            Button("Refresh") { mic.refreshDevices() }
        }
    }
}

/// Hardware mic volume (when the mic supports it) and a software Boost.
struct MicVolumeControls: View {
    @ObservedObject var mic: MicManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let volume = mic.hardwareVolume {
                HStack {
                    Text("Mic volume").frame(width: 90, alignment: .leading)
                    Slider(value: Binding(get: { volume }, set: { mic.setHardwareVolume($0) }), in: 0...1)
                    Text("\(Int((volume * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            } else if mic.listening {
                Text("This mic's own volume can't be set from here — use the knob on the mic, or Boost below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Boost").frame(width: 90, alignment: .leading)
                Slider(value: $mic.softwareGainDB, in: 0...24, step: 1)
                Text("+\(Int(mic.softwareGainDB)) dB").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text("Raise Mic volume first; use Boost only if it's still too quiet. Aim for your loudest words to reach the yellow zone, never red.")
                .font(.caption).foregroundStyle(.secondary)
            if mic.sampleRate > 0 {
                Text(String(format: "Recording at %.1f kHz", mic.sampleRate / 1000))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlayerControls: View {
    @ObservedObject var player: Player

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            Button { player.stop() } label: { Image(systemName: "stop.fill").frame(width: 18) }
            Slider(value: Binding(get: { player.current }, set: { player.seek($0) }),
                   in: 0...max(player.duration, 0.1))
            Text("\(timeText(player.current)) / \(timeText(player.duration))")
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .disabled(player.loadedURL == nil)
    }
}

func timeText(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}
