import AVFoundation
import Foundation

/// Microphone selection, live level metering and lossless recording (CAF / linear PCM).
final class MicManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID: String = ""
    @Published var averageDB: Float = -160
    @Published var peakDB: Float = -160
    @Published var clipping = false
    @Published var listening = false
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    /// Highest peak (dB) seen during the most recent recording.
    @Published var recordPeakDB: Float = -160
    @Published var message = ""

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let queue = DispatchQueue(label: "ether.mic.session")
    private var input: AVCaptureDeviceInput?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var clipUntil = Date.distantPast
    private var finish: ((URL?, String?) -> Void)?

    override init() {
        super.init()
        refreshDevices()
    }

    var selectedDevice: AVCaptureDevice? {
        devices.first { $0.uniqueID == selectedID }
    }

    var selectedIsBluetooth: Bool {
        guard let device = selectedDevice else { return false }
        let transport = UInt32(bitPattern: device.transportType)
        // 'blue' and 'blea' — CoreAudio Bluetooth / Bluetooth LE transport codes.
        return transport == 0x626C_7565
            || transport == 0x626C_6561
            || device.localizedName.localizedCaseInsensitiveContains("airpods")
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)
        devices = discovery.devices
        if selectedDevice == nil {
            selectedID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? devices.first?.uniqueID ?? ""
        }
        if devices.isEmpty {
            message = "No microphone found. A Mac mini has no built-in mic — plug in a USB mic or headset, then press Refresh."
        } else if message.hasPrefix("No microphone") {
            message = ""
        }
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        if listening && !recording { configureAndRun() }
    }

    // MARK: Permission

    private func withPermission(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            then()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { then() } else { self.permissionDenied() }
                }
            }
        default:
            permissionDenied()
        }
    }

    private func permissionDenied() {
        message = "Microphone access is off. Open System Settings → Privacy & Security → Microphone and turn on Ether Reader, then try again."
    }

    // MARK: Listening

    func startListening() {
        withPermission { [weak self] in self?.configureAndRun() }
    }

    func stopListening() {
        if recording { stopRecording() }
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        listening = false
        meterTimer?.invalidate()
        averageDB = -160
        peakDB = -160
        clipping = false
    }

    private func configureAndRun() {
        guard let device = selectedDevice else {
            refreshDevices()
            return
        }
        queue.async {
            self.session.beginConfiguration()
            if let old = self.input { self.session.removeInput(old) }
            self.input = nil
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.input = newInput
                }
                if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                    self.session.addOutput(self.output)
                }
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.listening = true
                    if !self.message.hasPrefix("Microphone access") { self.message = "" }
                    self.startMeter()
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.message = "Could not open \(device.localizedName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMeter()
        }
    }

    private func updateMeter() {
        let channels = output.connections.flatMap { $0.audioChannels }
        guard !channels.isEmpty else { return }
        let average = channels.map { $0.averagePowerLevel }.max() ?? -160
        let peak = channels.map { $0.peakHoldLevel }.max() ?? -160
        averageDB = average.isFinite ? average : -160
        peakDB = peak.isFinite ? peak : -160
        if peakDB > -1 { clipUntil = Date().addingTimeInterval(1.5) }
        clipping = Date() < clipUntil
        if recording {
            recordPeakDB = max(recordPeakDB, peakDB)
            if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        }
    }

    // MARK: Recording

    /// Records lossless audio to `url` (CAF). Stops automatically after `maxSeconds`.
    func record(to url: URL, maxSeconds: Double, completion: @escaping (URL?, String?) -> Void) {
        guard !recording else { return }
        withPermission { [weak self] in
            guard let self else { return }
            if !self.listening { self.configureAndRun() }
            try? FileManager.default.removeItem(at: url)
            self.finish = completion
            self.recordPeakDB = -160
            self.elapsed = 0
            self.recording = true
            self.startedAt = Date()
            self.queue.async {
                guard self.input != nil else {
                    DispatchQueue.main.async { self.finishRecording(url: nil, error: "No microphone is open.") }
                    return
                }
                self.output.maxRecordedDuration = CMTime(seconds: maxSeconds, preferredTimescale: 600)
                self.output.startRecording(to: url, outputFileType: .caf, recordingDelegate: self)
            }
        }
    }

    func stopRecording() {
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        var succeeded = (error == nil)
        if let nsError = error as NSError?,
           let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool,
           finished {
            succeeded = true  // stopped by the time limit
        }
        DispatchQueue.main.async {
            self.finishRecording(url: succeeded ? outputFileURL : nil,
                                 error: succeeded ? nil : (error?.localizedDescription ?? "Recording failed."))
        }
    }

    private func finishRecording(url: URL?, error: String?) {
        recording = false
        startedAt = nil
        let callback = finish
        finish = nil
        callback?(url, error)
    }

    // MARK: Helpers

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// Plain-English advice for a peak level in dBFS.
    static func verdict(peakDB: Float) -> (text: String, good: Bool) {
        if peakDB > -1 {
            return ("Too loud — the sound is clipping, which causes distortion and crackle. Lower the input volume in Sound settings or move a little further from the mic.", false)
        }
        if peakDB < -35 {
            return ("Too quiet. Move closer to the mic or raise the input volume in Sound settings.", false)
        }
        return ("Good level. This microphone is ready for recording.", true)
    }
}
