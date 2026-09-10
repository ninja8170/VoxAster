import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum OVTheme {
    static let bgTop = Color(red: 0.025, green: 0.040, blue: 0.066)
    static let bgBottom = Color(red: 0.010, green: 0.017, blue: 0.030)

    static let panel = Color.white.opacity(0.045)
    static let panelRaised = Color.white.opacity(0.070)
    static let controlSurface = Color.white.opacity(0.050)
    static let border = Color.white.opacity(0.085)

    static let accent = Color(red: 0.28, green: 0.54, blue: 1.0)
    static let accent2 = Color(red: 0.48, green: 0.36, blue: 1.0)

    static let radius: CGFloat = 16
    static let nestedRadius: CGFloat = 11
    static let workspaceMax: CGFloat = 1280
    static let inspectorWidth: CGFloat = 300
}

struct StatusPill: View {
    let text: String
    let ready: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.055))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
    }
}

#if !PHASE1_TESTS
@main
struct OmniVoiceNativeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 920)
    }
}

#endif

enum AppSection: String, CaseIterable {
    case clone = "Voice Clone"
    case design = "Voice Design"
    case library = "Library"
    case history = "History"
    case longForm = "Long Form"
    case projects = "Projects"
    case engineLab = "Engine Lab"
    case personalVoice = "Voice Training"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .clone: return "mic.fill"
        case .design: return "slider.horizontal.3"
        case .library: return "folder"
        case .history: return "clock"
        case .longForm: return "text.document"
        case .projects: return "square.grid.2x2"
        case .engineLab: return "testtube.2"
        case .personalVoice: return "person.wave.2"
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
            .appendingPathComponent("omnivoice-recording-\(UUID().uuidString).wav")

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
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .clone

    @Published var referenceURL: URL?
    @Published var referenceText = ""
    @Published var cloneText = "The future sounds better together."
    @Published var cloneLanguage = "Auto detect"
    @Published var clonePronunciationRules = ""
    @Published var designMode = "Design"
    @Published var designDialect = "Auto"
    @Published var designPreset = "Custom"

    @Published var designText = "Create a voice that sounds natural, confident and warm."
    @Published var designGender = "Auto"
    @Published var designAge = "Auto"
    @Published var designPitch = "Auto"
    @Published var designAccent = "Auto"
    @Published var designStyle = "Auto"

    @Published var speed = 1.0
    @Published var steps = 32.0
    @Published var guidance = 2.0
    @Published var runtimeProvenance: [String: String] = [:]
    @Published var generationSeed = 0
    @Published var denoiseOutput = true
    @Published var useDuration = false
    @Published var targetDuration = 10.0
    @Published var timeShift = 0.1
    @Published var positionTemperature = 5.0
    @Published var classTemperature = 0.0
    @Published var layerPenaltyFactor = 5.0
    @Published var cloneMatchInsideWords = false
    @Published var longFormMatchInsideWords = false
    @Published var designPronunciationRules = ""
    @Published var designMatchInsideWords = false
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
    @Published var engineLabText = "Artificial intelligence is changing the way we create, communicate, and understand the world."
    @Published var engineLabRunning = false
    @Published var engineLabStatus = "Ready"
    @Published var engineLabA: URL?
    @Published var engineLabB: URL?
    @Published var engineLabMap: [String: String] = [:]
    @Published var engineLabRevealed = false
    @Published var engineLabWinner: String?
    @Published var engineLabAvailableEngines: [String] = ["OmniVoice Zero-Shot"]
    @Published var engineLabEngineA = "OmniVoice Zero-Shot"
    @Published var engineLabEngineB = "F5-TTS"
    @Published var f5Available = false

    // Personal Voice Lab
    @Published var personalDatasetFolder: URL?
    @Published var personalLanguage = "en"
    @Published var personalAutoTranscribe = false
    @Published var personalPreparing = false
    @Published var personalTraining = false
    @Published var personalStatus = "No dataset prepared"
    @Published var personalGoodClips = 0
    @Published var personalRejectedClips = 0
    @Published var personalMinutes = 0.0
    @Published var personalAdapterPath = ""
    @Published var personalTrainingLog = ""
    @Published var personalTrainingPhase = "Idle"
    @Published var personalTrainingStep = 0
    @Published var personalTrainingTotal = 1000
    @Published var personalModelReady = false
    @Published var personalModelPath = ""
    @Published var personalMerging = false
    @Published var personalMergeStatus = ""
    @Published var trainedVoiceName = ""
    @Published var savingTrainedVoice = false
    @Published var savedTrainedVoiceName = ""
    @Published var trainedEngines: [String] = []

