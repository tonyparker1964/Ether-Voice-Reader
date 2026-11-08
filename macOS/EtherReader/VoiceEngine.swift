import Foundation

/// Owns the storage folder, the voice sample, the Python (MLX) voice engine install,
/// and a long-running worker process that keeps the voice model loaded.
final class VoiceEngine: ObservableObject {
    static let externalDrive = URL(fileURLWithPath: "/Volumes/MAC Mini 2")

    @Published var root: URL {
        didSet {
            UserDefaults.standard.set(root.path, forKey: "storagePath")
            stopWorker()
            refresh()
        }
    }
    @Published var installed = false
    @Published var installing = false
    @Published var log = ""
    @Published var generating = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var hasSample = false
    @Published var sampleSeconds: Double = 0
    @Published var transcript = ""
    @Published var lastNarration: URL?

    private var worker: Process?
    private var workerInput: FileHandle?
    private var buffer = Data()
    private var cancelled = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: "storagePath") {
            root = URL(fileURLWithPath: saved)
        } else {
            root = VoiceEngine.defaultRoot()
        }
        refresh()
    }

    static func defaultRoot() -> URL {
        if FileManager.default.fileExists(atPath: externalDrive.path) {
            return externalDrive.appendingPathComponent("Ether Reader")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Ether Reader")
    }

    // MARK: Paths

    var venv: URL { root.appendingPathComponent("venv") }
    var python: URL { venv.appendingPathComponent("bin/python") }
    var modelCache: URL { root.appendingPathComponent("model-cache") }
    var voiceDir: URL { root.appendingPathComponent("voice") }
    var sampleURL: URL { voiceDir.appendingPathComponent("reference.wav") }
    var transcriptURL: URL { voiceDir.appendingPathComponent("transcript.txt") }
    var narrationDir: URL { root.appendingPathComponent("narrations") }
    var marker: URL { venv.appendingPathComponent("ether-installed.txt") }
    var requirements: URL? { Bundle.main.url(forResource: "requirements", withExtension: "txt") }
    var script: URL? { Bundle.main.url(forResource: "ether_tts", withExtension: "py") }

    var rootIsOnExternalDrive: Bool { root.path.hasPrefix(VoiceEngine.externalDrive.path) }
    var externalDriveMounted: Bool { FileManager.default.fileExists(atPath: VoiceEngine.externalDrive.path) }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HF_HOME"] = modelCache.path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        return env
    }

    func refresh() {
        let fm = FileManager.default
        if let requirements,
           let wanted = try? String(contentsOf: requirements, encoding: .utf8),
           let have = try? String(contentsOf: marker, encoding: .utf8) {
            installed = (wanted == have) && fm.isExecutableFile(atPath: python.path)
        } else {
            installed = false
        }
        hasSample = fm.fileExists(atPath: sampleURL.path)
        sampleSeconds = hasSample ? MicManager.duration(of: sampleURL) : 0
        transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
    }

    // MARK: Voice sample

    func saveSample(from recording: URL, transcript words: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: sampleURL.path) { try fm.removeItem(at: sampleURL) }
        try fm.copyItem(at: recording, to: sampleURL)
        try words.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        refresh()
    }

    func saveTranscript(_ words: String) throws {
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        try words.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        refresh()
    }

    // MARK: Install

    func install() {
        guard !installing else { return }
        installing = true
        log = ""
        stopWorker()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.runInstall()
            DispatchQueue.main.async {
                self.installing = false
                self.refresh()
                self.appendLog(ok ? "\n✅ Voice engine installed.\n"
                                  : "\n⚠️ Installation stopped. Read the messages above.\n")
            }
        }
    }

    private func runInstall() -> Bool {
        guard let requirements, let script else {
            logAsync("The app is missing its voice engine files. Rebuild the app in Xcode.\n")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            logAsync("Cannot create \(root.path): \(error.localizedDescription)\n")
            return false
        }
        logAsync("Storage folder: \(root.path)\n")
        guard let systemPython = findPython() else {
            logAsync("""
            Python 3.10 or newer (Apple Silicon) was not found.
            Install Python 3.11 from https://www.python.org/downloads/macos/ \
            or run: brew install python@3.11
            Then press Install again.\n
            """)
            return false
        }
        logAsync("Using \(systemPython)\n")
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            logAsync("\n→ Creating Python environment…\n")
            guard run(systemPython, ["-m", "venv", venv.path]) == 0 else {
                logAsync("Could not create the environment. If the storage drive is formatted as ExFAT, choose a folder on an APFS or Mac OS Extended drive.\n")
                return false
            }
        }
        logAsync("\n→ Updating pip…\n")
        _ = run(python.path, ["-m", "pip", "install", "--upgrade", "pip"])
        logAsync("\n→ Installing voice packages (this can take several minutes)…\n")
        guard run(python.path, ["-m", "pip", "install", "-r", requirements.path]) == 0 else { return false }
        logAsync("\n→ Checking the installation…\n")
        guard run(python.path, [script.path, "--check"]) == 0 else { return false }
        do {
            try String(contentsOf: requirements, encoding: .utf8).write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            logAsync("Could not write install marker: \(error.localizedDescription)\n")
            return false
        }
        return true
    }

    private func findPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/usr/local/bin/python3", "/usr/bin/python3",
        ]
        let probe = "import sys,platform;print(sys.version_info>=(3,10) and platform.machine()=='arm64')"
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            var output = ""
            if run(path, ["-c", probe], quiet: true, capture: &output) == 0,
               output.trimmingCharacters(in: .whitespacesAndNewlines) == "True" {
                return path
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        var ignored = ""
        return run(executable, arguments, quiet: false, capture: &ignored)
    }

    /// Runs a process synchronously, streaming its output to the log (unless quiet).
    private func run(_ executable: String, _ arguments: [String], quiet: Bool, capture: inout String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
            if !quiet, let text = String(data: data, encoding: .utf8) { self.logAsync(text) }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            if !quiet { logAsync("Could not run \(executable): \(error.localizedDescription)\n") }
            return -1
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        collected.append(rest)
        if !quiet, !rest.isEmpty, let text = String(data: rest, encoding: .utf8) { logAsync(text) }
        capture = String(data: collected.data, encoding: .utf8) ?? ""
        return process.terminationStatus
    }

    // MARK: Log

    private func logAsync(_ text: String) {
        DispatchQueue.main.async { self.appendLog(text) }
    }

    func appendLog(_ text: String) {
        log += text
        if log.count > 60_000 { log = String(log.suffix(50_000)) }
    }

    // MARK: Narration

    func speak(_ text: String) {
        guard !generating else { return }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard installed else { status = "Install the voice engine first (Voice Engine page)."; return }
        guard hasSample else { status = "Record your voice first (Record Voice page)."; return }
        guard !words.isEmpty else { status = "Your voice sample needs its transcript (Record Voice page)."; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Paste or open some text to read."
            return
        }
        do {
            try FileManager.default.createDirectory(at: narrationDir, withIntermediateDirectories: true)
            try ensureWorker()
        } catch {
            status = "Could not start the voice engine: \(error.localizedDescription)"
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let out = narrationDir.appendingPathComponent("narration-\(stamp).wav")
        let request: [String: Any] = [
            "cmd": "speak", "text": text, "ref_audio": sampleURL.path,
            "ref_text": words, "out": out.path,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
        cancelled = false
        generating = true
        progress = 0
        status = "Starting the voice engine…"
        workerInput?.write(json + Data([0x0A]))
    }

    func cancel() {
        guard generating else { return }
        cancelled = true
        stopWorker()
    }

    private func ensureWorker() throws {
        if let worker, worker.isRunning { return }
        guard let script else { throw NSError(domain: "Ether", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voice engine script missing."]) }
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) { self?.logAsync(text) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.workerEnded() }
        }
        try process.run()
        worker = process
        workerInput = inPipe.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            guard line.hasPrefix("@@ETHER ") else {
                logAsync(line + "\n")
                continue
            }
            let payload = Data(line.dropFirst(8).utf8)
            if let event = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] {
                DispatchQueue.main.async { self.handle(event) }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let message = event["message"] as? String
        switch event["event"] as? String {
        case "status":
            if let message { status = message }
        case "progress":
            if let message { status = message }
            if let done = event["done"] as? Double, let total = event["total"] as? Double, total > 0 {
                progress = done / total
            }
        case "done":
            generating = false
            progress = 1
            let seconds = event["seconds"] as? Double ?? 0
            status = String(format: "Narration ready (%.0f seconds).", seconds)
            if let path = event["out"] as? String { lastNarration = URL(fileURLWithPath: path) }
        case "error":
            generating = false
            status = "Voice engine error: \(message ?? "unknown"). Details are on the Voice Engine page."
        default:
            break
        }
    }

    private func workerEnded() {
        worker = nil
        workerInput = nil
        if generating {
            generating = false
            status = cancelled ? "Stopped." : "The voice engine stopped unexpectedly. Details are on the Voice Engine page."
        }
    }

    func stopWorker() {
        if let worker, worker.isRunning { worker.terminate() }
    }
}

/// Thread-safe accumulator for process output.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock(); storage.append(chunk); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
