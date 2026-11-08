import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Microphone selection, hardware input volume, software boost, live metering and recording.
/// Uses AVAudioEngine (clean float capture at the mic's own sample rate) and writes 24-bit WAV.
final class MicManager: NSObject, ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID: String = ""
    @Published var averageDB: Float = -160
    @Published var peakDB: Float = -160
    @Published var clipping = false
    @Published var listening = false
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    /// Highest peak (dB, after Boost) during the most recent recording — before any clean-up.
    @Published var recordPeakDB: Float = -160
    @Published var message = ""
    /// Hardware input volume of the selected mic (0...1), or nil when the mic has no adjustable volume.
    @Published var hardwareVolume: Float?
    @Published var sampleRate: Double = 0
    @Published var softwareGainDB: Float = 0 {
        didSet {
            UserDefaults.standard.set(softwareGainDB, forKey: "softwareGainDB")
            state.setGain(MicManager.linear(softwareGainDB))
        }
    }

    private var engine: AVAudioEngine?
    private var currentDeviceID: AudioDeviceID?
    private let state = TapState()
    private let store = SampleStore()
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var maxSeconds: Double = 30
    private var outputURL: URL?
    private var cleanUp = false
    private var finish: ((URL?, String?) -> Void)?
    private var clipUntil = Date.distantPast
    private var configObserver: NSObjectProtocol?

    override init() {
        super.init()
        softwareGainDB = UserDefaults.standard.float(forKey: "softwareGainDB")
        state.setGain(MicManager.linear(softwareGainDB))
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
        guard id != selectedID, !recording else { return }
        selectedID = id
        if listening { startEngine() }
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
        withPermission { [weak self] in self?.startEngine() }
    }

    func stopListening() {
        if recording { stopRecording() }
        stopEngine()
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        listening = false
        meterTimer?.invalidate()
        averageDB = -160
        peakDB = -160
        clipping = false
    }

    private func startEngine() {
        stopEngine()
        guard let device = selectedDevice else {
            refreshDevices()
            return
        }
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let deviceID = MicManager.audioDeviceID(forUID: device.uniqueID)
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                message = "Could not switch to \(device.localizedName) (error \(status)). Using the system input instead."
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            message = "\(device.localizedName) isn't sending audio. Check that it's plugged in, then press Refresh."
            return
        }
        let state = self.state
        let store = self.store
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            state.process(buffer, store: store)
        }
        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            message = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        engine = newEngine
        currentDeviceID = deviceID
        sampleRate = format.sampleRate
        hardwareVolume = deviceID.flatMap { MicManager.inputVolume($0) }
        listening = true
        if !message.hasPrefix("Microphone access") && !message.hasPrefix("Could not switch") { message = "" }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main) { [weak self] _ in
            guard let self, self.listening, !self.recording else { return }
            self.refreshDevices()
            self.startEngine()
        }
        startMeter()
    }

    // MARK: Volume

    func setHardwareVolume(_ value: Float) {
        guard let currentDeviceID else { return }
        MicManager.setInputVolume(currentDeviceID, value)
        hardwareVolume = MicManager.inputVolume(currentDeviceID) ?? value
    }

    // MARK: Meter

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let meter = state.readMeter()
        averageDB = MicManager.db(meter.rms)
        let peak = MicManager.db(meter.peak)
        peakDB = max(peak, peakDB - 1.5)
        if peak > -1 { clipUntil = Date().addingTimeInterval(1.5) }
        clipping = Date() < clipUntil
        if recording, let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
            recordPeakDB = MicManager.db(state.recordPeak())
            if elapsed >= maxSeconds { stopRecording() }
        }
    }

    // MARK: Recording

    /// Records the selected mic (with Boost) to a 24-bit WAV at `url`.
    /// With `cleanUp`, removes rumble, lowers hiss between words and evens out the level.
    func record(to url: URL, maxSeconds: Double, cleanUp: Bool = false,
                completion: @escaping (URL?, String?) -> Void) {
        guard !recording else { return }
        withPermission { [weak self] in
            guard let self else { return }
            if !self.listening { self.startEngine() }
            guard self.listening, self.sampleRate > 0 else {
                completion(nil, self.message.isEmpty ? "No microphone is open." : self.message)
                return
            }
            self.outputURL = url
            self.cleanUp = cleanUp
            self.finish = completion
            self.maxSeconds = maxSeconds
            self.store.reset(capacity: Int(self.sampleRate * maxSeconds) + 4096)
            self.state.setRecording(true)
            self.recordPeakDB = -160
            self.elapsed = 0
            self.startedAt = Date()
            self.recording = true
        }
    }

    func stopRecording() {
        guard recording else { return }
        state.setRecording(false)
        recording = false
        startedAt = nil
        recordPeakDB = MicManager.db(state.recordPeak())
        let samples = store.take()
        let rate = sampleRate
        let url = outputURL
        let clean = cleanUp
        let callback = finish
        finish = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MicManager.writeRecording(samples, rate: rate, to: url, cleanUp: clean)
            DispatchQueue.main.async { callback?(result.url, result.error) }
        }
    }

    static func writeRecording(_ raw: [Float], rate: Double, to url: URL?, cleanUp: Bool) -> (url: URL?, error: String?) {
        guard let url else { return (nil, "No file to record to.") }
        guard rate > 0, raw.count > Int(rate * 0.2) else { return (nil, "Nothing was recorded.") }
        let samples = cleanUp ? AudioCleanup.process(raw, rate: rate) : raw
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                return (nil, "Could not prepare the recording.")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
            try file.write(from: buffer)
            return (url, nil)
        } catch {
            return (nil, "Could not save the recording: \(error.localizedDescription)")
        }
    }

    // MARK: CoreAudio helpers

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    static func inputVolume(_ id: AudioDeviceID) -> Float? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    static func setInputVolume(_ id: AudioDeviceID, _ newValue: Float) {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value = Float32(max(0, min(1, newValue)))
            _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    // MARK: Helpers

    static func db(_ value: Float) -> Float { value > 0.000_001 ? 20 * log10(value) : -160 }
    static func linear(_ db: Float) -> Float { pow(10, db / 20) }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// Plain-English advice for a peak level in dBFS.
    static func verdict(peakDB: Float) -> (text: String, good: Bool) {
        if peakDB > -1 {
            return ("Too loud — the sound is clipping, which causes distortion and crackle. Turn Mic volume or Boost down, or move back a little.", false)
        }
        if peakDB < -24 {
            return ("Too quiet — quiet recordings get hissy when they're turned up. Raise Mic volume first, then Boost, until your loudest words reach the yellow zone.", false)
        }
        return ("Good level. This microphone is ready for recording.", true)
    }
}

