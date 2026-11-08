import AVFoundation
import Foundation

/// Simple audio player with play / pause / stop / seek for SwiftUI.
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    @discardableResult
    func load(_ url: URL) -> Bool {
        stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            current = 0
            loadedURL = url
            return true
        } catch {
            player = nil
            loadedURL = nil
            duration = 0
            return false
        }
    }

    func unload() {
        stop()
        player = nil
        loadedURL = nil
        duration = 0
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        current = 0
        isPlaying = false
        timer?.invalidate()
    }

    func seek(_ time: TimeInterval) {
        player?.currentTime = time
        current = time
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.current = player.currentTime
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.current = 0
            self.timer?.invalidate()
        }
    }
}
