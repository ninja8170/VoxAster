import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

#if !PHASE1_TESTS
@main
struct VoxAsterApp: App {
    @NSApplicationDelegateAdaptor(DraftQuitDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var ui = StudioUI()
    @StateObject private var cleaner = ReferenceCleaner()
    @StateObject private var doctor = TakeDoctor()
    @StateObject private var cast = CastStore()

    var body: some Scene {
        Window("VoxAster", id: "main") {
            StudioRoot()
                .environmentObject(model)
                .environmentObject(ui)
                .environmentObject(cleaner)
                .environmentObject(doctor)
                .environmentObject(cast)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)
        .commands { StudioCommands(model: model, ui: ui, cast: cast) }

        Window("Engine Lab", id: "engine-lab") {
            EngineLabWindow()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 680)

        Settings {
            PreferencesView().environmentObject(model)
        }
    }
}

#endif

enum AppSection: String, CaseIterable {
    case clone = "Voice Clone"
    case design = "Voice Design"
    case library = "Library"
    case history = "History"
    case longForm = "Long Form"
    case performance = "Performance"
    case projects = "Projects"
    case engineLab = "Engine Lab"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .clone: return "mic.fill"
        case .design: return "slider.horizontal.3"
        case .library: return "folder"
        case .history: return "clock"
        case .longForm: return "text.document"
        case .performance: return "waveform.path"
        case .projects: return "square.grid.2x2"
        case .engineLab: return "testtube.2"
        case .settings: return "gearshape"
        }
    }
}

final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        if loadedURL == url, player != nil { return }
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            loadedURL = url
            duration = player?.duration ?? 0
            currentTime = 0
            isPlaying = false
        } catch {
            player = nil
            duration = 0
        }
    }

    func isPlaying(_ url: URL) -> Bool {
        loadedURL == url && isPlaying
    }

    func currentTime(for url: URL) -> Double {
        loadedURL == url ? currentTime : 0
    }

    func duration(for url: URL) -> Double {
        if loadedURL == url { return duration }
        return (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
    }

    func seek(_ url: URL, to value: Double) {
        if loadedURL != url { load(url) }
        seek(to: value)
    }

    func toggle(_ url: URL) {
        load(url)
        guard let player else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to value: Double) {
        guard let player else { return }
        let clamped = max(0, min(value, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying {
                self.isPlaying = false
                self.stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}

final class RecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pendingURL: URL?
    private var onFinished: ((URL?) -> Void)?

    func toggle(onFinished: @escaping (URL?) -> Void) {
        if isRecording {
            stop()
            return
        }

        self.onFinished = onFinished
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.permissionDenied = true
                    self.onFinished?(nil)
                    self.onFinished = nil
                    return
                }
                self.start()
            }
        }
    }

    private func start() {
        // Remove an abandoned temporary take before creating another.
        if let old = pendingURL {
            try? FileManager.default.removeItem(at: old)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxaster-recording-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            newRecorder.prepareToRecord()

            guard newRecorder.record() else {
                try? FileManager.default.removeItem(at: url)
                onFinished?(nil)
                onFinished = nil
                return
            }

            recorder = newRecorder
            pendingURL = url
            elapsed = 0
            isRecording = true

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            isRecording = false
            onFinished?(nil)
            onFinished = nil
        }
    }

    func stop() {
        guard isRecording else { return }

        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        let finished = pendingURL
        pendingURL = nil

        // Publish the reference only after AVAudioRecorder has closed/finalized the WAV.
        if let finished,
           let attrs = try? FileManager.default.attributesOfItem(atPath: finished.path),
           let bytes = attrs[.size] as? NSNumber,
           bytes.intValue > 44 {
            onFinished?(finished)
        } else {
            if let finished { try? FileManager.default.removeItem(at: finished) }
            onFinished?(nil)
        }

        onFinished = nil
        elapsed = 0
    }
}
enum PythonBackendLaunch {
    static func arguments(server: String) -> [String] { ["-B", server] }

    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return environment
    }
}