    @Published var personalRejectionDetails: [String] = []
    @Published var preset = "Natural"
    private var synchronizingProduction = false
    @Published var longFormText = "" {
        didSet {
            if !synchronizingProduction && oldValue != longFormText {
                productionChunks = []
                longFormOutputURL = nil
            }
        }
    }
    @Published var longFormProgress: Double = 0
    @Published var longFormStatus = "Ready"
    @Published var longFormOutputURL: URL?
    @Published var pronunciationRules = ""
    @Published var projectName = "My Voice Project"
    @Published var projects: [VoiceProject] = []
    @Published var currentProjectID: UUID?
    @Published var projectStatus = "Unsaved project"
    @Published var activeProjectGenerationIDs: [UUID] = []
    @Published var variantCount = 2
    @Published var variantURLs: [URL] = []
    @Published var productionChunks: [ProductionChunk] = []
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
    private let session: URLSession

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
    }

    init(startServices: Bool = true, storageRoot: URL? = nil, session: URLSession = .shared) {
        self.session = session
        storageOverride = storageRoot
        guard startServices else { return }
        createDirectories()
        loadPersistentData()
        startBackend()
        pollHealth()
    }

    deinit {
        if let p = backend, p.isRunning { p.terminate() }
    }

    private var documentsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OmniVoice-Mac", isDirectory: true)
    }

    private var outputsDir: URL { documentsRoot.appendingPathComponent("outputs", isDirectory: true) }
    private var voicesDir: URL { documentsRoot.appendingPathComponent("voices", isDirectory: true) }

    private var appSupport: URL {
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

    func startBackend() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let python = "\(home)/Documents/OmniVoice-Mac/.venv/bin/python"

        guard let resources = Bundle.main.resourcePath else {
            status = "App resources unavailable"
            return
        }
        let server = "\(resources)/backend.py"

        guard fm.fileExists(atPath: python), fm.fileExists(atPath: server) else {
            status = "Backend files not found"
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [server]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"

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
        env["PATH"] = mergedPath.joined(separator: ":")

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
                          json["generation_contract"] as? Int == 2,
                          let provenance = json["provenance"] as? [String: String] else {
                        self?.modelReady = false
                        self?.status = "Incompatible backend"
                        self?.errorMessage = "Close the older OmniVoice app/backend before using this build."
                        return
                    }
                    self?.runtimeProvenance = provenance
                    self?.modelReady = true
                    self?.status = "Model Ready"
                    self?.checkEngineLab()
                    self?.pollPersonalTraining()
                    self?.checkPersonalModel()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
                self?.personalModelReady = (json["personal_available"] as? Bool) ?? self?.personalModelReady ?? false
                self?.personalModelPath = json["personal_path"] as? String ?? self?.personalModelPath ?? ""

                if let engines = json["engines"] as? [String], !engines.isEmpty {
                    self?.engineLabAvailableEngines = engines

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



    func checkPersonalModel() {
        guard let url = URL(string: "http://127.0.0.1:8011/personal/model-status") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                self?.personalModelReady = json["ready"] as? Bool ?? false
                self?.personalModelPath = json["path"] as? String ?? ""
                if let saved = json["saved_engines"] as? [[String: Any]] {
                    let names = saved.compactMap { $0["name"] as? String }
                    self?.trainedEngines = names
                    if let last = names.last {
                        self?.savedTrainedVoiceName = last
                    }
                }
            }
        }.resume()
    }

    func preparePersonalModel() {
        personalMerging = true
        personalMergeStatus = "Preparing trained voice model…"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/personal/merge")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1800

        session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.personalMerging = false
                if let error {
                    self?.personalMergeStatus = "Merge failed"
                    self?.errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                if let e = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.personalMergeStatus = "Merge failed"
                    self?.errorMessage = e
                    return
                }
                self?.personalModelReady = true
                self?.personalModelPath = json["merged_model"] as? String ?? ""
                self?.personalMergeStatus = "Personal Voice ready"
            }
        }.resume()
    }

    func saveTrainedVoice() {
        let name = trainedVoiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Enter a name for this trained voice."
            return
        }

        savingTrainedVoice = true
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/personal/save-engine")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1800
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])

        session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.savingTrainedVoice = false

                if let error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self?.errorMessage = "Could not read the saved-engine response."
                    return
                }

                if let e = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.errorMessage = e
                    return
                }

                let savedName = json["name"] as? String ?? name
                self?.savedTrainedVoiceName = savedName
                self?.personalModelReady = true
                self?.personalModelPath = json["path"] as? String ?? ""
                self?.personalMergeStatus = "Saved as \(savedName)"
                self?.checkEngineLab()
            }
        }.resume()
    }

    func choosePersonalDatasetFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            personalDatasetFolder = panel.url
        }
    }

    func preparePersonalDataset() {
        guard let folder = personalDatasetFolder else { return }
        personalPreparing = true
        personalStatus = "Preparing dataset…"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/personal/prepare")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "folder": folder.path,
            "language_id": personalLanguage,
            "auto_transcribe": personalAutoTranscribe
        ])

        session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.personalPreparing = false
                if let error {
                    self?.personalStatus = "Preparation failed"
                    self?.errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self?.errorMessage = "Unreadable Personal Voice response."
                    return
                }
                if let e = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.personalStatus = "Preparation failed"
                    self?.personalRejectionDetails = json["rejection_details"] as? [String] ?? []
                    self?.personalGoodClips = json["accepted"] as? Int ?? 0
                    self?.personalRejectedClips = json["rejected"] as? Int ?? 0
                    self?.personalMinutes = json["minutes"] as? Double ?? 0
                    self?.errorMessage = e
                    return
                }
                self?.personalGoodClips = json["accepted"] as? Int ?? 0
                self?.personalRejectedClips = json["rejected"] as? Int ?? 0
                self?.personalMinutes = json["minutes"] as? Double ?? 0
                self?.personalRejectionDetails = json["rejection_details"] as? [String] ?? []
                self?.personalStatus = "Dataset ready"
            }
        }.resume()
    }

    func startPersonalTraining() {
        personalTraining = true
        personalStatus = "Starting training…"
        personalTrainingPhase = "Launching"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8011/personal/train")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        session.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.personalTraining = false
                    self?.errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self?.personalTraining = false
                    return
                }
                if let e = (json["error"] as? String ?? json["detail"] as? String) {
                    self?.personalTraining = false
                    self?.personalStatus = "Training could not start"
                    self?.errorMessage = e
                    return
                }
                self?.personalStatus = "Training running in background"
                self?.pollPersonalTraining()
            }
        }.resume()
    }

    func pollPersonalTraining() {
        guard let url = URL(string: "http://127.0.0.1:8011/personal/training-status") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }

                self?.personalTraining = json["running"] as? Bool ?? false
                self?.personalTrainingLog = json["tail"] as? String ?? ""
                self?.personalAdapterPath = json["adapter_path"] as? String ?? ""
                self?.personalTrainingPhase = json["phase"] as? String ?? "Training"
                self?.personalTrainingStep = json["step"] as? Int ?? 0
                self?.personalTrainingTotal = json["total_steps"] as? Int ?? 1000
                if let accepted = json["accepted"] as? Int, accepted > 0 {
                    self?.personalGoodClips = accepted
                    self?.personalRejectedClips = json["rejected"] as? Int ?? 0
                    self?.personalMinutes = json["minutes"] as? Double ?? self?.personalMinutes ?? 0
                }

                if self?.personalTraining == true {
                    self?.personalStatus = "Training in progress"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.pollPersonalTraining()
                    }
                } else {
                    let code = json["exit_code"] as? Int
                    if code == 0 {
                        self?.personalStatus = "Training complete"
                        self?.personalTrainingPhase = "Complete"
                    } else if code != nil {
                        self?.personalStatus = "Training failed"
                        self?.personalTrainingPhase = "Failed"
                    }
                }
            }
        }.resume()
    }

    func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            referenceURL = panel.url
            referencePlayer.stop()
        }
    }

    func acceptDroppedAudio(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }

                guard let resolved = url else { return }
                DispatchQueue.main.async {
                    self?.referenceURL = resolved
                    self?.referencePlayer.stop()
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
                self.referencePlayer.stop()
                self.referenceURL = url
                self.referenceText = ""
            } else if self.recorder.permissionDenied {
                self.errorMessage = "Microphone access is disabled. Enable OmniVoice in System Settings → Privacy & Security → Microphone."
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
            let saved = SavedVoice(
                name: trimmed,
                path: destination.path,
                transcript: referenceText,
                createdAt: Date()
            )
            savedVoices.insert(saved, at: 0)
            saveVoices()
        } catch {
            errorMessage = "Could not save voice: \(error.localizedDescription)"
        }
    }

    func selectEngineLabVoice(_ voice: SavedVoice) {
        referenceURL = voice.url
        referenceText = voice.transcript
        referencePlayer.stop()
    }

    func useVoice(_ voice: SavedVoice) {
        referenceURL = voice.url
        referenceText = voice.transcript
        selectedSection = .clone
    }

    func deleteVoice(_ voice: SavedVoice) {
        try? FileManager.default.removeItem(at: voice.url)
        savedVoices.removeAll { $0.id == voice.id }
        saveVoices()
    }

    private func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: projectsFile, options: .atomic)
        }
    }

    func newProject() {
        outputPlayer.stop()
        currentProjectID = nil
        activeProjectGenerationIDs = []
        projectName = "Untitled Project"
        pronunciationRules = ""
        referenceURL = nil
        referenceText = ""
        projectStatus = "New project — not saved"
    }

    func saveCurrentProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Enter a project name before saving."
            return
        }
        let now = Date()
        if let id = currentProjectID, let i = projects.firstIndex(where: {$0.id == id}) {
            projects[i].name = name
            projects[i].referencePath = referenceURL?.path
            projects[i].referenceText = referenceText
            projects[i].pronunciationRules = pronunciationRules
            projects[i].generationIDs = activeProjectGenerationIDs
            projects[i].updatedAt = now
        } else {
            let p = VoiceProject(
                name: name,
                referencePath: referenceURL?.path,
                referenceText: referenceText,
                pronunciationRules: pronunciationRules,
                generationIDs: activeProjectGenerationIDs,
                createdAt: now,
                updatedAt: now
            )
            projects.insert(p, at: 0)
            currentProjectID = p.id
            activeProjectGenerationIDs = p.generationIDs
        }
        projects.sort {$0.updatedAt > $1.updatedAt}
        saveProjects()
        projectStatus = "Saved"
    }

    func openProject(_ p: VoiceProject) {
        currentProjectID = p.id
        activeProjectGenerationIDs = p.generationIDs
        projectName = p.name
        pronunciationRules = p.pronunciationRules
        referenceText = p.referenceText
        if let path = p.referencePath, FileManager.default.fileExists(atPath: path) {
            referenceURL = URL(fileURLWithPath: path)
        } else {
            referenceURL = nil
        }
        projectStatus = "Opened"
    }

    func deleteProject(_ p: VoiceProject) {
        projects.removeAll {$0.id == p.id}
        if currentProjectID == p.id {
            currentProjectID = nil
            activeProjectGenerationIDs = []
            projectStatus = "Unsaved project"
        }
        saveProjects()
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
            saveProjects()
        }
    }

    func generationFields(text: String, pronunciations: String = "", language: String = "Auto detect",
                          instruct: String = "", segments: [String]? = nil,
                          retryIndex: Int? = nil, matchInsideWords: Bool = false,
                          nativeAdvanced: Bool = true, allowDuration: Bool = true) -> [String: String]? {
        do {
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
                    self.errorMessage = "Unreadable response from OmniVoice."
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

    func inspectSpeech(text: String, rules: String, matchMode: String) async throws -> SpeechInspection {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string:"http://127.0.0.1:8011/preview-speech")!)
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
        guard referenceAnalysisReady else { return }
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
        guard modelReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
            matchInsideWords: endpoint == "generate-design" ? designMatchInsideWords : cloneMatchInsideWords) else { isGenerating = false; return }
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
                    self?.errorMessage = "No response from OmniVoice."
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = (json["error"] as? String ?? json["detail"] as? String) {
                        self?.errorMessage = message
                    } else {
                        self?.errorMessage = "OmniVoice returned HTTP \(http.statusCode)."
                    }
                    self?.status = "Generation failed"
                    return
                }

                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let path = json["output"] as? String
                else {
                    self?.status = "Generation failed"
                    self?.errorMessage = "OmniVoice returned an unreadable response."
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
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
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

        if let data = try? Data(contentsOf: projectsFile),
           let decoded = try? JSONDecoder().decode([VoiceProject].self, from: data) {
            projects = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 250)
            Divider().opacity(0.25)

            Group {
                switch model.selectedSection {
                case .clone: CloneWorkspace()
                case .design: VoiceDesignWorkspace()
                case .library: LibraryWorkspace()
                case .history: HistoryWorkspace()
                case .longForm: LongFormWorkspace()
                case .projects: ProjectsWorkspace()
                case .engineLab: EngineLabWorkspace()
                case .personalVoice: PersonalVoiceWorkspace()
                case .settings: SettingsWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LinearGradient(
                colors: [
                    OVTheme.bgTop,
                    OVTheme.bgBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .alert("OmniVoice", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering: AppSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                        .shadow(color: OVTheme.accent.opacity(0.28), radius: 14, y: 5)
                    Image(systemName: "waveform.path").font(.system(size: 21, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("OmniVoice").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("VOICE STUDIO").font(.system(size: 9, weight: .semibold)).tracking(2.2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 18)

            Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(1.7)
                .foregroundStyle(.tertiary).padding(.horizontal, 22).padding(.bottom, 3)

            ForEach(AppSection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.selectedSection = section }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: section.icon).font(.system(size: 15, weight: .medium)).frame(width: 22)
                        Text(section.rawValue).font(.system(size: 14.5, weight: model.selectedSection == section ? .semibold : .medium))
                        Spacer()
                        if model.selectedSection == section { Circle().fill(OVTheme.accent).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(model.selectedSection == section ? .white : Color.white.opacity(0.72))
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 11).fill(model.selectedSection == section ? OVTheme.accent.opacity(0.17) : (hovering == section ? Color.white.opacity(0.045) : .clear)))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(model.selectedSection == section ? OVTheme.accent.opacity(0.22) : .clear))
                }
                .buttonStyle(.plain).padding(.horizontal, 11)
                .onHover { inside in hovering = inside ? section : nil }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Apple Silicon", systemImage: "cpu").font(.caption.weight(.medium))
                    Spacer()
                    StatusPill(text: model.modelReady ? "Ready" : "Loading", ready: model.modelReady)
                }
                Text("Local inference • MPS accelerated").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14).background(.ultraThinMaterial.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 14)).padding(14)
        }
        .background(Color.black.opacity(0.20))
    }
}