/// State shared with the real-time audio tap. All access is locked.
final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var gain: Float = 1
    private var recording = false
    private var windowPeak: Float = 0
    private var windowSum: Float = 0
    private var windowCount = 0
    private var peakWhileRecording: Float = 0
    private var channelEnergy: [Float] = []
    private var channel = 0

    func setGain(_ value: Float) {
        lock.lock(); gain = value; lock.unlock()
    }

    func setRecording(_ value: Bool) {
        lock.lock()
        recording = value
        if value { peakWhileRecording = 0 }
        lock.unlock()
    }

    func recordPeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        return peakWhileRecording
    }

    func readMeter() -> (rms: Float, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        let rms = windowCount > 0 ? (windowSum / Float(windowCount)).squareRoot() : 0
        let peak = windowPeak
        windowPeak = 0
        windowSum = 0
        windowCount = 0
        return (rms, peak)
    }

    func process(_ buffer: AVAudioPCMBuffer, store: SampleStore) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard count > 0, channels > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        // On multi-input interfaces, follow the input that actually has the voice (locked while recording).
        if !recording && channels > 1 {
            if channelEnergy.count != channels { channelEnergy = Array(repeating: 0, count: channels); channel = 0 }
            for c in 0..<channels {
                let samples = data[c]
                var energy: Float = 0
                for i in 0..<count { energy += samples[i] * samples[i] }
                channelEnergy[c] = channelEnergy[c] * 0.9 + energy * 0.1
            }
            if let best = channelEnergy.indices.max(by: { channelEnergy[$0] < channelEnergy[$1] }),
               channelEnergy[best] > channelEnergy[channel] * 4 {
                channel = best
            }
        }
        let samples = data[min(channel, channels - 1)]
        for i in 0..<count {
            let value = samples[i] * gain
            let magnitude = abs(value)
            if magnitude > windowPeak { windowPeak = magnitude }
            windowSum += value * value
        }
        windowCount += count
        if recording {
            if windowPeak > peakWhileRecording { peakWhileRecording = windowPeak }
            store.append(samples, count: count, gain: gain)
        }
    }
}