final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .clone

    @Published var referenceURL: URL? { didSet { referenceDidChange() } }
    @Published var referenceIdentity: ReferenceIdentity?
    @Published var unverifiedReferenceTranscript: String?
    var transcriptReferenceID: UUID?
    var analysisBinding: ReferenceAnalysisBinding?
    @Published var referenceText = "" { didSet { transcriptDidChange() } }
    @Published var cloneText = "The future sounds better together." { didSet { draftChanged() } }
    @Published var cloneLanguage = "Auto detect" { didSet { draftChanged() } }
    @Published var clonePronunciationRules = "" { didSet { draftChanged() } }
    @Published var designMode = "Design" { didSet { draftChanged() } }
    @Published var designDialect = "Auto" { didSet { draftChanged() } }
    @Published var designPreset = "Custom" { didSet { draftChanged() } }

    @Published var designText = "Create a voice that sounds natural, confident and warm." { didSet { draftChanged() } }
    @Published var designGender = "Auto" { didSet { draftChanged() } }
    @Published var designAge = "Auto" { didSet { draftChanged() } }
    @Published var designPitch = "Auto" { didSet { draftChanged() } }
    @Published var designAccent = "Auto" { didSet { draftChanged() } }
    @Published var designStyle = "Auto" { didSet { draftChanged() } }

    @Published var speed = 1.0 { didSet { draftChanged() } }
    @Published var steps = 32.0 { didSet { draftChanged() } }
    @Published var guidance = 2.0 { didSet { draftChanged() } }
    let runtimeSetup = RuntimeSetupController()
    @Published var runtimeSelection: RuntimeSelection?
    @Published var runtimeProvenance: [String: String] = [:]
    @Published var generationSeed = 0 { didSet { draftChanged() } }
    @Published var denoiseOutput = true { didSet { draftChanged() } }
    @Published var useDuration = false { didSet { draftChanged() } }
    @Published var targetDuration = 10.0 { didSet { draftChanged() } }
    @Published var timeShift = 0.1 { didSet { draftChanged() } }
    @Published var positionTemperature = 5.0 { didSet { draftChanged() } }
    @Published var classTemperature = 0.0 { didSet { draftChanged() } }
    @Published var layerPenaltyFactor = 5.0 { didSet { draftChanged() } }
    @Published var cloneMatchInsideWords = false { didSet { draftChanged() } }
    @Published var longFormMatchInsideWords = false { didSet { draftChanged() } }
    @Published var designPronunciationRules = "" { didSet { draftChanged() } }
    @Published var designMatchInsideWords = false { didSet { draftChanged() } }
    var engineLabSupportsNative: Bool { engineLabEngineA != "F5-TTS" && engineLabEngineB != "F5-TTS" }


    // Reference Analyzer / Auto Tune
    @Published var referenceAnalyzing = false
    @Published var referenceAnalysisReady = false
    @Published var referenceAnalysisStatus = "Analyze a reference to get voice-specific settings."
    @Published var referenceDuration = 0.0
    @Published var referencePitch = 0.0
    @Published var referencePitchRange = 0.0
    @Published var referenceRMS = -60.0
    @Published var referencePeak = -60.0
    @Published var referenceSpeechRatio = 0.0
    @Published var referencePauseRatio = 0.0
    @Published var referenceWPM = 0.0
    @Published var referenceQualityScore = 0
    @Published var referenceQualityLabel = "Not analyzed"
    @Published var referencePaceLabel = "Unknown"
    @Published var recommendedSpeed = 1.0
    @Published var recommendedSteps = 32.0
    @Published var recommendedGuidance = 2.0
    @Published var recommendedDenoise = true
    @Published var isGenerating = false
    @Published var status = "Starting model…"
    @Published var modelReady = false
    @Published var outputURL: URL?
    @Published var errorMessage: String?

    // Engine Lab
    @Published var engineLabText = "Artificial intelligence is changing the way we create, communicate, and understand the world." { didSet { draftChanged() } }
    @Published var engineLabRunning = false
    @Published var engineLabStatus = "Ready"
    @Published var engineLabA: URL?
    @Published var engineLabB: URL?
    @Published var engineLabMap: [String: String] = [:]
    @Published var engineLabRevealed = false
    @Published var engineLabWinner: String?
    @Published var engineLabAvailableEngines: [String] = ["OmniVoice Zero-Shot"]
    @Published var engineLabEngineA = "OmniVoice Zero-Shot" { didSet { draftChanged() } }
    @Published var engineLabEngineB = "F5-TTS" { didSet { draftChanged() } }
    @Published var f5Available = false

    @Published var trainedEngines: [String] = []

    @Published var preset = "Natural" { didSet { draftChanged() } }
    private var synchronizingProduction = false
    @Published var longFormText = "" {
        didSet {
            if !synchronizingProduction && oldValue != longFormText {
                productionChunks = []
                longFormOutputURL = nil
            }
            draftChanged()
        }
    }
    @Published var longFormProgress: Double = 0
    @Published var longFormStatus = "Ready"
    @Published var longFormOutputURL: URL?
    @Published var pronunciationRules = "" { didSet { draftChanged() } }
    @Published var projectName = "My Voice Project" { didSet { draftChanged() } }
    @Published var projects: [VoiceProject] = []
    @Published var currentProjectID: UUID?
    @Published var projectStatus = "Unsaved project"
    @Published var activeProjectGenerationIDs: [UUID] = []
    @Published var performanceText = "A setup. [pause 500ms] A punchline." { didSet { draftChanged() } }
    @Published var performanceRules = "" { didSet { draftChanged() } }
    @Published var performanceMatchInsideWords = false { didSet { draftChanged() } }
    @Published var performanceBusy = false
    @Published var performanceStatus = "Prepare a production to freeze its segments."
    @Published var performanceProduction: PerformanceProduction?
    @Published var performanceHistory: [PerformanceSummary] = []
    @Published var variantCount = 2 { didSet { draftChanged() } }
    @Published var variantURLs: [URL] = []
    @Published var productionChunks: [ProductionChunk] = [] { didSet { draftChanged() } }
    @Published var currentChunkIndex = 0

    @Published var generations: [Generation] = []
    @Published var savedVoices: [SavedVoice] = []

    @Published var autoPlay = true
    @Published var keepOutputs = true

    let outputPlayer = AudioPlayerController()
    let referencePlayer = AudioPlayerController()
    let recorder = RecorderController()

    private var backend: Process?
    private var storageOverride: URL?
    let session: URLSession

    struct Generation: Identifiable, Codable, Equatable {
        var id = UUID()
        let text: String
        let path: String
        let createdAt: Date
        let mode: String
        var url: URL { URL(fileURLWithPath: path) }
    }

    struct SavedVoice: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        let path: String
        var transcript: String
        let createdAt: Date
        var referenceSHA256: String? = nil
        var url: URL { URL(fileURLWithPath: path) }
    }

    struct ProductionChunk: Identifiable {
        let id = UUID()
        var text: String
        var state: String = "Pending"
        var output: URL?
    }

    struct VoiceProject: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        var referencePath: String?
        var referenceText: String
        var pronunciationRules: String
        var generationIDs: [UUID]
        var createdAt: Date
        var updatedAt: Date
        var referenceSHA256: String? = nil
    }

    var draftsEnabled = false
    var draftSuspended = false
    var draftLoadFailed = false
    var projectLoadFailed = false
    var draftBook = DraftBook()
    @Published var draftStatus = "Draft recovery not started"
    @Published var recoverableDrafts: [DraftSummary] = []
    var persistenceWrite: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    init(startServices: Bool = true, storageRoot: URL? = nil, session: URLSession = .shared, recoverDrafts: Bool = false) {
        self.session = session
        storageOverride = storageRoot
        if startServices || recoverDrafts {
            do { try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true) }
            catch { errorMessage = "Draft storage unavailable: \(error.localizedDescription)" }
            loadPersistentData()
            restoreDrafts()
            draftsEnabled = true
        }
        guard startServices else { return }
        createDirectories()
        runtimeSetup.beforeInstall = { [weak self] in self?.stopBackend() }
        runtimeSetup.onReady = { [weak self] selection in
            guard let self else { return }
            self.runtimeSelection = selection
            self.startBackend()
            self.pollHealth()
        }
        status = "Checking runtime"
        runtimeSetup.inspect(legacy: documentsRoot.appendingPathComponent(".venv/bin/python"))
    }

    deinit {
        if let p = backend, p.isRunning { p.terminate() }
    }

    nonisolated static var documentsRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OmniVoice-Mac", isDirectory: true)
    }

    private var documentsRoot: URL { Self.documentsRootURL }

    private var outputsDir: URL { documentsRoot.appendingPathComponent("outputs", isDirectory: true) }
    private var voicesDir: URL { documentsRoot.appendingPathComponent("voices", isDirectory: true) }

    var appSupport: URL {
        if let storageOverride { return storageOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniVoice", isDirectory: true)
    }

    private var historyFile: URL { appSupport.appendingPathComponent("history.json") }
    private var voicesFile: URL { appSupport.appendingPathComponent("voices.json") }
    private var projectsFile: URL { appSupport.appendingPathComponent("projects.json") }

    private func createDirectories() {
        for dir in [documentsRoot, outputsDir, voicesDir, appSupport] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func stopBackend() {
        runtimeSetup.cancel()
        guard let process = backend, process.isRunning else { return }
        process.terminate()
        // A backend stuck in a GPU call can ignore SIGTERM; an unbounded
        // waitUntilExit() then freezes the app on quit. Escalate instead.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        backend = nil
        modelReady = false
    }

    func startBackend() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let python = runtimeSelection?.python.path ?? "\(home)/Documents/OmniVoice-Mac/.venv/bin/python"

        guard let resources = Bundle.main.resourcePath else {
            status = "App resources unavailable"
            return
        }
        let server = "\(resources)/backend.py"

        guard fm.fileExists(atPath: python), fm.fileExists(atPath: server) else {
            status = "Runtime setup required"
            runtimeSetup.presented = true
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = PythonBackendLaunch.arguments(server: server)

        var env = runtimeSelection.map { runtimeSetup.environment(selection: $0) } ?? PythonBackendLaunch.environment(from: ProcessInfo.processInfo.environment)

        // Finder/LaunchServices apps do not reliably inherit the shell PATH.
        // Always expose Homebrew/system tools such as ffmpeg to the Python backend.
        let requiredPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPath = env["PATH"] ?? ""
        let existingParts = existingPath.split(separator: ":").map(String.init)
        let mergedPath = requiredPaths + existingParts.filter { !requiredPaths.contains($0) }
        if runtimeSelection?.managed == nil { env["PATH"] = mergedPath.joined(separator: ":") }

        p.environment = env

        let logDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OmniVoice")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("native-backend.log")
        fm.createFile(atPath: logURL.path, contents: nil)

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        }

        do {
            try p.run()
            backend = p
            p.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    self?.modelReady = false
                    self?.status = "Backend stopped"
                    if process.terminationStatus != 0 {
                        self?.errorMessage = "The backend exited. Check ~/Library/Logs/OmniVoice/native-backend.log. Verify runtime setup and that port 8011 is free, then reopen the app."
                    }
                }
            }
        } catch {
            status = "Could not start model backend"
            errorMessage = error.localizedDescription
        }
    }

    func pollHealth() {
        guard let url = URL(string: "http://127.0.0.1:8011/health") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1

        session.dataTask(with: req) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    guard let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          json["ok"] as? Bool == true,
                          json["generation_contract"] as? Int == 3,
                          let provenance = json["provenance"] as? [String: String] else {
                        self?.modelReady = false
                        self?.status = "Incompatible backend"
                        self?.errorMessage = "Close the older app/backend before using this build."
                        return
                    }
                    self?.runtimeProvenance = provenance
                    self?.modelReady = true
                    self?.status = "Model Ready"
                    self?.checkEngineLab()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard self?.backend?.isRunning == true else { return }
                        self?.pollHealth()
                    }
                }
            }
        }.resume()
    }


    func checkEngineLab() {
        guard let url = URL(string: "http://127.0.0.1:8011/engine-lab/status") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                self?.f5Available = (json["f5_available"] as? Bool) ?? false

                if let engines = json["engines"] as? [String], !engines.isEmpty {
                    self?.engineLabAvailableEngines = engines
                    self?.trainedEngines = engines.filter { $0 != "OmniVoice Zero-Shot" && $0 != "F5-TTS" }

                    if let currentA = self?.engineLabEngineA, !engines.contains(currentA) {
                        self?.engineLabEngineA = engines.first ?? "OmniVoice Zero-Shot"
                    }

                    if let currentB = self?.engineLabEngineB, !engines.contains(currentB) {
                        self?.engineLabEngineB = engines.first(where: { $0 != self?.engineLabEngineA }) ?? (engines.first ?? "OmniVoice Zero-Shot")
                    }
                }
            }
        }.resume()
    }

    func runEngineComparison() {
        guard let ref = referenceURL,
              !engineLabText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        engineLabRunning = true
        engineLabStatus = "Generating both engines…"
        engineLabA = nil
        engineLabB = nil
        engineLabMap = [:]
        engineLabWinner = nil
        engineLabRevealed = false

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/engine-lab/compare")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1800

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        guard let fields = generationFields(text: engineLabText, pronunciations: clonePronunciationRules,
                                            language: cloneLanguage, matchInsideWords: cloneMatchInsideWords,
                                            nativeAdvanced: engineLabSupportsNative) else {
            engineLabRunning = false
            return
        }
        for (name, value) in fields { field(name, value) }
        field("engine_a", engineLabEngineA)
        field("engine_b", engineLabEngineB)

        if let data = try? Data(contentsOf: ref) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ref_audio\"; filename=\"\(ref.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.engineLabRunning = false

                if let error {
                    self?.engineLabStatus = "Failed"
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self?.engineLabStatus = "Failed"
                    self?.errorMessage = "Engine Lab returned an unreadable response."
                    return
                }

                if let error = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.engineLabStatus = "Failed"
                    self?.errorMessage = error
                    return
                }

                guard let a = json["A"] as? String,
                      let b = json["B"] as? String,
                      let mapping = json["map"] as? [String: String]
                else {
                    self?.engineLabStatus = "Failed"
                    self?.errorMessage = "Engine Lab did not return two comparison files."
                    return
                }

                self?.engineLabA = URL(fileURLWithPath: a)
                self?.engineLabB = URL(fileURLWithPath: b)
                self?.engineLabMap = mapping
                self?.engineLabStatus = "Ready — listen and choose before revealing."
            }
        }.resume()
    }

    func revealEngineComparison() {
        engineLabRevealed = true
    }



    func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            if let url = panel.url { selectReference(url) }
        }
    }

    func acceptDroppedAudio(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { [weak self] item, _ in
                guard let resolved = item as? URL, resolved.isFileURL else { return }
                DispatchQueue.main.async {
                    self?.selectReference(resolved)
                }
            }
            return true
        }
        return false
    }

    func startRecording() {
        recorder.toggle { [weak self] url in
            guard let self else { return }
            if let url {
                self.selectRecordedReference(url)
            } else if self.recorder.permissionDenied {
                self.errorMessage = "Microphone access is disabled. Enable VoxAster in System Settings → Privacy & Security → Microphone."
            } else {
                self.errorMessage = "The recording could not be saved. Please try again."
            }
        }
    }

    func saveCurrentVoice(named name: String) {
        guard let source = referenceURL else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let safeName = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var destination = voicesDir.appendingPathComponent("\(safeName).\(ext)")

        if FileManager.default.fileExists(atPath: destination.path) {
            destination = voicesDir.appendingPathComponent("\(safeName)-\(UUID().uuidString.prefix(6)).\(ext)")
        }

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            guard let identity = referenceIdentity, referenceMatches(identity), try SafeFiles.digest(destination) == identity.sha256 else {
                try? FileManager.default.removeItem(at: destination)
                throw ReliabilityError(message: "The reference changed while saving. Select it again before saving its transcript.")
            }
            let saved = SavedVoice(
                name: trimmed,
                path: destination.path,
                transcript: referenceText,
                createdAt: Date(),
                referenceSHA256: try SafeFiles.digest(destination)
            )
            savedVoices.insert(saved, at: 0)
            saveVoices()
        } catch {
            errorMessage = "Could not save voice: \(error.localizedDescription)"
        }
    }

    func selectEngineLabVoice(_ voice: SavedVoice) {
        selectReference(voice.url, transcript: voice.transcript, expectedSHA256: voice.referenceSHA256)
    }

    func useVoice(_ voice: SavedVoice) {
        if selectReference(voice.url, transcript: voice.transcript, expectedSHA256: voice.referenceSHA256) { selectedSection = .clone }
    }

    func deleteVoice(_ voice: SavedVoice) {
        try? FileManager.default.removeItem(at: voice.url)
        savedVoices.removeAll { $0.id == voice.id }
        saveVoices()
    }

    private func saveProjects(_ records: [VoiceProject]) throws {
        guard !projectLoadFailed else { throw ReliabilityError(message: "Existing project records could not be read. Repair or restore projects.json before saving; it has not been overwritten.") }
        try persistenceWrite(JSONEncoder().encode(records), projectsFile)
    }

    func newProject() {
        guard canSwitchDraft() else { return }
        applyDraft(EditableDraft())
        draftBook.activeKey = UUID().uuidString
        projectStatus = "New project — recoverable draft only"
        _ = persistDraft()
    }

    func saveCurrentProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Enter a project name before saving."; return }
        guard canSwitchDraft() else { return }
        let now = Date()
        let id = currentProjectID ?? UUID()
        var records = projects
        let record = VoiceProject(id: id, name: name, referencePath: referenceURL?.path,
            referenceText: referenceText, pronunciationRules: pronunciationRules,
            generationIDs: activeProjectGenerationIDs,
            createdAt: records.first(where: { $0.id == id })?.createdAt ?? now, updatedAt: now,
            referenceSHA256: referenceIdentity?.sha256)
        records.removeAll { $0.id == id }; records.append(record)
        records.sort { $0.updatedAt > $1.updatedAt }
        do {
            try saveProjects(records)
            projects = records; currentProjectID = id
            draftBook.activeKey = id.uuidString
            if persistDraft() { projectStatus = "Project record and editable draft saved — not a full production session" }
        } catch {
            projectStatus = "Project save failed — editable draft retained"
            errorMessage = "Could not save project: \(error.localizedDescription). Your active work has not been cleared."
        }
    }

    func openProject(_ p: VoiceProject) {
        guard canSwitchDraft() else { return }
        let key = p.id.uuidString
        if let draft = draftBook.drafts[key] { applyDraft(draft) }
        else {
            var draft = EditableDraft()
            draft.projectID = p.id; draft.projectName = p.name
            draft.referencePath = p.referencePath; draft.referenceSHA256 = p.referenceSHA256
            draft.referenceText = p.referenceText; draft.pronunciationRules = p.pronunciationRules
            applyDraft(draft)
        }
        currentProjectID = p.id; activeProjectGenerationIDs = p.generationIDs
        draftBook.activeKey = key
        projectStatus = "Opened project record and editable draft — production results are separate"
        _ = persistDraft()
    }

    func deleteProject(_ p: VoiceProject) {
        guard canSwitchDraft() else { return }
        let records = projects.filter { $0.id != p.id }
        do {
            try saveProjects(records); projects = records
            if currentProjectID == p.id {
                currentProjectID = nil
                projectStatus = "Project record removed; editable draft retained"
                _ = persistDraft()
            }
        } catch { errorMessage = "Could not remove project record: \(error.localizedDescription)" }
    }

    func projectOutputs(_ p: VoiceProject?) -> [Generation] {
        let ids: Set<UUID>
        if let p {
            ids = Set(p.generationIDs)
        } else {
            ids = Set(activeProjectGenerationIDs)
        }
        return generations.filter { ids.contains($0.id) }
    }

    /// Adds a finished take (Cast master, repaired take) to history and the active project.
    func recordTake(path: String, text: String, mode: String) {
        let item = Generation(text: text, path: path, createdAt: Date(), mode: mode)
        generations.insert(item, at: 0)
        registerGenerationWithActiveProject(item.id)
        saveHistory()
    }

    private func registerGenerationWithActiveProject(_ id: UUID) {
        let isNewUnsavedProject = currentProjectID == nil && projectStatus.hasPrefix("New project")
        let isSavedProjectOpen = currentProjectID != nil

        guard isNewUnsavedProject || isSavedProjectOpen else { return }

        if !activeProjectGenerationIDs.contains(id) {
            activeProjectGenerationIDs.append(id)
        }

        // Keep an already-saved/open project in sync immediately so a generated
        // output belongs to that project even before the user presses Save Changes.
        if let projectID = currentProjectID,
           let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].generationIDs = activeProjectGenerationIDs
            projects[index].updatedAt = Date()
            do { try saveProjects(projects) }
            catch { projectStatus = "Project update failed"; errorMessage = "Could not save project output association: \(error.localizedDescription)" }
        }
    }

    func generationFields(text: String, pronunciations: String = "", language: String = "Auto detect",
                          instruct: String = "", segments: [String]? = nil,
                          retryIndex: Int? = nil, matchInsideWords: Bool = false,
                          nativeAdvanced: Bool = true, allowDuration: Bool = true, checkReference: Bool = true) -> [String: String]? {
        do {
            if checkReference, let identity = referenceIdentity, !referenceMatches(identity) {
                throw ReliabilityError(message: "Reference audio changed or is missing. Select it again before generation; its previous transcript cannot be reused.")
            }
            guard steps.isFinite, (8...64).contains(steps) else { throw GenerationRequest.RequestError.invalid }
            return try GenerationRequest(text: text, refText: referenceText,
                pronunciations: pronunciations, language: language, instruct: instruct,
                speed: speed, steps: Int(steps), guidance: guidance,
                seed: generationSeed, denoise: denoiseOutput,
                duration: nativeAdvanced && allowDuration && useDuration ? targetDuration : nil,
                timeShift: nativeAdvanced ? timeShift : 0.1,
                positionTemperature: nativeAdvanced ? positionTemperature : 5,
                classTemperature: nativeAdvanced ? classTemperature : 0,
                layerPenaltyFactor: nativeAdvanced ? layerPenaltyFactor : 5,
                pronunciationMode: matchInsideWords ? "substring" : "words", count: variantCount,
                segments: segments, retryIndex: retryIndex).fields()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func applyPreset(_ name: String) {
        preset = name
        if name == "Auto Tuned" { return }
        switch name {
        case "Fast Preview": steps = 16; guidance = 2.0; speed = 1.0
        case "Maximum Quality": steps = 48; guidance = 2.2; speed = 1.0
        case "Narration": steps = 36; guidance = 2.1; speed = 0.95
        default: steps = 32; guidance = 2.0; speed = 1.0
        }
    }

    func prepareProductionChunks() {
        let cleaned = longFormText.replacingOccurrences(of: "\n", with: " ")
        let sentences = cleaned.components(separatedBy: ". ")
        var chunks:[ProductionChunk]=[]; var current=""
        for sentence in sentences {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            let candidate = current.isEmpty ? s : current + ". " + s
            if candidate.count > 420 && !current.isEmpty {
                chunks.append(ProductionChunk(text: current + "."))
                current = s
            } else { current = candidate }
        }
        if !current.isEmpty { chunks.append(ProductionChunk(text: current)) }
        productionChunks = chunks
    }

    func updateChunk(_ index:Int, text:String) {
        guard productionChunks.indices.contains(index) else{return}
        productionChunks[index].text=text
        productionChunks[index].state="Edited"
        productionChunks[index].output=nil
        synchronizingProduction = true
        longFormText = productionChunks.map(\.text).joined(separator: " ")
        synchronizingProduction = false
        longFormOutputURL = nil
    }

    func retryChunk(_ index:Int) {
        guard productionChunks.indices.contains(index), !isGenerating else { return }
        executeLongForm(retryIndex: index)
    }

    func generateVariants() {
        guard let ref=referenceURL, !cloneText.isEmpty else{return}
        isGenerating=true; variantURLs=[]
        var req=URLRequest(url:URL(string:"http://127.0.0.1:8011/generate-variants")!)
        req.httpMethod="POST"; req.timeoutInterval=1200
        let boundary=UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var body=Data()
        func f(_ n:String,_ v:String){body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using:.utf8)!)}
        guard let fields = generationFields(text: cloneText, pronunciations: clonePronunciationRules,
                                            language: cloneLanguage, matchInsideWords: cloneMatchInsideWords) else { isGenerating = false; return }
        for (name, value) in fields { f(name, value) }
        if let d=try? Data(contentsOf:ref){body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"ref_audio\"; filename=\"\(ref.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using:.utf8)!);body.append(d);body.append("\r\n".data(using:.utf8)!)}
        body.append("--\(boundary)--\r\n".data(using:.utf8)!);req.httpBody=body
        session.dataTask(with:req){[weak self] data,_,_ in DispatchQueue.main.async{
            self?.isGenerating=false
            guard let data, let j = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { self?.errorMessage="Variant generation failed."; return }
            if let error = j["error"] as? String ?? j["detail"] as? String { self?.errorMessage=error; return }
            guard let paths = j["outputs"] as? [String] else { self?.errorMessage="Variant generation failed."; return }
            self?.variantURLs=paths.map{URL(fileURLWithPath:$0)}
        }}.resume()
    }

    func generateLongForm() { executeLongForm(retryIndex: nil) }

    private func executeLongForm(retryIndex: Int?) {
        guard modelReady, !isGenerating, let ref = referenceURL else { return }
        if productionChunks.isEmpty { prepareProductionChunks() }
        let sourceSegments = productionChunks.map(\.text)
        let sourceIDs = productionChunks.map(\.id)
        let sourceText = sourceSegments.joined(separator: " ")
        guard let fields = generationFields(text: sourceText, pronunciations: pronunciationRules,
            segments: sourceSegments, retryIndex: retryIndex, matchInsideWords: longFormMatchInsideWords, allowDuration: false) else { return }
        longFormOutputURL = nil
        if let retryIndex { productionChunks[retryIndex].state = "Generating" }
        errorMessage = nil
        isGenerating = true
        longFormProgress = 0.15
        longFormStatus = "Generating sections…"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/generate-long")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        for (name, value) in fields { field(name, value) }
        if let data = try? Data(contentsOf: ref) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ref_audio\"; filename=\"\(ref.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isGenerating = false
                guard let self else { return }
                guard self.productionChunks.map(\.text) == sourceSegments,
                      self.productionChunks.map(\.id) == sourceIDs else {
                    self.longFormStatus = "Script changed — generate the edited source again"
                    return
                }
                if let retryIndex { self.productionChunks[retryIndex].state = "Failed" }
                if let error {
                    self.longFormStatus = "Failed"
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else {
                    self.errorMessage = "Unreadable response from VoxAster."
                    return
                }
                if let message = (json["error"] as? String ?? json["detail"] as? String) {
                    self.longFormStatus = "Failed"; self.errorMessage = message; return
                }
                guard let path = json["output"] as? String else { return }
                let url = URL(fileURLWithPath: path)
                if let retryIndex {
                    self.productionChunks[retryIndex].output = url
                    self.productionChunks[retryIndex].state = "Complete"
                    self.longFormStatus = "Section regenerated — generate master to include this edit"
                    self.outputURL = url
                    if self.autoPlay { self.outputPlayer.toggle(url) }
                    return
                }
                if let paths = json["segment_outputs"] as? [String], paths.count == sourceSegments.count {
                    for i in paths.indices {
                        self.productionChunks[i].output = URL(fileURLWithPath: paths[i])
                        self.productionChunks[i].state = "Complete"
                    }
                }
                self.longFormOutputURL = url
                self.outputURL = url
                self.longFormProgress = 1
                self.longFormStatus = "Complete • \(json["chunks"] as? Int ?? 1) sections"
                do {
                    let text = sourceText
                    let item = Generation(text: text, path: path, createdAt: Date(), mode: "Long Form")
                    self.generations.insert(item, at: 0)
                    self.registerGenerationWithActiveProject(item.id)
                    self.saveHistory()
                }
                if self.autoPlay == true { self.outputPlayer.toggle(url) }
            }
        }.resume()
    }

    func resetGenerationDefaults() {
        speed = 1; steps = 32; guidance = 2; denoiseOutput = true; generationSeed = 0
        useDuration = false; targetDuration = 10
        timeShift = 0.1; positionTemperature = 5; classTemperature = 0; layerPenaltyFactor = 5
        preset = "Natural"
    }

    func inspectSpeech(text: String, rules: String, matchMode: String, performance: Bool = false) async throws -> SpeechInspection {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string:"http://127.0.0.1:8011/" + (performance ? "performance/preview" : "preview-speech"))!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField:"Content-Type")
        var body = Data()
        for (name, value) in ["text":text, "pronunciations":rules, "pronunciation_mode":matchMode] {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using:.utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using:.utf8)!)
        request.httpBody = body
        let (data, response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GenerationRequest.RequestError.invalid }
        return try JSONDecoder().decode(SpeechInspection.self, from:data)
    }

    func applyDesignPreset(_ name: String) {
        designPreset = name

        // Every preset explicitly sets every design field so tapping a preset
        // always produces an obvious, deterministic UI change.
        switch name {
        case "Audiobook":
            designMode = "Design"
            designGender = "Auto"
            designAge = "middle-aged"
            designPitch = "low pitch"
            designAccent = "British accent"
            designStyle = "Auto"
            designDialect = "Auto"

        case "News Anchor":
            designMode = "Design"
            designGender = "Auto"
            designAge = "middle-aged"
            designPitch = "moderate pitch"
            designAccent = "British accent"
            designStyle = "Auto"
            designDialect = "Auto"

        case "NPC":
            designMode = "Auto"
            designGender = "Auto"
            designAge = "Auto"
            designPitch = "Auto"
            designAccent = "Auto"
            designStyle = "Auto"
            designDialect = "Auto"

        case "Podcast":
            designMode = "Design"
            designGender = "Auto"
            designAge = "young adult"
            designPitch = "low pitch"
            designAccent = "American accent"
            designStyle = "Auto"
            designDialect = "Auto"

        case "Language Tutor":
            designMode = "Design"
            designGender = "Auto"
            designAge = "young adult"
            designPitch = "moderate pitch"
            designAccent = "British accent"
            designStyle = "Auto"
            designDialect = "Auto"

        case "Customer Support":
            designMode = "Design"
            designGender = "Auto"
            designAge = "young adult"
            designPitch = "moderate pitch"
            designAccent = "American accent"
            designStyle = "Auto"
            designDialect = "Auto"

        case "Whisper":
            designMode = "Design"
            designGender = "Auto"
            designAge = "young adult"
            designPitch = "low pitch"
            designAccent = "Auto"
            designStyle = "whisper"
            designDialect = "Auto"

        default:
            designPreset = "Custom"
        }
    }

    func analyzeReference() {
        guard let ref = referenceURL else {
            errorMessage = "Choose a reference voice first."
            return
        }

        guard let identity = referenceIdentity, referenceMatches(identity) else {
            errorMessage = "Reference audio changed or is unavailable. Select it again before analysis."; return
        }
        let binding = ReferenceAnalysisBinding(identity: identity, transcript: referenceText, requestID: UUID())
        analysisBinding = binding
        referenceAnalyzing = true
        referenceAnalysisReady = false
        referenceAnalysisStatus = "Analyzing voice…"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/analyze-reference")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        field("ref_text", referenceText)

        if let audio = try? Data(contentsOf: ref) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ref_audio\"; filename=\"\(ref.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(audio)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard self?.analysisIsCurrent(binding) == true else { return }
                self?.referenceAnalyzing = false

                if let error {
                    self?.referenceAnalysisStatus = "Analysis failed"
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self?.referenceAnalysisStatus = "Analysis failed"
                    self?.errorMessage = "Could not read analyzer response."
                    return
                }

                if let message = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.referenceAnalysisStatus = "Analysis failed"
                    self?.errorMessage = message
                    return
                }

                self?.referenceDuration = json["duration"] as? Double ?? 0
                self?.referencePitch = json["pitch_hz"] as? Double ?? 0
                self?.referencePitchRange = json["pitch_range_hz"] as? Double ?? 0
                self?.referenceRMS = json["rms_db"] as? Double ?? -60
                self?.referencePeak = json["peak_db"] as? Double ?? -60
                self?.referenceSpeechRatio = json["speech_ratio"] as? Double ?? 0
                self?.referencePauseRatio = json["pause_ratio"] as? Double ?? 0
                self?.referenceWPM = json["wpm"] as? Double ?? 0
                self?.referenceQualityScore = json["quality_score"] as? Int ?? 0
                self?.referenceQualityLabel = json["quality_label"] as? String ?? "Unknown"
                self?.referencePaceLabel = json["pace_label"] as? String ?? "Unknown"

                if let rec = json["recommended"] as? [String: Any] {
                    self?.recommendedSpeed = rec["speed"] as? Double ?? 1.0
                    self?.recommendedSteps = rec["steps"] as? Double ?? 32
                    self?.recommendedGuidance = rec["guidance"] as? Double ?? 2.0
                    self?.recommendedDenoise = rec["denoise"] as? Bool ?? true
                }

                self?.referenceAnalysisReady = true
                self?.referenceAnalysisStatus = "Analysis complete"
            }
        }.resume()
    }

    func applyReferenceRecommendations() {
        guard referenceAnalysisReady, let binding = analysisBinding, analysisIsCurrent(binding) else {
            invalidateReferenceAnalysis(); return
        }
        speed = recommendedSpeed
        steps = recommendedSteps
        guidance = recommendedGuidance
        denoiseOutput = recommendedDenoise
        preset = "Auto Tuned"
        referenceAnalysisStatus = "Recommended settings applied"
    }

    func generateClone() {
        guard let ref = referenceURL else { return }
        multipartGenerate(
            endpoint: "generate-clone",
            text: cloneText,
            extraFields: ["ref_text": referenceText, "pronunciations": clonePronunciationRules, "language": cloneLanguage],
            audioURL: ref,
            mode: "Voice Clone"
        )
    }

    func generateDesign() {
        var attrs: [String] = []

        if designMode == "Design" {
            if designGender != "Auto" { attrs.append(designGender) }
            if designAge != "Auto" { attrs.append(designAge) }
            if designPitch != "Auto" { attrs.append(designPitch) }
            if designStyle != "Auto" { attrs.append(designStyle) }
            if designAccent != "Auto" { attrs.append(designAccent) }
            if designDialect != "Auto" { attrs.append(designDialect) }
        }

        multipartGenerate(
            endpoint: "generate-design",
            text: designText,
            extraFields: ["instruct": attrs.joined(separator: ", "), "pronunciations": designPronunciationRules],
            audioURL: nil,
            mode: designMode == "Auto" ? "Auto Voice" : "Voice Design"
        )
    }

    private func multipartGenerate(endpoint: String, text: String, extraFields: [String:String], audioURL: URL?, mode: String) {
        guard modelReady, !isGenerating, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        errorMessage = nil
        isGenerating = true
        status = "Generating…"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/\(endpoint)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        guard let fields = generationFields(text: text,
            pronunciations: extraFields["pronunciations"] ?? "",
            language: extraFields["language"] ?? "Auto detect",
            instruct: extraFields["instruct"] ?? "",
            matchInsideWords: endpoint == "generate-design" ? designMatchInsideWords : cloneMatchInsideWords,
            checkReference: audioURL != nil) else { isGenerating = false; return }
        for (name, value) in fields { appendField(name, value) }

        if let audioURL, let data = try? Data(contentsOf: audioURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ref_audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isGenerating = false

                if let error {
                    self?.status = "Generation failed"
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard let data else {
                    self?.status = "Generation failed"
                    self?.errorMessage = "No response from VoxAster."
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = (json["error"] as? String ?? json["detail"] as? String) {
                        self?.errorMessage = message
                    } else {
                        self?.errorMessage = "VoxAster returned HTTP \(http.statusCode)."
                    }
                    self?.status = "Generation failed"
                    return
                }

                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let path = json["output"] as? String
                else {
                    self?.status = "Generation failed"
                    self?.errorMessage = "VoxAster returned an unreadable response."
                    return
                }

                let url = URL(fileURLWithPath: path)
                self?.outputURL = url
                self?.status = "Done"

                let item = Generation(text: text, path: path, createdAt: Date(), mode: mode)
                self?.generations.insert(item, at: 0)
                self?.registerGenerationWithActiveProject(item.id)
                self?.saveHistory()

                if self?.autoPlay == true {
                    self?.outputPlayer.toggle(url)
                }
            }
        }.resume()
    }

    func exportOutput(_ url: URL?) {
        guard let url else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destination = panel.url {
            exportAudio(url, to: destination)
        }
    }

    func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteGeneration(_ item: Generation) {
        if keepOutputs == false {
            try? FileManager.default.removeItem(at: item.url)
        }
        generations.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearHistory() {
        generations.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(generations) {
            try? data.write(to: historyFile, options: .atomic)
        }
    }

    private func saveVoices() {
        if let data = try? JSONEncoder().encode(savedVoices) {
            try? data.write(to: voicesFile, options: .atomic)
        }
    }

    private func loadPersistentData() {
        if let data = try? Data(contentsOf: historyFile),
           let decoded = try? JSONDecoder().decode([Generation].self, from: data) {
            generations = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        if let data = try? Data(contentsOf: voicesFile),
           let decoded = try? JSONDecoder().decode([SavedVoice].self, from: data) {
            savedVoices = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        if FileManager.default.fileExists(atPath: projectsFile.path) {
            do {
                let decoded = try JSONDecoder().decode([VoiceProject].self, from: Data(contentsOf: projectsFile))
                projects = decoded.sorted { $0.updatedAt > $1.updatedAt }
            } catch {
                projectLoadFailed = true
                errorMessage = "Project recovery failed: \(error.localizedDescription). Existing projects.json was preserved."
            }
        }
    }
}