struct WorkspaceHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold)).tracking(2.4).foregroundStyle(OVTheme.accent)
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .leading, endPoint: .trailing))
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .background(LinearGradient(colors: [OVTheme.accent.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .bottom) { Divider().opacity(0.18) }
    }
}

struct CloneWorkspace: View {
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Speech without boundaries",
                title: "Clone. Create. Speak Freely.",
                subtitle: "600+ languages. Your voice. Infinite possibilities."
            )

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        ReferenceCard()
                        CloneTextCard()
                        VariantStudioCard()
                        OutputCard()
                    }.padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                ScrollView {
                    VStack(spacing: 14) {
                        ReferenceAnalysisCard()
                        GenerationSettingsCard(mode: .clone)
                        RecentCard()
                    }
                }
                .frame(width: 320)
            }
            .padding(18)
        }
    }
}

struct ReferenceCard: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTarget = false
    @State private var showSaveVoice = false
    @State private var voiceName = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(
                    number: 1,
                    title: "Reference Voice",
                    subtitle: "Drop in a clip, browse for a file, or record directly from your Mac."
                )

                HStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Button(action: model.chooseReference) {
                            VStack(spacing: 9) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 30))
                                Text(model.referenceURL == nil ? "Drop audio here" : "Replace audio")
                                    .font(.headline)
                                Text("or click to browse")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("WAV, MP3, M4A • 3–10 seconds")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 122)
                            .background(isDropTarget ? Color.blue.opacity(0.14) : Color.white.opacity(0.02))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        isDropTarget ? Color.blue : Color.white.opacity(0.3),
                                        style: StrokeStyle(lineWidth: 1, dash: [5])
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) {
                            model.acceptDroppedAudio($0)
                        }

                        RecordingButton(
                            recorder: model.recorder,
                            action: model.startRecording
                        )
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 11) {
                        if let u = model.referenceURL {
                            AudioWaveform(url: u, barCount: 64)
                                .frame(height: 62)

                            Text(u.lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            CompactPlayer(url: u, controller: model.referencePlayer)

                            TextField("Reference transcript (optional)", text: $model.referenceText)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button {
                                    voiceName = u.deletingPathExtension().lastPathComponent
                                    showSaveVoice = true
                                } label: {
                                    Label("Save Voice", systemImage: "person.crop.circle.badge.plus")
                                }
                                Spacer()
                                Text("Reference ready")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                        } else {
                            Spacer()
                            Image(systemName: "waveform")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            Text("Your reference waveform will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 185)
                    .background(Color.black.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .sheet(isPresented: $showSaveVoice) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Save Voice").font(.title2.bold())
                Text("Give this reference voice a name so you can reuse it later.")
                    .foregroundStyle(.secondary)
                TextField("Voice name", text: $voiceName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") { showSaveVoice = false }
                    Button("Save") {
                        model.saveCurrentVoice(named: voiceName)
                        showSaveVoice = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
    }

}

struct RecordingButton: View {
    @ObservedObject var recorder: RecorderController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                Text(recorder.isRecording ? "Stop Recording" : "Record on Mac")
                Spacer()
                if recorder.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text(timeString(recorder.elapsed))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(recorder.isRecording ? Color.red.opacity(0.16) : Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded(.down)) % 10
        return String(format: "%02d:%02d.%d", Int(seconds) / 60, Int(seconds) % 60, tenths)
    }
}

struct CloneTextCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                StepHeader(number: 2, title: "Text to Speak", subtitle: "Clone across languages, add expression, and control pronunciation.")

                HStack {
                    Label("Output language", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.cloneLanguage) {
                        ForEach([
                            "Auto detect", "English", "French", "Spanish", "German",
                            "Italian", "Portuguese", "Dutch", "Polish", "Russian",
                            "Arabic", "Hindi", "Japanese", "Korean", "Chinese"
                        ], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 220)
                }

                Text("Auto detect leaves language unspecified. A selected language is forwarded to OmniVoice.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                SpeechEditor(text:$model.cloneText, rules:model.clonePronunciationRules,
                             matchMode:model.cloneMatchInsideWords ? "substring" : "words")
                PronunciationRulesEditor(rules:$model.clonePronunciationRules, matchInsideWords:$model.cloneMatchInsideWords)

                HStack {
                    Button("Clear") { model.cloneText = "" }
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            model.cloneText = s
                        }
                    }
                    Spacer()
                    Text("\(model.cloneText.count) / 5000")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OutputCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                StepHeader(
                    number: 3,
                    title: "Generated Audio",
                    subtitle: model.outputURL == nil ? "Your generated voice will appear here." : "Your audio is ready."
                )

                if let u = model.outputURL {
                    AudioWaveform(url: u, barCount: 90)
                        .frame(height: 58)

                    FullPlayer(url: u, controller: model.outputPlayer)

                    HStack {
                        Button {
                            model.exportOutput(u)
                        } label: {
                            Label("Export WAV", systemImage: "square.and.arrow.down")
                        }

                        ShareLink(item: u) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }

                        Spacer()

                        Button {
                            model.reveal(u)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Generate speech to create an audio file.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                }
            }
        }
    }
}

struct VoiceDesignWorkspace: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Design a voice",
                title: "Create a Voice From Scratch.",
                subtitle: "Shape gender, age, pitch, accent and delivery — no reference clip required."
            )

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 20) {
                                StepHeader(
                                    number: 1,
                                    title: "Voice Character",
                                    subtitle: "Start with a preset or shape the voice yourself."
                                )

                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Generation Mode")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        Picker("Mode", selection: $model.designMode) {
                                            Label("Design", systemImage: "slider.horizontal.3").tag("Design")
                                            Label("Auto Voice", systemImage: "sparkles").tag("Auto")
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 310)
                                    }

                                    Spacer()

                                    if model.designPreset != "Custom" {
                                        HStack(spacing: 7) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(OVTheme.accent)
                                            Text(model.designPreset)
                                                .font(.caption.weight(.semibold))
                                            Text("preset")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 7)
                                        .background(OVTheme.accent.opacity(0.09))
                                        .clipShape(Capsule())
                                    }
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Creator Presets")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    LazyVGrid(
                                        columns: [
                                            GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 10)
                                        ],
                                        alignment: .leading,
                                        spacing: 10
                                    ) {
                                        CreatorPresetCard(
                                            title: "Audiobook",
                                            subtitle: "Warm • measured",
                                            icon: "book.closed.fill",
                                            selected: model.designPreset == "Audiobook"
                                        ) { model.applyDesignPreset("Audiobook") }

                                        CreatorPresetCard(
                                            title: "News Anchor",
                                            subtitle: "Clear • authoritative",
                                            icon: "newspaper.fill",
                                            selected: model.designPreset == "News Anchor"
                                        ) { model.applyDesignPreset("News Anchor") }

                                        CreatorPresetCard(
                                            title: "NPC",
                                            subtitle: "Automatic character",
                                            icon: "gamecontroller.fill",
                                            selected: model.designPreset == "NPC"
                                        ) { model.applyDesignPreset("NPC") }

                                        CreatorPresetCard(
                                            title: "Podcast",
                                            subtitle: "Relaxed • conversational",
                                            icon: "mic.fill",
                                            selected: model.designPreset == "Podcast"
                                        ) { model.applyDesignPreset("Podcast") }

                                        CreatorPresetCard(
                                            title: "Language Tutor",
                                            subtitle: "Clear • balanced",
                                            icon: "character.book.closed.fill",
                                            selected: model.designPreset == "Language Tutor"
                                        ) { model.applyDesignPreset("Language Tutor") }

                                        CreatorPresetCard(
                                            title: "Customer Support",
                                            subtitle: "Friendly • neutral",
                                            icon: "headphones",
                                            selected: model.designPreset == "Customer Support"
                                        ) { model.applyDesignPreset("Customer Support") }

                                        CreatorPresetCard(
                                            title: "Whisper",
                                            subtitle: "Soft • intimate",
                                            icon: "waveform",
                                            selected: model.designPreset == "Whisper"
                                        ) { model.applyDesignPreset("Whisper") }
                                    }
                                }

                                Divider().opacity(0.22)

                                if model.designMode == "Design" {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Text("Voice Profile")
                                                .font(.headline)
                                            Spacer()
                                            Text("Fine tune the selected preset")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        LazyVGrid(
                                            columns: [
                                                GridItem(.flexible(), spacing: 12),
                                                GridItem(.flexible(), spacing: 12),
                                                GridItem(.flexible(), spacing: 12)
                                            ],
                                            spacing: 12
                                        ) {
                                            DesignControlTile(
                                                title: "Gender",
                                                icon: "person.2.fill",
                                                selection: $model.designGender,
                                                options: ["Auto","male","female"]
                                            )

                                            DesignControlTile(
                                                title: "Age",
                                                icon: "calendar",
                                                selection: $model.designAge,
                                                options: ["Auto","child","teenager","young adult","middle-aged","elderly"]
                                            )

                                            DesignControlTile(
                                                title: "Pitch",
                                                icon: "waveform.path",
                                                selection: $model.designPitch,
                                                options: ["Auto","very low pitch","low pitch","moderate pitch","high pitch","very high pitch"]
                                            )

                                            DesignControlTile(
                                                title: "Delivery",
                                                icon: "quote.bubble.fill",
                                                selection: $model.designStyle,
                                                options: ["Auto","whisper"]
                                            )

                                            DesignControlTile(
                                                title: "English Accent",
                                                icon: "globe.europe.africa.fill",
                                                selection: $model.designAccent,
                                                options: ["Auto","American accent","British accent","Australian accent","Canadian accent","Indian accent","Chinese accent","Japanese accent","Korean accent","Portuguese accent","Russian accent"]
                                            )

                                            if model.designAccent == "Chinese accent" {
                                                DesignControlTile(
                                                    title: "Chinese Dialect",
                                                    icon: "character.bubble.fill",
                                                    selection: $model.designDialect,
                                                    options: ["Auto","河南话","陕西话","四川话","贵州话","云南话","桂林话","济南话","石家庄话","甘肃话","宁夏话","青岛话","东北话"]
                                                )
                                            }
                                        }
                                    }
                                } else {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(OVTheme.accent.opacity(0.12))
                                                .frame(width: 48, height: 48)
                                            Image(systemName: "sparkles")
                                                .font(.title3)
                                                .foregroundStyle(OVTheme.accent)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Auto Voice")
                                                .font(.headline)
                                            Text("OmniVoice will invent a fitting speaker automatically. No character controls are required.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                    }
                                    .padding(14)
                                    .background(OVTheme.controlSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: OVTheme.nestedRadius))
                                }
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                StepHeader(number: 2, title: "Text to Speak", subtitle: "Enter what the designed voice should say.")

                                SpeechEditor(text:$model.designText, rules:model.designPronunciationRules,
                                    matchMode:model.designMatchInsideWords ? "substring" : "words", minimumHeight:150)
                                PronunciationRulesEditor(rules:$model.designPronunciationRules, matchInsideWords:$model.designMatchInsideWords)
                            }
                        }

                        OutputCard()
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                ScrollView {
                    VStack(spacing: 14) {
                        GenerationSettingsCard(mode: .design)
                        RecentCard()
                    }
                }
                .frame(width: 300)
            }
            .padding(18)
        }
    }
}