/// Recorded samples, filled from the audio thread.
final class SampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset(capacity: Int) {
        lock.lock()
        samples = []
        samples.reserveCapacity(capacity)
        lock.unlock()
    }

    func append(_ source: UnsafePointer<Float>, count: Int, gain: Float) {
        lock.lock()
        for i in 0..<count { samples.append(max(-1, min(1, source[i] * gain))) }
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}

/// Voice clean-up: DC + rumble removal, a gentle gate that lowers hiss between words,
/// and peak normalisation to −3 dBFS.
enum AudioCleanup {
    static func process(_ input: [Float], rate: Double) -> [Float] {
        let n = input.count
        guard n > 0, rate > 0 else { return input }
        var y = input

        // 1. Remove DC offset and rumble (high-pass at 80 Hz).
        let mean = y.reduce(0, +) / Float(n)
        let rc = 1.0 / (2.0 * Double.pi * 80.0)
        let alpha = Float(rc / (rc + 1.0 / rate))
        var previousIn: Float = 0
        var previousOut: Float = 0
        for i in 0..<n {
            let x = y[i] - mean
            let out = alpha * (previousOut + x - previousIn)
            previousIn = x
            previousOut = out
            y[i] = out
        }

        // 2. Gentle gate: estimate the background noise level, then lower quiet gaps by up to 15 dB.
        let frame = max(1, Int(rate * 0.02))
        let frames = (n + frame - 1) / frame
        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let start = f * frame
            let end = min(n, start + frame)
            var sum: Float = 0
            for i in start..<end { sum += y[i] * y[i] }
            rms[f] = (sum / Float(end - start)).squareRoot()
        }
        let noiseFloor = max(rms.sorted()[frames / 10], 1e-6)
        let closed = noiseFloor * 1.5
        let open = noiseFloor * 4
        let floorGain: Float = 0.18
        var target = [Float](repeating: 1, count: frames)
        for f in 0..<frames {
            let level = rms[f]
            if level >= open {
                target[f] = 1
            } else if level <= closed {
                target[f] = floorGain
            } else {
                target[f] = floorGain + (1 - floorGain) * (level - closed) / (open - closed)
            }
        }
        var held = target
        for f in 0..<frames where target[f] >= 0.999 {
            for k in max(0, f - 2)...min(frames - 1, f + 6) { held[k] = 1 }
        }
        var gains = [Float](repeating: 1, count: frames)
        var g = held[0]
        for f in 0..<frames {
            let t = held[f]
            g = t > g ? t : g + (t - g) * 0.4
            gains[f] = g
        }
        for i in 0..<n {
            let position = Float(i) / Float(frame) - 0.5
            let f0 = max(0, min(frames - 1, Int(position.rounded(.down))))
            let f1 = min(frames - 1, f0 + 1)
            let t = max(0, min(1, position - Float(f0)))
            y[i] *= gains[f0] * (1 - t) + gains[f1] * t
        }

        // 3. Normalise the loudest moment to −3 dBFS (at most +30 dB).
        let peak = y.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain = min(Float(0.708) / peak, Float(31.6))
            for i in 0..<n { y[i] *= gain }
        }

        // 4. Short fades so the file starts and ends without a click.
        let fade = min(n / 2, Int(rate * 0.01))
        if fade > 0 {
            for i in 0..<fade {
                let k = Float(i) / Float(fade)
                y[i] *= k
                y[n - 1 - i] *= k
            }
        }
        return y
    }
}