struct LibraryWorkspace: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = "Voices"

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Local collection",
                title: "Library",
                subtitle: "Saved voices and generated audio, stored locally on this Mac."
            )

            VStack(spacing: 16) {
                Picker("", selection: $tab) {
                    Text("Reference Voices (\(model.savedVoices.count))").tag("Voices")
                    Text("Trained Voices (\(model.trainedEngines.count))").tag("Trained")
                    Text("Generated Audio (\(model.generations.count))").tag("Audio")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                if tab == "Voices" {
                    SavedVoiceGrid()
                } else if tab == "Trained" {
                    TrainedVoiceGrid()
                } else {
                    GenerationGrid(items: model.generations)
                }
            }
            .padding(20)
        }
    }
}


struct TrainedVoiceGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            if model.trainedEngines.isEmpty {
                ContentUnavailableView(
                    "No Trained Voices",
                    systemImage: "brain.head.profile",
                    description: Text("Complete Voice Training and save a named voice to add it here.")
                )
                .padding(.top, 70)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(model.trainedEngines, id: \.self) { name in
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 11)
                                            .fill(Color.green.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "brain.head.profile")
                                            .foregroundStyle(.green)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(name).font(.headline)
                                        Text("Trained OmniVoice")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("READY")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }

                                Divider().opacity(0.2)

                                HStack {
                                    Button("Engine Lab") {
                                        model.engineLabEngineB = name
                                        model.selectedSection = .engineLab
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Spacer()

                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

struct SavedVoiceGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            if model.savedVoices.isEmpty {
                ContentUnavailableView(
                    "No Saved Voices",
                    systemImage: "person.wave.2",
                    description: Text("Save a reference voice from Voice Clone and it will appear here.")
                )
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(model.savedVoices) { voice in
                        Card {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    ZStack {
                                        Circle().fill(Color.blue.opacity(0.18)).frame(width: 42, height: 42)
                                        Image(systemName: "person.wave.2.fill").foregroundStyle(.blue)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(voice.name).font(.headline)
                                        Text(voice.createdAt, style: .date)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }

                                AudioWaveform(url: voice.url, barCount: 50).frame(height: 42)
                                CompactPlayer(url: voice.url, controller: model.referencePlayer)

                                if !voice.transcript.isEmpty {
                                    Text(voice.transcript)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                HStack {
                                    Button("Use Voice") { model.useVoice(voice) }
                                    Spacer()
                                    Button(role: .destructive) { model.deleteVoice(voice) } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct HistoryWorkspace: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = "All"
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Generation activity",
                title: "History",
                subtitle: "Every successful generation saved by the native app."
            )

            HStack(spacing: 10) {
                Picker("Filter", selection: $filter) {
                    ForEach(["All", "Voice Clone", "Voice Design", "Long Form"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                Spacer()

                TextField("Search history", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            VStack(spacing: 12) {
                HStack {
                    Text("\(model.generations.count) generations")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History") { model.clearHistory() }
                        .disabled(model.generations.isEmpty)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.generations) { item in
                            HistoryRow(item: item)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}


struct LongFormWorkspace: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(eyebrow: "Studio workflow", title: "Long Form",
                            subtitle: "Turn full scripts into one continuous voiceover.")
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                StepHeader(number: 1, title: "Script",
                                           subtitle: "Paste a full script. It will be split at natural sentence boundaries.")
                                SpeechEditor(text:$model.longFormText, rules:model.pronunciationRules,
                                    matchMode:model.longFormMatchInsideWords ? "substring" : "words", minimumHeight:300)
                                HStack {
                                    Button("Paste") { if let s = NSPasteboard.general.string(forType: .string) { model.longFormText = s } }
                                    Button("Clear") { model.longFormText = "" }
                                    Spacer()
                                    Text("\(model.longFormText.count) characters").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                StepHeader(number: 2, title: "Pronunciation Notes",
                                           subtitle: "Optional replacements, one per line: original = replacement")
                                PronunciationRulesEditor(rules:$model.pronunciationRules, matchInsideWords:$model.longFormMatchInsideWords)
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Production Chunks").font(.title3.bold())
                                    Spacer()
                                    Button("Prepare / Refresh") { model.prepareProductionChunks() }
                                }
                                if model.productionChunks.isEmpty {
                                    Text("Prepare the script to inspect and edit chunks before generation.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(model.productionChunks.enumerated()), id: \.element.id) { i, chunk in
                                        VStack(alignment:.leading,spacing:7) {
                                            HStack {
                                                Text("Section \(i+1)").font(.caption.bold()).foregroundStyle(.blue)
                                                Spacer()
                                                Text(chunk.state).font(.caption2).foregroundStyle(chunk.state=="Complete" ? .green : .secondary)
                                                Button { model.retryChunk(i) } label:{ Image(systemName:"arrow.clockwise") }.help("Retry this section")
                                            }
                                            SpeechEditor(text: Binding(
                                                get:{ model.productionChunks.indices.contains(i) ? model.productionChunks[i].text : "" },
                                                set:{ model.updateChunk(i,text:$0) }
                                            ), rules:model.pronunciationRules,
                                               matchMode:model.longFormMatchInsideWords ? "substring" : "words", minimumHeight:72)
                                        }
                                        if i < model.productionChunks.count-1 { Divider().opacity(0.2) }
                                    }
                                }
                            }
                        }

                        if let u = model.longFormOutputURL {
                            Card {
                                VStack(alignment: .leading, spacing: 12) {
                                    StepHeader(number: 3, title: "Master Audio",
                                               subtitle: "All sections have been joined into one WAV.")
                                    AudioWaveform(url: u, barCount: 100).frame(height: 60)
                                    FullPlayer(url: u, controller: model.outputPlayer)
                                    HStack {
                                        Button { model.exportOutput(u) } label: { Label("Export WAV", systemImage: "square.and.arrow.down") }
                                        ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }
                                        Spacer()
                                        Button { model.reveal(u) } label: { Label("Show in Finder", systemImage: "folder") }
                                    }
                                }
                            }
                        }
                    }.padding(.bottom, 24)
                }
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Long Form Settings", systemImage: "text.document").font(.headline)
                                NativeAdvancedControls(allowDuration:false)
                                Picker("Preset", selection: $model.preset) {
                                    ForEach(["Fast Preview","Natural","Narration","Maximum Quality","Auto Tuned"], id: \.self) { Text($0).tag($0) }
                                }.onChange(of: model.preset) { _, v in
                                    if v != "Auto Tuned" { model.applyPreset(v) }
                                }
                                SliderRow(title: "Speed", value: $model.speed, range: 0.5...1.5, display: String(format: "%.2f", model.speed))
                                SliderRow(title: "Steps", value: $model.steps, range: 8...64, display: "\(Int(model.steps))")
                                Divider().opacity(0.3)
                                HStack {
                                    Text("Reference")
                                    Spacer()
                                    Text(model.referenceURL?.deletingPathExtension().lastPathComponent ?? "None")
                                        .lineLimit(1).foregroundStyle(model.referenceURL == nil ? .red : .green)
                                }.font(.caption)
                                if model.isGenerating {
                                    ProgressView(value: model.longFormProgress)
                                    Text(model.longFormStatus).font(.caption).foregroundStyle(.secondary)
                                }
                                Button(action: model.generateLongForm) {
                                    HStack {
                                        if model.isGenerating { ProgressView().controlSize(.small) }
                                        Image(systemName: "waveform.badge.plus")
                                        Text(model.isGenerating ? "Generating…" : "Generate Full Voiceover").bold()
                                        Spacer()
                                    }.padding(.horizontal, 14).frame(height: 50)
                                     .background(LinearGradient(colors: [OVTheme.accent,OVTheme.accent2], startPoint: .leading, endPoint: .trailing))
                                     .clipShape(RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                                 .disabled(model.isGenerating || !model.modelReady || model.referenceURL == nil || model.longFormText.isEmpty)
                                Text("Choose the voice for this production here.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(width: 300)
            }.padding(18)
        }
    }
}


struct VariantStudioCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("A/B Variants").font(.title3.bold())
                        Text("Generate several takes of the same line and audition them side-by-side.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Takes",selection:$model.variantCount) {
                        Text("2 takes").tag(2);Text("3 takes").tag(3);Text("4 takes").tag(4)
                    }.frame(width:120)
                    Button("Generate Variants"){model.generateVariants()}
                        .disabled(model.referenceURL==nil || model.isGenerating)
                }
                if !model.variantURLs.isEmpty {
                    ForEach(Array(model.variantURLs.enumerated()),id: \.offset){i,u in
                        HStack {
                            Text("Take \(i+1)").font(.headline).frame(width:60,alignment:.leading)
                            AudioWaveform(url:u,barCount:38).frame(height:34)
                            Button { model.outputPlayer.toggle(u) } label:{Image(systemName:model.outputPlayer.isPlaying(u) ? "pause.fill" : "play.fill")}
                            Button { model.exportOutput(u) } label:{Image(systemName:"square.and.arrow.down")}
                        }
                    }
                }
            }
        }
    }
}

struct ProjectsWorkspace: View {
    @EnvironmentObject var model: AppModel

    private var current: AppModel.VoiceProject? {
        guard let id = model.currentProjectID else { return nil }
        return model.projects.first {$0.id == id}
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Production workspace",
                title: "Projects",
                subtitle: "Each project has its own voice, rules and outputs — completely separate from global History."
            )

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(current == nil ? "New Project" : "Current Project").font(.title2.bold())
                                        Text(model.projectStatus).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { model.newProject() } label: { Label("New Project", systemImage: "plus") }
                                    Button { model.saveCurrentProject() } label: {
                                        Label(current == nil ? "Save Project" : "Save Changes", systemImage: "square.and.arrow.down")
                                    }.buttonStyle(.borderedProminent)
                                }

                                TextField("Project name", text: $model.projectName).textFieldStyle(.roundedBorder)

                                HStack {
                                    Label(model.referenceURL?.deletingPathExtension().lastPathComponent ?? "No voice selected",
                                          systemImage: "person.wave.2")
                                    Spacer()
                                    Label("\(model.projectOutputs(current).count) outputs", systemImage: "waveform")
                                }.foregroundStyle(.secondary)

                                Divider().opacity(0.25)
                                Text("Pronunciation Dictionary").font(.headline)
                                TextEditor(text: $model.pronunciationRules)
                                    .font(.body.monospaced()).scrollContentBackground(.hidden)
                                    .padding(8).frame(height: 140)
                                    .background(Color.black.opacity(0.18))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Project Outputs").font(.headline)
                                let outputs = model.projectOutputs(current)
                                if outputs.isEmpty {
                                    Text("No outputs belong to this project yet. Generate new audio while this project is active to add it here.")
                                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                                } else {
                                    ForEach(outputs.prefix(20)) { g in
                                        HStack {
                                            Text(g.text).lineLimit(1)
                                            Spacer()
                                            Text(g.mode).font(.caption).foregroundStyle(.secondary)
                                            StatefulAudioButton(
                                                controller: model.outputPlayer,
                                                url: g.url,
                                                compact: true
                                            )
                                            Button { model.reveal(g.url) } label: { Image(systemName: "folder") }
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(.bottom, 24)
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Saved Projects", systemImage: "folder.fill").font(.headline)
                            Spacer()
                            Text("\(model.projects.count)").font(.caption).foregroundStyle(.secondary)
                        }

                        if model.projects.isEmpty {
                            Text("Create and save your first project.")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        } else {
                            ForEach(model.projects) { p in
                                VStack(alignment: .leading, spacing: 8) {
                                    Button { model.openProject(p) } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                                Text(p.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: model.currentProjectID == p.id ? "checkmark.circle.fill" : "chevron.right")
                                                .foregroundStyle(model.currentProjectID == p.id ? .green : .secondary)
                                        }
                                    }.buttonStyle(.plain)

                                    HStack {
                                        Text("\(p.generationIDs.count) outputs").font(.caption2).foregroundStyle(.secondary)
                                        Spacer()
                                        Button(role: .destructive) { model.deleteProject(p) } label: { Image(systemName: "trash") }
                                            .buttonStyle(.plain)
                                    }
                                }
                                Divider().opacity(0.18)
                            }
                        }
                    }
                }.frame(width: 300)
            }.padding(18)
        }
    }
}


struct EngineLabWorkspace: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Blind model benchmark",
                title: "Engine Lab",
                subtitle: "Choose any two installed engines, use one shared reference, and compare them blind."
            )

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                StepHeader(
                                    number: 1,
                                    title: "Reference Voice",
                                    subtitle: "Choose the benchmark reference here — no need to leave Engine Lab."
                                )

                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill((model.referenceURL == nil ? Color.orange : Color.green).opacity(0.12))
                                            .frame(width: 48, height: 48)
                                        Image(systemName: "person.wave.2")
                                            .foregroundStyle(model.referenceURL == nil ? .orange : .green)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.referenceURL?.deletingPathExtension().lastPathComponent ?? "No reference selected")
                                            .font(.headline)
                                        Text(model.referenceURL == nil ? "Choose a saved voice or browse for audio" : "Reference ready for both engines")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Menu {
                                        if !model.savedVoices.isEmpty {
                                            Section("Saved Voices") {
                                                ForEach(model.savedVoices) { voice in
                                                    Button(voice.name) {
                                                        model.selectEngineLabVoice(voice)
                                                    }
                                                }
                                            }
                                        }

                                        Section {
                                            Button("Browse Audio…") {
                                                model.chooseReference()
                                            }
                                        }
                                    } label: {
                                        Label(model.referenceURL == nil ? "Choose Reference" : "Change", systemImage: "chevron.up.chevron.down")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                if let ref = model.referenceURL {
                                    AudioWaveform(url: ref, barCount: 58)
                                        .frame(height: 42)
                                    CompactPlayer(url: ref, controller: model.referencePlayer)
                                }
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                StepHeader(
                                    number: 2,
                                    title: "Test Script",
                                    subtitle: "Speed is shared. OmniVoice controls apply only to OmniVoice; F5 comparisons require plain text and no pronunciation overrides."
                                )

                                if model.engineLabSupportsNative {
                                    SpeechEditor(text:$model.engineLabText, rules:model.clonePronunciationRules,
                                        matchMode:model.cloneMatchInsideWords ? "substring" : "words")
                                    PronunciationRulesEditor(rules:$model.clonePronunciationRules, matchInsideWords:$model.cloneMatchInsideWords)
                                } else {
                                TextEditor(text: $model.engineLabText)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(height: 150)
                                    .background(Color.black.opacity(0.18))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text("F5 accepts plain text. Clear Clone pronunciation rules and use Auto detect before comparing; OmniVoice advanced settings use defaults in mixed-engine comparisons.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let a = model.engineLabA, let b = model.engineLabB {
                            Card {
                                VStack(alignment: .leading, spacing: 18) {
                                    StepHeader(
                                        number: 3,
                                        title: "Blind Listening",
                                        subtitle: "Listen first. Pick the better result before revealing the engine names."
                                    )

                                    BlindEngineTake(
                                        label: "A",
                                        url: a,
                                        engine: model.engineLabRevealed ? model.engineLabMap["A"] : nil
                                    )

                                    Divider().opacity(0.25)

                                    BlindEngineTake(
                                        label: "B",
                                        url: b,
                                        engine: model.engineLabRevealed ? model.engineLabMap["B"] : nil
                                    )

                                    HStack {
                                        Text("Best overall clone")
                                            .font(.headline)
                                        Spacer()

                                        Button("Choose A") { model.engineLabWinner = "A" }
                                            .buttonStyle(.borderedProminent)
                                        Button("Choose B") { model.engineLabWinner = "B" }
                                            .buttonStyle(.borderedProminent)
                                    }

                                    if let winner = model.engineLabWinner {
                                        Label("You chose Take \(winner)", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }

                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Engine Matchup", systemImage: "cpu")
                                    .font(.headline)

                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Engine 1")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("Engine 1", selection: $model.engineLabEngineA) {
                                        ForEach(model.engineLabAvailableEngines, id: \.self) { engine in
                                            Text(engine).tag(engine)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }

                                Image(systemName: "arrow.up.arrow.down")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)

                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Engine 2")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("Engine 2", selection: $model.engineLabEngineB) {
                                        ForEach(model.engineLabAvailableEngines, id: \.self) { engine in
                                            Text(engine).tag(engine)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }

                                if model.engineLabEngineA == model.engineLabEngineB {
                                    Label("Choose two different engines.", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }

                                Divider().opacity(0.25)

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.engineLabAvailableEngines, id: \.self) { engine in
                                        HStack {
                                            Circle().fill(Color.green).frame(width: 7, height: 7)
                                            Text(engine).font(.caption)
                                            Spacer()
                                            Text("READY").font(.caption2.bold()).foregroundStyle(.green)
                                        }
                                    }
                                }

                                if model.engineLabSupportsNative {
                                    NativeAdvancedControls()
                                }

                                Button(action: model.runEngineComparison) {
                                    HStack {
                                        if model.engineLabRunning {
                                            ProgressView().controlSize(.small)
                                        }
                                        Image(systemName: "testtube.2")
                                        Text(model.engineLabRunning ? "Comparing…" : "Generate A / B").bold()
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 50)
                                    .background(
                                        LinearGradient(
                                            colors: [OVTheme.accent, OVTheme.accent2],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(
                                    model.engineLabRunning ||
                                    model.referenceURL == nil ||
                                    model.engineLabEngineA == model.engineLabEngineB ||
                                    model.engineLabAvailableEngines.count < 2
                                )

                                Text(model.engineLabStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if model.engineLabA != nil {
                            Card {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Reveal").font(.headline)

                                    Text("Choose A or B first so the comparison stays blind.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button("Reveal Engines") {
                                        model.revealEngineComparison()
                                    }
                                    .disabled(model.engineLabWinner == nil)

                                    if model.engineLabRevealed {
                                        Divider().opacity(0.25)
                                        Text("A  •  \(model.engineLabMap["A"] ?? "Unknown")")
                                        Text("B  •  \(model.engineLabMap["B"] ?? "Unknown")")

                                        if let winner = model.engineLabWinner,
                                           let engine = model.engineLabMap[winner] {
                                            Label("Winner: \(engine)", systemImage: "trophy.fill")
                                                .font(.headline)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 330)
            }
            .padding(18)
        }
        .onAppear {
            model.checkEngineLab()
            model.checkPersonalModel()
        }
    }
}


struct EngineStatusRow: View {
    let name: String
    let detail: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            Text(ready ? "READY" : "SETUP")
                .font(.caption2.bold())
                .foregroundStyle(ready ? .green : .orange)
        }
    }
}

struct BlindEngineTake: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let url: URL
    let engine: String?

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .frame(width: 48, height: 48)
                .background(OVTheme.accent.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(engine ?? "Hidden Engine")
                        .font(.headline)
                    Spacer()
                    if engine != nil {
                        Text("REVEALED")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }

                AudioWaveform(url: url, barCount: 62)
                    .frame(height: 42)

                FullPlayer(url: url, controller: model.outputPlayer)
            }
        }
    }
}


struct PersonalVoiceWorkspace: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "Voice training lab",
                title: "Voice Training",
                subtitle: "Prepare a clean speech dataset and train your own OmniVoice engine."
            )

            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            StepHeader(
                                number: 1,
                                title: "Voice Dataset",
                                subtitle: "Choose a folder of clean clips. Matching .txt transcripts are preferred."
                            )

                            HStack {
                                Button(action: model.choosePersonalDatasetFolder) {
                                    Label(
                                        model.personalDatasetFolder?.lastPathComponent ?? "Choose Recording Folder",
                                        systemImage: "folder.badge.plus"
                                    )
                                }
                                Spacer()
                                Picker("Language", selection: $model.personalLanguage) {
                                    Text("English").tag("en")
                                    Text("French").tag("fr")
                                    Text("Spanish").tag("es")
                                    Text("German").tag("de")
                                }
                                .frame(width: 160)
                            }

                            Toggle(
                                "Auto-transcribe clips without matching .txt files using local Whisper",
                                isOn: $model.personalAutoTranscribe
                            )

                            Text("Best results: one speaker, dry/clean recordings, consistent microphone, and roughly 20–60 minutes of speech. Quiet usable clips are normalized automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button(action: model.preparePersonalDataset) {
                                HStack {
                                    if model.personalPreparing { ProgressView().controlSize(.small) }
                                    Image(systemName: "wand.and.stars")
                                    Text(model.personalPreparing ? "Preparing…" : "Analyse & Prepare Dataset").bold()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.personalDatasetFolder == nil || model.personalPreparing)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            StepHeader(
                                number: 2,
                                title: "Dataset Quality",
                                subtitle: "Only accepted clips are written into the OmniVoice training manifests."
                            )

                            HStack(spacing: 24) {
                                MetricTile(value: "\(model.personalGoodClips)", label: "Accepted", good: true)
                                MetricTile(value: "\(model.personalRejectedClips)", label: "Rejected", good: model.personalRejectedClips == 0)
                                MetricTile(value: String(format: "%.1f", model.personalMinutes), label: "Minutes", good: model.personalMinutes >= 20)
                            }

                            PersonalVoiceStatusBanner(
                                status: model.personalStatus,
                                isPreparing: model.personalPreparing,
                                isTraining: model.personalTraining,
                                accepted: model.personalGoodClips,
                                minutes: model.personalMinutes,
                                phase: model.personalTrainingPhase,
                                step: model.personalTrainingStep,
                                totalSteps: model.personalTrainingTotal
                            )

                            if !model.personalRejectionDetails.isEmpty {
                                Divider().opacity(0.25)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Rejected clips").font(.headline)
                                    ForEach(model.personalRejectionDetails, id: \.self) { detail in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .foregroundStyle(.orange)
                                            Text(detail)
                                                .font(.caption)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            StepHeader(
                                number: 3,
                                title: "Train Voice",
                                subtitle: "Train a compact OmniVoice LoRA locally, then save it as a named engine."
                            )

                            if model.personalStatus.lowercased().contains("complete") {
                                PersonalTrainingStatusBanner(
                                    status: model.personalStatus,
                                    running: false,
                                    phase: "Complete",
                                    step: model.personalTrainingTotal,
                                    totalSteps: model.personalTrainingTotal,
                                    adapterPath: model.personalAdapterPath
                                )

                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Save Trained Voice")
                                        .font(.headline)

                                    Text("Give this trained voice a name. The saved name becomes an engine you can select directly in Engine Lab.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 10) {
                                        TextField("e.g. Dwayne Studio v1", text: $model.trainedVoiceName)
                                            .textFieldStyle(.roundedBorder)

                                        Button(action: model.saveTrainedVoice) {
                                            HStack {
                                                if model.savingTrainedVoice {
                                                    ProgressView().controlSize(.small)
                                                }
                                                Image(systemName: "square.and.arrow.down")
                                                Text(model.savingTrainedVoice ? "Saving…" : "Save Voice")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(
                                            model.savingTrainedVoice ||
                                            model.trainedVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        )
                                    }

                                    if !model.savedTrainedVoiceName.isEmpty {
                                        Label(
                                            "\(model.savedTrainedVoiceName) added to Engine Lab",
                                            systemImage: "checkmark.circle.fill"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    } else if !model.personalMergeStatus.isEmpty {
                                        Text(model.personalMergeStatus)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(14)
                                .background(Color.green.opacity(0.045))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.green.opacity(0.16), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                                if !model.personalAdapterPath.isEmpty {
                                    Label(
                                        "Checkpoint: \(model.personalAdapterPath)",
                                        systemImage: "checkmark.seal.fill"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                }

                                if !model.personalTrainingLog.isEmpty {
                                    DisclosureGroup("View training log") {
                                        ScrollView {
                                            Text(model.personalTrainingLog)
                                                .font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(height: 180)
                                        .padding(10)
                                        .background(Color.black.opacity(0.25))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .padding(.top, 8)
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            } else {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Training mode")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("LoRA • SDPA • single process")
                                            .font(.headline)
                                    }

                                    Spacer()

                                    Button(action: model.startPersonalTraining) {
                                        HStack {
                                            if model.personalTraining {
                                                ProgressView().controlSize(.small)
                                            }
                                            Image(systemName: "cpu")
                                            Text(model.personalTraining ? "Training…" : "Start LoRA Training")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.personalGoodClips == 0 || model.personalTraining)
                                }

                                PersonalTrainingStatusBanner(
                                    status: model.personalStatus,
                                    running: model.personalTraining,
                                    phase: model.personalTrainingPhase,
                                    step: model.personalTrainingStep,
                                    totalSteps: model.personalTrainingTotal,
                                    adapterPath: model.personalAdapterPath
                                )

                                Text("Apple Silicon training uses Mac-safe single-process data loading.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if !model.personalTrainingLog.isEmpty {
                                    ScrollView {
                                        Text(model.personalTrainingLog)
                                            .font(.system(size: 11, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(height: 180)
                                    .padding(10)
                                    .background(Color.black.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What happens").font(.headline)
                            Label("Clips are checked for duration, clipping and usable speech level", systemImage: "waveform.path.ecg")
                            Label("Audio is normalized to 24 kHz mono WAV", systemImage: "waveform")
                            Label("Train / dev JSONL manifests are created locally", systemImage: "doc.text")
                            Label("OmniVoice audio tokens are extracted", systemImage: "square.stack.3d.up")
                            Label("A LoRA adapter is trained without overwriting the base model", systemImage: "brain.head.profile")
                            Label("The adapter can later enter Engine Lab against zero-shot OmniVoice", systemImage: "testtube.2")
                        }
                        .font(.caption)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }
}


struct PersonalVoiceStatusBanner: View {
    let status: String
    let isPreparing: Bool
    let isTraining: Bool
    let accepted: Int
    let minutes: Double
    let phase: String
    let step: Int
    let totalSteps: Int

    private var failed: Bool {
        status.lowercased().contains("fail")
    }

    private var ready: Bool {
        status.lowercased().contains("dataset ready")
    }

    private var tint: Color {
        if failed { return .red }
        if ready { return .green }
        if isPreparing || isTraining { return OVTheme.accent }
        return .secondary
    }

    private var title: String {
        if isPreparing { return "PREPARING DATASET" }
        if isTraining { return "TRAINING IN PROGRESS" }
        if failed { return "ACTION REQUIRED" }
        if ready { return "DATASET READY" }
        return status.uppercased()
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 42, height: 42)

                if isPreparing || isTraining {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.15)
                    .foregroundStyle(tint)

                if isTraining {
                    Text("\(phase) • step \(step) of \(totalSteps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if ready {
                    Text("\(accepted) clips accepted • \(String(format: "%.1f", minutes)) min prepared")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(13)
        .background(tint.opacity(0.065))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct PersonalTrainingStatusBanner: View {
    let status: String
    let running: Bool
    let phase: String
    let step: Int
    let totalSteps: Int
    let adapterPath: String

    private var failed: Bool { status.lowercased().contains("fail") }
    private var complete: Bool { status.lowercased().contains("complete") }

    private var tint: Color {
        if failed { return .red }
        if complete { return .green }
        if running { return OVTheme.accent }
        return .secondary
    }

    private var headline: String {
        if running { return "TRAINING IN PROGRESS" }
        if complete { return "TRAINING COMPLETE" }
        if failed { return "TRAINING FAILED" }
        return "READY TO TRAIN"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: complete ? "checkmark.seal.fill" : (failed ? "xmark.octagon.fill" : "cpu"))
                        .foregroundStyle(tint)
                }

                Text(headline)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(tint)

                Spacer()

                if running && totalSteps > 0 {
                    Text("\(step) / \(totalSteps)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if running {
                Text(phase)
                    .font(.headline)

                if totalSteps > 0 {
                    ProgressView(value: Double(step), total: Double(totalSteps))
                }
            } else if complete && !adapterPath.isEmpty {
                Text("Trained OmniVoice engine created")
                    .font(.headline)
            } else if failed {
                Text("Open the training log below for the exact error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dataset prepared. Start a Mac-safe single-process LoRA run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(tint.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MetricTile: View {
    let value: String
    let label: String
    let good: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(good ? .green : .primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsWorkspace: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                eyebrow: "OmniVoice preferences",
                title: "Settings",
                subtitle: "Playback, storage, inference and local runtime."
            )

            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("General", systemImage: "slider.horizontal.3")
                                .font(.headline)

                            Toggle("Automatically play generated audio", isOn: $model.autoPlay)
                            Toggle("Keep WAV files when removing history entries", isOn: $model.keepOutputs)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Storage", systemImage: "internaldrive")
                                .font(.headline)

                            SettingsPathRow(label: "Outputs", value: "~/Documents/OmniVoice-Mac/outputs")
                            SettingsPathRow(label: "Reference voices", value: "~/Documents/OmniVoice-Mac/voices")
                            SettingsPathRow(label: "Trained engines", value: "~/Documents/OmniVoice-Mac/personal-voice/engines")
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Native app: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                                .font(.caption)
                            ForEach(model.runtimeProvenance.keys.sorted(), id: \.self) { key in
                                SettingsPathRow(label: key.replacingOccurrences(of: "_", with: " "),
                                                value: model.runtimeProvenance[key] ?? "unknown")
                            }

                            Label("Inference", systemImage: "cpu")
                                .font(.headline)

                            SettingsStatusRow(label: "Device", value: "Apple Silicon / MPS", ready: model.modelReady)
                            SettingsStatusRow(label: "OmniVoice", value: model.modelReady ? "Ready" : "Loading", ready: model.modelReady)
                            SettingsStatusRow(label: "F5-TTS", value: model.f5Available ? "Ready" : "Unavailable", ready: model.f5Available)

                            Divider().opacity(0.2)

                            HStack {
                                Text("Backend")
                                Spacer()
                                Text("127.0.0.1:8011")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct SettingsPathRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsStatusRow: View {
    let label: String
    let value: String
    let ready: Bool
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(value)
                .font(.caption)
                .foregroundStyle(ready ? .green : .secondary)
        }
    }
}

enum GenerationMode { case clone, design }


struct ReferenceAnalysisCard: View {
    @EnvironmentObject var model: AppModel

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("Reference Analyzer", systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    if model.referenceAnalysisReady {
                        Text("\(model.referenceQualityScore)/100")
                            .font(.caption.bold())
                            .foregroundStyle(model.referenceQualityScore >= 75 ? .green : .orange)
                    }
                }

                Text("Measure the reference and tune OmniVoice to the speaker instead of guessing the controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.referenceAnalysisReady {
                    VStack(spacing: 9) {
                        HStack(spacing: 10) {
                            metric("Quality", model.referenceQualityLabel)
                            metric("Pace", model.referencePaceLabel)
                        }
                        HStack(spacing: 10) {
                            metric("Pitch", model.referencePitch > 0 ? "\(Int(model.referencePitch)) Hz" : "—")
                            metric("Pitch Range", model.referencePitchRange > 0 ? "\(Int(model.referencePitchRange)) Hz" : "—")
                        }
                        HStack(spacing: 10) {
                            metric("Speech", "\(Int(model.referenceSpeechRatio * 100))%")
                            metric("Pauses", "\(Int(model.referencePauseRatio * 100))%")
                        }
                        if model.referenceWPM > 0 {
                            HStack {
                                metric("Measured pace", "\(Int(model.referenceWPM)) wpm")
                                metric("Level", String(format: "%.1f dB", model.referenceRMS))
                            }
                        }
                    }

                    Divider().opacity(0.22)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Recommended")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(String(format: "%.2f×", model.recommendedSpeed))
                            Spacer()
                            Text("\(Int(model.recommendedSteps)) steps")
                            Spacer()
                            Text(String(format: "%.1f guidance", model.recommendedGuidance))
                        }
                        .font(.caption.monospacedDigit())

                        Button {
                            model.applyReferenceRecommendations()
                        } label: {
                            Label("Apply Recommended Settings", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(model.referenceAnalysisStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    model.analyzeReference()
                } label: {
                    HStack {
                        if model.referenceAnalyzing {
                            ProgressView().controlSize(.small)
                        }
                        Image(systemName: "waveform.path.ecg")
                        Text(model.referenceAnalyzing ? "Analyzing…" : (model.referenceAnalysisReady ? "Analyze Again" : "Analyze Reference"))
                        Spacer()
                    }
                }
                .disabled(model.referenceURL == nil || model.referenceAnalyzing)
            }
        }
    }
}

struct GenerationSettingsCard: View {
    @EnvironmentObject var model: AppModel
    let mode: GenerationMode

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Generation Settings", systemImage: "slider.horizontal.3").font(.headline)
                Picker("Preset", selection: $model.preset) {
                    ForEach(["Fast Preview","Natural","Narration","Maximum Quality","Auto Tuned"], id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model.preset) { _, v in model.applyPreset(v) }

                SliderRow(title: "Speed", value: $model.speed, range: 0.5...1.5, display: String(format: "%.2f", model.speed))
                SliderRow(title: "Steps", value: $model.steps, range: 8...64, display: "\(Int(model.steps))")
                SliderRow(title: "Guidance", value: $model.guidance, range: 0...4, display: String(format: "%.1f", model.guidance))

                Text("Speed adjusts overall pacing; Guidance adjusts conditioning strength, not emotional intensity.")
                    .font(.caption2).foregroundStyle(.secondary)
                NativeAdvancedControls()

                Button {
                    if mode == .clone { model.generateClone() }
                    else { model.generateDesign() }
                } label: {
                    HStack {
                        if model.isGenerating { ProgressView().controlSize(.small) }
                        Image(systemName: "waveform")
                        Text(model.isGenerating ? "Generating…" : "Generate Speech").bold()
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(
                    !model.modelReady ||
                    model.isGenerating ||
                    (mode == .clone && model.referenceURL == nil)
                )

                Text("Apple GPU (MPS) • Local & private")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct RecentCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Generations").font(.headline)
                    Spacer()
                    Text("\(model.generations.count)").foregroundStyle(.secondary)
                }

                if model.generations.isEmpty {
                    Text("Your recent generations will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.generations.prefix(4)) { item in
                        HStack(spacing: 10) {
                            Button {
                                model.outputPlayer.toggle(item.url)
                            } label: {
                                Image(systemName: model.outputPlayer.isPlaying(item.url) ? "pause.fill" : "play.fill")
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.07))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).lineLimit(1).font(.subheadline)
                                Text(item.mode).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct GenerationGrid: View {
    @EnvironmentObject var model: AppModel
    let items: [AppModel.Generation]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Audio Yet",
                    systemImage: "waveform",
                    description: Text("Generate a voice and it will appear here.")
                )
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(items) { item in
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(item.mode).font(.caption).foregroundStyle(.blue)
                                    Spacer()
                                    Text(item.createdAt, style: .date)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }

                                Text(item.text).lineLimit(3).font(.headline)
                                AudioWaveform(url: item.url, barCount: 50).frame(height: 40)

                                HStack {
                                    StatefulAudioButton(
                                        controller: model.outputPlayer,
                                        url: item.url,
                                        compact: true
                                    )
                                    Spacer()
                                    Button {
                                        model.exportOutput(item.url)
                                    } label: {
                                        Image(systemName: "square.and.arrow.down")
                                    }
                                    Button {
                                        model.reveal(item.url)
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let item: AppModel.Generation

    var body: some View {
        HStack(spacing: 14) {
                        StatefulAudioButton(
                controller: model.outputPlayer,
                url: item.url,
                compact: true
            )            .buttonStyle(.plain)

            AudioWaveform(url: item.url, barCount: 28)
                .frame(width: 120, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).lineLimit(1).font(.headline)
                HStack {
                    Text(item.mode)
                    Text("•")
                    Text(item.createdAt, style: .date)
                    Text(item.createdAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.exportOutput(item.url)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }

            Button {
                model.reveal(item.url)
            } label: {
                Image(systemName: "folder")
            }

            Button(role: .destructive) {
                model.deleteGeneration(item)
            } label: {
                Image(systemName: "trash")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}


struct StatefulAudioButton: View {
    @ObservedObject var controller: AudioPlayerController
    let url: URL
    var compact = false

    var body: some View {
        Button {
            controller.toggle(url)
        } label: {
            Image(systemName: controller.isPlaying(url) ? "pause.fill" : "play.fill")
                .frame(
                    width: compact ? 18 : 24,
                    height: compact ? 18 : 24
                )
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .help(controller.isPlaying(url) ? "Pause" : "Play")
    }
}

struct CompactPlayer: View {
    let url: URL
    @ObservedObject var controller: AudioPlayerController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                controller.toggle(url)
            } label: {
                Image(systemName: controller.isPlaying(url) ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.20))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { controller.currentTime(for: url) },
                    set: { controller.seek(url, to: $0) }
                ),
                in: 0...max(controller.duration(for: url), 0.01)
            )

            Text("\(time(controller.currentTime(for: url))) / \(time(controller.duration(for: url)))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct FullPlayer: View {
    let url: URL
    @ObservedObject var controller: AudioPlayerController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.toggle(url)
            } label: {
                Image(systemName: controller.isPlaying(url) ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { controller.currentTime(for: url) },
                    set: { controller.seek(url, to: $0) }
                ),
                in: 0...max(controller.duration(for: url), 0.01)
            )

            Text("\(time(controller.currentTime(for: url))) / \(time(controller.duration(for: url)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 88)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct AudioWaveform: View {
    let url: URL
    let barCount: Int

    @State private var samples: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                let data = samples.isEmpty ? Array(repeating: CGFloat(0.12), count: barCount) : samples
                ForEach(Array(data.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .top, endPoint: .bottom))
                        .frame(
                            width: max(1.5, (geo.size.width - CGFloat(max(0, barCount - 1)) * 2) / CGFloat(barCount)),
                            height: max(3, geo.size.height * value)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            samples = await waveformSamples(url: url, count: barCount)
        }
    }

    private func waveformSamples(url: URL, count: Int) async -> [CGFloat] {
        await Task.detached(priority: .utility) {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frameCount = AVAudioFrameCount(file.length)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
                else { return [] }

                try file.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { return [] }

                let total = Int(buffer.frameLength)
                let bucket = max(1, total / count)
                var values: [CGFloat] = []
                values.reserveCapacity(count)

                for i in 0..<count {
                    let start = i * bucket
                    if start >= total { values.append(0.05); continue }
                    let end = min(total, start + bucket)
                    var peak: Float = 0
                    for j in start..<end {
                        peak = max(peak, abs(channel[j]))
                    }
                    values.append(CGFloat(peak))
                }

                let maxValue = values.max() ?? 1
                guard maxValue > 0 else { return Array(repeating: 0.05, count: count) }
                return values.map { max(0.06, min(1.0, $0 / maxValue)) }
            } catch {
                return []
            }
        }.value
    }
}


struct CreatorPresetCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? OVTheme.accent.opacity(0.20) : Color.white.opacity(0.055))
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? OVTheme.accent : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(OVTheme.accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                selected
                    ? OVTheme.accent.opacity(0.09)
                    : OVTheme.controlSurface
            )
            .overlay(
                RoundedRectangle(cornerRadius: OVTheme.nestedRadius)
                    .stroke(
                        selected ? OVTheme.accent.opacity(0.55) : OVTheme.border,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: OVTheme.nestedRadius))
        }
        .buttonStyle(.plain)
    }
}

struct DesignControlTile: View {
    let title: String
    let icon: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(OVTheme.controlSurface)
        .overlay(
            RoundedRectangle(cornerRadius: OVTheme.nestedRadius)
                .stroke(OVTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: OVTheme.nestedRadius))
    }
}

struct DesignPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(20)
            .background(.ultraThinMaterial.opacity(0.62))
            .background(OVTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: OVTheme.radius, style: .continuous).stroke(OVTheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: OVTheme.radius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
    }
}

struct StepHeader: View {
    let number: Int
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.bold())
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: [OVTheme.accent, OVTheme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
