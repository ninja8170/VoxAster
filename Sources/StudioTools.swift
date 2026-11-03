import SwiftUI
import AVFoundation

// MARK: - Engine requests for the studio tools

enum StudioAPI {
    static let base = "http://127.0.0.1:8011/"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Multipart POST to the local engine; engine errors come back as readable messages.
    static func post(_ path: String, fields: [String: String], files: [(String, URL)] = [],
                     timeout: TimeInterval = 900) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func add(_ string: String) { body.append(string.data(using: .utf8)!) }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        for (name, url) in files {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "")
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            body.append(data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw Failure(message: (json?["error"] as? String) ?? (json?["detail"] as? String)
                          ?? "The engine returned HTTP \(http.statusCode).")
        }
        return data
    }

    static func outputPath(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["output"] as? String else { throw Failure(message: "The engine returned an unreadable response.") }
        return path
    }

    static func jsonList(_ items: [String]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: items), encoding: .utf8)!
    }
}

extension AppModel {
    /// The descriptors Voice Design sends, built exactly as generateDesign() does.
    var designInstruct: String {
        guard designMode == "Design" else { return "" }
        return [designGender, designAge, designPitch, designStyle, designAccent, designDialect]
            .filter { $0 != "Auto" }.joined(separator: ", ")
    }
}

func audioDuration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
    return Double(file.length) / file.processingFormat.sampleRate
}

// MARK: - Reference Cleaner

struct CleanResult: Decodable, Equatable {
    struct Candidate: Decodable, Equatable { let start: Double; let end: Double; let score: Int }
    let start: Double
    let end: Double
    let score: Int
    let speech_ratio: Double
    let trimmed: Bool
    let output: String
    let transcript: String
    let source_duration: Double
    let candidates: [Candidate]
    var url: URL { URL(fileURLWithPath: output) }
}

@MainActor
final class ReferenceCleaner: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var result: CleanResult?
    @Published private(set) var sourcePath: String?

    /// Result for the reference currently loaded, if any.
    func result(for url: URL?) -> CleanResult? {
        guard let url, sourcePath == url.path else { return nil }
        return result
    }

    func run(_ model: AppModel, target: Double = 12) {
        guard let source = model.referenceURL, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await StudioAPI.post("reference/clean", fields: ["target": String(target)],
                                                    files: [("ref_audio", source)], timeout: 600)
                result = try JSONDecoder().decode(CleanResult.self, from: data)
                sourcePath = source.path
            } catch {
                model.errorMessage = "Reference Cleaner: \(error.localizedDescription)"
            }
        }
    }

    /// Switch the studio to the cleaned clip with its exact transcript.
    func use(_ model: AppModel, saveAs name: String? = nil) {
        guard let result else { return }
        if model.selectReference(result.url) {
            model.referenceText = result.transcript
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { model.saveCurrentVoice(named: name) }
        }
    }
}

// MARK: - Take Doctor

struct TakeReport: Decodable, Equatable {
    struct Word: Decodable, Equatable {
        let text: String
        let location: Int
        let length: Int
        let status: String
        let heard: String?
        let t0: Double?
        let t1: Double?
        let sentence: Int
        var flagged: Bool { status != "ok" }
        var range: NSRange { NSRange(location: location, length: length) }
    }
    struct Sentence: Decodable, Equatable { let text: String; let location: Int; let length: Int }
    let score: Int
    let wer: Double
    let transcript: String
    let notes: [String]
    let words: [Word]
    let sentences: [Sentence]
    let duration: Double
    var flagged: [Word] { words.filter(\.flagged) }

    /// Padded time range of a sentence inside the take (mirrors studio_tools.sentence_times).
    func times(ofSentence index: Int) -> (Double, Double)? {
        let timed = words.filter { $0.sentence == index }.compactMap { w -> (Double, Double)? in
            guard let a = w.t0, let b = w.t1 else { return nil }
            return (a, b)
        }
        if let first = timed.map(\.0).min(), let last = timed.map(\.1).max() {
            return (max(0, first - 0.06), min(duration, last + 0.10))
        }
        // Nothing of this sentence was heard: insert it between its neighbours.
        let before = words.filter { $0.sentence < index }.compactMap(\.t1).max()
        let after = words.filter { $0.sentence > index }.compactMap(\.t0).min()
        let start = before.map { min(duration, $0 + 0.05) } ?? 0
        let end = after.map { max(start, $0 - 0.05) } ?? (before == nil ? duration : start)
        return (start, end)
    }
}

@MainActor
final class TakeDoctor: ObservableObject {
    @Published private(set) var reports: [String: TakeReport] = [:]
    @Published private(set) var checkedScripts: [String: String] = [:]
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var repairing = false

    static let enabledKey = "takeDoctor"
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func report(for url: URL?) -> TakeReport? { url.flatMap { reports[$0.path] } }
    func isChecking(_ url: URL?) -> Bool { url.map { checking.contains($0.path) } ?? false }

    /// Report for a take only while the script still matches what was checked.
    func report(for url: URL?, script: String) -> TakeReport? {
        guard let url, checkedScripts[url.path] == script else { return nil }
        return reports[url.path]
    }

    func best(of urls: [URL]) -> URL? {
        let scored = urls.compactMap { url in reports[url.path].map { (url, $0.score) } }
        guard scored.count == urls.count, scored.count > 1 else { return nil }
        return scored.max { $0.1 < $1.1 }?.0
    }

    func check(_ urls: [URL], script: String) {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = urls.filter { !checking.contains($0.path) && checkedScripts[$0.path] != script }
        guard enabled, !text.isEmpty, !pending.isEmpty else { return }
        pending.forEach { checking.insert($0.path) }
        Task {
            defer { pending.forEach { checking.remove($0.path) } }
            do {
                let data = try await StudioAPI.post("takes/check", fields: [
                    "script": script, "paths": StudioAPI.jsonList(pending.map(\.path))], timeout: 600)
                struct Envelope: Decodable { let reports: [String: TakeReport] }
                let decoded = try JSONDecoder().decode(Envelope.self, from: data)
                for (path, report) in decoded.reports { reports[path] = report; checkedScripts[path] = script }
            } catch {
                // A failed check never blocks the take itself; it just stays unscored.
            }
        }
    }

    /// Re-render one sentence and splice it into the take, level-matched.
    func repair(_ take: URL, sentence index: Int, script: String, model: AppModel) {
        guard let report = reports[take.path], report.sentences.indices.contains(index),
              let span = report.times(ofSentence: index), !repairing, !model.busy else { return }
        let (start, end) = span
        let designed = model.voiceSource == .designed
        guard designed || model.referenceURL != nil else { return }
        guard var fields = model.generationFields(
            text: report.sentences[index].text, pronunciations: model[keyPath: model.rulesKey],
            language: designed ? "Auto detect" : model.cloneLanguage, instruct: designed ? model.designInstruct : "",
            matchInsideWords: model[keyPath: model.matchKey], allowDuration: false, checkReference: !designed) else { return }
        fields["take_path"] = take.path
        fields["start"] = String(format: "%.3f", start)
        fields["end"] = String(format: "%.3f", end)
        let files = designed ? [] : [("ref_audio", model.referenceURL!)]
        repairing = true
        model.isGenerating = true
        Task {
            defer { repairing = false; model.isGenerating = false }
            do {
                let path = try StudioAPI.outputPath(try await StudioAPI.post("takes/repair", fields: fields, files: files))
                model.recordTake(path: path, text: script, mode: "Repaired Take")
                model.outputURL = URL(fileURLWithPath: path)
                if model.autoPlay { model.outputPlayer.toggle(URL(fileURLWithPath: path)) }
            } catch {
                model.errorMessage = "Take Doctor could not re-render that sentence: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Cast

@MainActor
final class CastStore: ObservableObject {
    /// One spoken line inside a Together passage.
    struct Part: Codable, Equatable {
        var speaker: String; var text: String
        var cut: Bool? = nil    // the line ends "--": the next speaker cuts it off
        var over: Bool? = nil   // the line starts ">>": it talks over the previous one
    }

    /// A rendered unit of the scene: one line (Line by line) or a passage of several lines (Together).
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var speaker: String
        var text: String
        var state = "Pending"
        var output: URL?
        var error: String?
        var parts: [Part]? = nil
        var cut = false, over = false
        /// Together: where each part sits in the passage audio, [start, end] seconds (from Whisper).
        var slices: [[Double]]? = nil
        /// Whisper's check of the rendered audio: score and the words that came out wrong.
        var score: Int? = nil
        var issues: [Issue]? = nil

        init(speaker: String, text: String, state: String = "Pending", output: URL? = nil, error: String? = nil,
             cut: Bool = false, over: Bool = false) {
            self.speaker = speaker; self.text = text; self.state = state; self.output = output; self.error = error
            self.cut = cut; self.over = over
        }

        init(passage: [Part]) {
            var names: [String] = []
            for part in passage where !names.contains(part.speaker) { names.append(part.speaker) }
            self.init(speaker: names.joined(separator: " · "),
                      text: passage.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"))
            parts = passage
        }
    }

    /// A line as written to disk. In the draft `path` is absolute; in a saved scene it is a file name in the scene folder.
    struct StoredLine: Codable, Equatable {
        var speaker: String; var text: String; var path: String?; var error: String?; var parts: [Part]? = nil
        var cut: Bool? = nil; var over: Bool? = nil; var slices: [[Double]]? = nil
        var score: Int? = nil; var issues: [Issue]? = nil
    }

    /// A word Whisper heard wrongly (or not at all), at `t` seconds into the unit's audio.
    struct Issue: Codable, Equatable { var t: Double; var word: String; var heard: String? }

    /// Whether the Together engine (MOSS-TTSD) is installed, as reported by the backend.
    struct EngineStatus: Decodable { var available: Bool; var reason: String }

    static let engines: [(id: String, name: String)] = [("lines", "Line by line"), ("moss", "Together")]
    /// Lines MOSS renders in one pass. Short passages stay accurate; ~40 s ones started to slip in testing.
    nonisolated static let passageLines = 6, passageChars = 420, passageSpeakers = 5

    /// The working draft, kept across relaunches including rendered lines.
    struct Saved: Codable {
        var script: String; var assignments: [String: String]; var gapMs: Double
        var room: String?; var lines: [StoredLine]?; var master: String?
        var sceneID: UUID?; var sceneName: String?
        var engine: String?; var designRefs: [String: String]?
        var clips: [Clip]?
        var tracks: Tracks?
        var markers: [Marker]?
    }

    /// A named point on the Scene Editor's ruler.
    struct Marker: Codable, Identifiable, Equatable { var id = UUID(); var t: Double; var name: String }

    /// Per-lane mix controls in the Scene Editor (Audacity-style track panel).
    struct Tracks: Codable, Equatable {
        var muted: [String] = []
        var soloed: [String] = []
        var gain: [String: Double] = [:]
    }

    /// A scene in the Library: its own folder holding copies of every line and the master,
    /// so deleting a take never breaks it.
    struct Scene: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var script: String
        var assignments: [String: String]
        var gapMs: Double
        var room: String
        var lines: [StoredLine]
        var master: String?
        var createdAt: Date
        var updatedAt: Date
        var engine: String? = nil
        var designRefs: [String: String]? = nil   // file names in the scene folder
        var clips: [Clip]? = nil
        var tracks: Tracks? = nil
        var markers: [Marker]? = nil
    }

    /// Designed cast voices: plain descriptors the engine accepts.
    static let designedVoices: [(String, String)] = [
        ("Man, low and steady", "male, middle-aged, low pitch"),
        ("Woman, warm", "female, middle-aged, moderate pitch"),
        ("Young man", "male, young adult, moderate pitch"),
        ("Young woman", "female, young adult, high pitch"),
        ("Older man", "male, elderly, low pitch"),
        ("Older woman", "female, elderly, moderate pitch"),
        ("Child", "child, high pitch"),
        ("British narrator", "male, middle-aged, low pitch, British accent"),
        ("American narrator", "female, middle-aged, moderate pitch, American accent"),
        ("Whisperer", "female, young adult, whisper"),
    ]

    /// Shared acoustic spaces (keys match studio_tools.ROOMS).
    static let rooms: [(id: String, name: String)] = [("dry", "Dry"), ("booth", "Booth"), ("room", "Small room"), ("large", "Large room")]

    @Published var script: String { didSet { save() } }
    @Published var assignments: [String: String] { didSet { save() } }
    @Published var gapMs: Double { didSet { save() } }
    @Published var room: String { didSet { save() } }
    @Published var engine: String { didSet { save() } }
    @Published private(set) var mossStatus: EngineStatus?
    /// Voices for Together: a short, clean OmniVoice sample per "SPEAKER|voice", which MOSS then clones.
    /// MOSS needs clean speech; OmniVoice copes with noisy references (stand-up, music, crowds), so it goes first.
    private var designRefs: [String: URL] = [:] { didSet { save() } }
    @Published var sceneName: String { didSet { save() } }
    @Published private(set) var sceneID: UUID? { didSet { save() } }
    @Published private(set) var lines: [Line] = [] { didSet { save() } }
    /// The timeline: every line as a clip on its speaker's lane, in script order.
    @Published private(set) var clips: [Clip] = [] { didSet { if !liveEdit { save() } } }
    @Published private(set) var mixing = false
    @Published var tracks = Tracks() { didSet { save() } }
    @Published var markers: [Marker] = [] { didSet { save() } }
    private var liveEdit = false
    private var masterIsEdit = false
    private var remixTask: Task<Void, Never>?
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    private var baseline: Snapshot?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var durations: [URL: Double] = [:]
    @Published private(set) var masterURL: URL? { didSet { save() } }
    @Published private(set) var scenes: [Scene] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    private var task: Task<Void, Never>?
    private var restoring = true

    private let file: URL
    let scenesRoot: URL

    init(file: URL? = nil, scenesRoot: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniVoice/cast.json")
        self.scenesRoot = scenesRoot ?? AppModel.documentsRootURL.appendingPathComponent("outputs/scenes", isDirectory: true)
        let saved = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        script = saved?.script ?? ""
        assignments = saved?.assignments ?? [:]
        gapMs = saved?.gapMs ?? 350
        room = saved?.room.flatMap { r in Self.rooms.contains { $0.id == r } ? r : nil } ?? "room"
        engine = saved?.engine.flatMap { e in Self.engines.contains { $0.id == e } ? e : nil } ?? "lines"
        designRefs = (saved?.designRefs ?? [:]).compactMapValues { path in
            let url = URL(fileURLWithPath: path); return Self.exists(url) ? url : nil }
        sceneName = saved?.sceneName ?? ""
        sceneID = saved?.sceneID
        lines = (saved?.lines ?? []).map { Self.line($0, folder: nil) }
        masterURL = saved?.master.map { URL(fileURLWithPath: $0) }.flatMap { Self.exists($0) ? $0 : nil }
        clips = (saved?.clips ?? []).filter { $0.unit < lines.count }
        tracks = saved?.tracks ?? Tracks()
        markers = saved?.markers ?? []
        restoring = false
        loadScenes()
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func line(_ stored: StoredLine, folder: URL?) -> Line {
        let url = stored.path.map { folder?.appendingPathComponent($0) ?? URL(fileURLWithPath: $0) }.flatMap { exists($0) ? $0 : nil }
        var line = stored.parts.map { Line(passage: $0) } ?? Line(speaker: stored.speaker, text: stored.text)
        line.state = url != nil ? "Done" : (stored.error != nil && url == nil ? "Failed" : "Pending")
        line.output = url
        line.error = stored.error
        line.cut = stored.cut ?? false
        line.over = stored.over ?? false
        line.slices = stored.slices
        line.score = stored.score
        line.issues = stored.issues
        return line
    }

    private static func stored(_ line: Line, path: String?) -> StoredLine {
        StoredLine(speaker: line.speaker, text: line.text, path: path, error: line.error, parts: line.parts,
                   cut: line.cut ? true : nil, over: line.over ? true : nil, slices: line.slices,
                   score: line.score, issues: line.issues)
    }

    private func save() {
        guard !restoring else { return }
        let draft = Saved(script: script, assignments: assignments, gapMs: gapMs, room: room,
                          lines: lines.map { Self.stored($0, path: $0.output?.path) },
                          master: masterURL?.path, sceneID: sceneID, sceneName: sceneName,
                          engine: engine, designRefs: designRefs.mapValues(\.path), clips: clips, tracks: tracks, markers: markers)
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// `NAME: line` blocks; unlabelled lines continue the previous speaker (mirrors studio_tools.parse_cast).
    static func parse(_ script: String) -> [(speaker: String, text: String)] {
        let pattern = try! NSRegularExpression(pattern: #"^\s*([A-Za-z][A-Za-z0-9 .'’-]{0,30}?)\s*:\s*(.*)$"#)
        var lines: [(speaker: String, text: String)] = []
        for raw in script.components(separatedBy: .newlines) where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let ns = raw as NSString
            if let m = pattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1)).split(separator: " ").joined(separator: " ").uppercased()
                lines.append((name, ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)))
            } else if !lines.isEmpty {
                lines[lines.count - 1].text = (lines[lines.count - 1].text + " " + raw.trimmingCharacters(in: .whitespaces))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(("NARRATOR", raw.trimmingCharacters(in: .whitespaces)))
            }
        }
        return lines.filter { !$0.text.isEmpty }
    }

    var parsed: [(speaker: String, text: String)] { Self.parse(script) }

    /// Interruption marks: a line ending "--" (or "—") is cut off by the next speaker; a line
    /// starting ">>" talks over the previous one. Marks never reach the voice engine.
    nonisolated static func cue(_ raw: String) -> (text: String, cut: Bool, over: Bool) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var over = false, cut = false
        if text.hasPrefix(">>") {
            over = true
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        for mark in ["--", "—", "–"] where text.hasSuffix(mark) {
            cut = true
            text = String(text.dropLast(mark.count)).trimmingCharacters(in: .whitespaces) + "—"
            break
        }
        return (text, cut, over)
    }

    var cues: [Part] {
        parsed.map { line in
            let c = Self.cue(line.text)
            return Part(speaker: line.speaker, text: c.text, cut: c.cut ? true : nil, over: c.over ? true : nil)
        }
    }

    var speakers: [String] {
        var seen: [String] = []
        for line in parsed where !seen.contains(line.speaker) { seen.append(line.speaker) }
        return seen
    }

    func voiceName(for speaker: String, model: AppModel) -> String? {
        guard let value = assignments[speaker] else { return nil }
        if value.hasPrefix("voice:"), let voice = savedVoice(value, model: model) { return voice.name }
        if value.hasPrefix("design:") { return String(value.dropFirst(7)) }
        return nil
    }

    func savedVoice(_ value: String?, model: AppModel) -> AppModel.SavedVoice? {
        guard let value, value.hasPrefix("voice:"), let id = UUID(uuidString: String(value.dropFirst(6))) else { return nil }
        return model.savedVoices.first { $0.id == id }
    }

    var unassigned: [String] { speakers.filter { assignments[$0] == nil } }

    /// Lines with no audio yet: failed, stopped before they were reached, or never rendered.
    var missing: [Int] { lines.indices.filter { lines[$0].output == nil } }
    var failedCount: Int { lines.filter { $0.state == "Failed" }.count }

    func canRender(_ model: AppModel) -> Bool {
        model.modelReady && !model.busy && !busy && !parsed.isEmpty
            && speakers.allSatisfy { voiceName(for: $0, model: model) != nil }
            && (engine != "moss" || mossStatus?.available == true)
    }

    /// Consecutive lines grouped into passages MOSS renders in one pass.
    nonisolated static func passages(_ lines: [(speaker: String, text: String)]) -> [[Part]] {
        passages(lines.map { Part(speaker: $0.speaker, text: $0.text) })
    }

    nonisolated static func passages(_ lines: [Part]) -> [[Part]] {
        var result: [[Part]] = []
        var current: [Part] = []
        func fits(_ line: Part) -> Bool {
            let speakers = Set(current.map(\.speaker) + [line.speaker])
            let chars = current.reduce(0) { $0 + $1.text.count } + line.text.count
            return current.count < passageLines && chars <= passageChars && speakers.count <= passageSpeakers
        }
        for line in lines {
            if !current.isEmpty && !fits(line) { result.append(current); current = [] }
            current.append(line)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func refreshEngines() {
        Task {
            guard let url = URL(string: StudioAPI.base + "cast/moss/status"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let status = try? JSONDecoder().decode(EngineStatus.self, from: data) else { return }
            mossStatus = status
        }
    }

    func canRetry(_ model: AppModel) -> Bool { model.modelReady && !model.busy && !busy }

    func cancel() { task?.cancel() }

    // MARK: Rendering

    func render(_ model: AppModel) {
        guard canRender(model) else { return }
        let cues = self.cues
        lines = engine == "moss" ? Self.passages(cues).map { Line(passage: $0) }
            : cues.map { Line(speaker: $0.speaker, text: $0.text, cut: $0.cut ?? false, over: $0.over ?? false) }
        clips = []
        masterURL = nil
        run(Array(lines.indices), model: model)
    }

    func retry(_ index: Int, model: AppModel) {
        guard lines.indices.contains(index) else { return }
        run([index], model: model)
    }

    /// Renders every line still missing audio, then joins the scene.
    func retryMissing(_ model: AppModel) { run(missing, model: model) }

    /// Joins the rendered lines again, e.g. after changing the room or gap.
    func rejoin(_ model: AppModel) {
        guard canRetry(model), !lines.isEmpty, missing.isEmpty else { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            let joined = await assemble(model)
            if sceneID != nil { saveScene(announce: false) }
            if joined { autoPlayMaster(model) }
        }
    }

    /// Renders the given lines in order. A failing line is tried once more, then marked and
    /// skipped so the rest of the scene still renders; Retry Failed picks up what's left.
    private func run(_ indices: [Int], model: AppModel) {
        guard !indices.isEmpty, canRetry(model) else { return }
        busy = true
        model.isGenerating = true
        progress = 0
        task = Task {
            defer { busy = false; model.isGenerating = false; task = nil }
            var locked = anchors(excluding: Set(indices))
            for (step, index) in indices.enumerated() {
                if Task.isCancelled { break }
                let unit = lines[index].parts == nil ? "Line" : "Passage"
                status = "\(unit) \(index + 1) of \(lines.count) · \(lines[index].speaker)"
                lines[index].state = "Rendering"
                lines[index].error = nil
                lines[index].score = nil
                lines[index].issues = nil
                var failure: String?
                for attempt in 1...2 {
                    if attempt > 1 { status = "\(unit) \(index + 1) of \(lines.count) · trying again" }
                    do {
                        lines[index].output = try await renderLine(index, model: model, locked: &locked)
                        failure = nil
                        break
                    } catch {
                        if Task.isCancelled { break }
                        failure = error.localizedDescription
                    }
                }
                if Task.isCancelled {
                    lines[index].state = lines[index].output == nil ? "Pending" : "Done"
                    break
                }
                if let failure {
                    // A failed retry never throws away the line's previous good audio.
                    lines[index].state = lines[index].output == nil ? "Failed" : "Done"
                    lines[index].error = lines[index].output == nil ? failure : "Retry failed, kept the previous take: \(failure)"
                } else {
                    lines[index].state = "Done"
                    if lines[index].parts == nil {
                        status = "Checking line \(index + 1)"
                        await checkUnit(index)
                    }
                }
                progress = Double(step + 1) / Double(indices.count + 1)
            }
            var joined = false
            if Task.isCancelled {
                status = missing.isEmpty ? "Stopped" : "Stopped · \(missing.count) of \(lines.count) lines left"
            } else if missing.isEmpty {
                if clips.isEmpty || indices.count == lines.count { layoutAll() } else { indices.forEach(rippleUnit) }
                markBaseline()
                joined = await assemble(model)
            } else {
                let failed = failedCount
                let unit = lines.first?.parts == nil ? (failed == 1 ? "line" : "lines") : (failed == 1 ? "passage" : "passages")
                status = "\(failed) of \(lines.count) \(unit) failed · Retry Failed to finish the scene"
            }
            if sceneID != nil { saveScene(announce: false) }
            if joined { autoPlayMaster(model) }
        }
    }

    /// Designed voices lock to their first rendered line. Lines being re-rendered can't anchor themselves.
    private func anchors(excluding: Set<Int>) -> [String: (URL, String)] {
        var locked: [String: (URL, String)] = [:]
        for index in lines.indices where !excluding.contains(index) {
            let line = lines[index]
            guard line.parts == nil, let url = line.output, locked[line.speaker] == nil,
                  assignments[line.speaker]?.hasPrefix("design:") == true else { continue }
            locked[line.speaker] = (url, line.text)
        }
        return locked
    }

    private func renderLine(_ index: Int, model: AppModel, locked: inout [String: (URL, String)]) async throws -> URL {
        if let parts = lines[index].parts { return try await renderPassage(index, parts: parts, model: model) }
        let line = lines[index]
        let value = assignments[line.speaker] ?? ""
        let rules = model.clonePronunciationRules
        func fields(instruct: String = "") throws -> [String: String] {
            guard let f = model.generationFields(text: line.text, pronunciations: rules, language: model.cloneLanguage,
                                                 instruct: instruct, matchInsideWords: model.cloneMatchInsideWords,
                                                 allowDuration: false, checkReference: false) else {
                throw StudioAPI.Failure(message: model.errorMessage ?? "Invalid line.")
            }
            return f
        }
        if let voice = savedVoice(value, model: model) {
            var f = try fields()
            f["ref_text"] = voice.transcript
            let path = try StudioAPI.outputPath(try await StudioAPI.post("generate-clone", fields: f, files: [("ref_audio", voice.url)]))
            return URL(fileURLWithPath: path)
        }
        guard value.hasPrefix("design:"),
              let instruct = Self.designedVoices.first(where: { $0.0 == String(value.dropFirst(7)) })?.1 else {
            throw StudioAPI.Failure(message: "\(line.speaker) has no voice.")
        }
        if let entry = locked[line.speaker] {
            let (reference, transcript) = entry
            // The designed voice locks to its first line: clone from it for consistency.
            var f = try fields()
            f["ref_text"] = transcript
            let path = try StudioAPI.outputPath(try await StudioAPI.post("generate-clone", fields: f, files: [("ref_audio", reference)]))
            return URL(fileURLWithPath: path)
        }
        let path = try StudioAPI.outputPath(try await StudioAPI.post("generate-design", fields: try fields(instruct: instruct)))
        let url = URL(fileURLWithPath: path)
        locked[line.speaker] = (url, line.text)
        return url
    }

    /// One Together passage: every speaker's voice goes to MOSS-TTSD, which performs the lines as one exchange.
    /// The backend transcribes the take and renders it again once if it was misheard.
    private func renderPassage(_ index: Int, parts: [Part], model: AppModel) async throws -> URL {
        var order: [String] = []
        for part in parts where !order.contains(part.speaker) { order.append(part.speaker) }
        var files: [(String, URL)] = []
        for (number, speaker) in order.enumerated() {
            files.append(("ref_\(number + 1)", try await reference(for: speaker, model: model)))
        }
        let lineList = String(data: try JSONSerialization.data(withJSONObject: parts.map { ["speaker": $0.speaker, "text": $0.text] }),
                              encoding: .utf8)!
        let data = try await StudioAPI.post("cast/moss", fields: ["lines": lineList, "seed": String(Int.random(in: 0..<1_000_000))],
                                            files: files)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["output"] as? String else {
            throw StudioAPI.Failure(message: "MOSS-TTSD returned an unreadable response.")
        }
        let score = json["score"] as? Int ?? 100
        if let segments = json["segments"] as? [[Double]], segments.count == parts.count { lines[index].slices = segments }
        lines[index].score = score
        lines[index].issues = Self.issues(json["words"] as? [[String: Any]] ?? [])
        if score < 90 {
            lines[index].error = "Check \(score)/100: some words may be off. Listen, or render this passage again."
        }
        return URL(fileURLWithPath: path)
    }

    static let voiceSampleText = "Honestly, I didn't think it would turn out like this. But you know what? "
        + "Sometimes the best things happen when you least expect them, and that's exactly what happened today."

    /// The recording MOSS clones for a speaker: a clean OmniVoice sample of the saved or designed voice.
    private func reference(for speaker: String, model: AppModel) async throws -> URL {
        let value = assignments[speaker] ?? ""
        let key = "\(speaker)|\(value)"
        if let url = designRefs[key], Self.exists(url) { return url }
        let voice = savedVoice(value, model: model)
        let instruct = Self.designedVoices.first(where: { "design:" + $0.0 == value })?.1
        guard voice != nil || instruct != nil else { throw StudioAPI.Failure(message: "\(speaker) has no voice.") }
        status = "Preparing \(speaker)'s voice"
        guard var fields = model.generationFields(
            text: Self.voiceSampleText, pronunciations: "", language: "English", instruct: instruct ?? "",
            matchInsideWords: false, allowDuration: false, checkReference: false) else {
            throw StudioAPI.Failure(message: model.errorMessage ?? "Could not prepare \(speaker)'s voice.")
        }
        let data: Data
        if let voice {
            fields["ref_text"] = voice.transcript
            data = try await StudioAPI.post("generate-clone", fields: fields, files: [("ref_audio", voice.url)])
        } else {
            data = try await StudioAPI.post("generate-design", fields: fields)
        }
        let url = URL(fileURLWithPath: try StudioAPI.outputPath(data))
        designRefs[key] = url
        return url
    }

    /// Mixes the timeline into the master. Renders record the master as a take; timeline edits
    /// (`record: false`) replace their own previous edit master instead of filling Takes.
    @discardableResult
    private func assemble(_ model: AppModel, record: Bool = true) async -> Bool {
        guard !lines.isEmpty, missing.isEmpty else { return false }
        if Set(clips.map(\.unit)) != Set(lines.indices) { layoutAll() }
        guard !clips.isEmpty else {
            status = "Could not read the rendered lines to lay out the timeline"
            return false
        }
        mixing = true
        defer { mixing = false }
        status = record ? "Mixing \(clips.count) clips" : "Updating the mix"
        do {
            let path = try StudioAPI.outputPath(try await StudioAPI.post("cast/mix", fields: [
                "clips": try Self.json(mixClips()), "room": room]))
            let previous = masterURL, previousWasEdit = masterIsEdit
            masterURL = URL(fileURLWithPath: path)
            masterIsEdit = !record
            if previousWasEdit, let previous, !previous.path.hasPrefix(scenesRoot.path) {
                try? FileManager.default.removeItem(at: previous)
            }
            progress = 1
            status = "Scene ready · \(clips.count) lines, \(Set(clips.map(\.lane)).count) voices"
            if record { model.recordTake(path: path, text: script, mode: "Cast") }
            return true
        } catch {
            status = "Could not mix the scene: \(error.localizedDescription)"
            return false
        }
    }

    private static func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    /// Plays the master the Scene panel shows. Called after any save, which moves the master
    /// into the scene folder; playing the old path left the Master waveform standing still.
    private func autoPlayMaster(_ model: AppModel) {
        guard model.autoPlay, let master = masterURL, !model.outputPlayer.isPlaying(master) else { return }
        model.outputPlayer.toggle(master)
    }

    // MARK: Scenes in the Library

    var defaultSceneName: String {
        let first = parsed.first?.text ?? lines.first?.text ?? "Untitled scene"
        return first.count > 40 ? String(first.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    func folder(for id: UUID) -> URL { scenesRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    func loadScenes() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: scenesRoot, includingPropertiesForKeys: nil)) ?? []
        scenes = dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("scene.json"))).flatMap { try? JSONDecoder().decode(Scene.self, from: $0) }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Writes the current scene (script, voices, room and every rendered line) to its Library folder.
    /// `asNew` keeps the opened scene untouched and saves a copy.
    @discardableResult
    func saveScene(asNew: Bool = false, announce: Bool = true) -> Bool {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !lines.isEmpty else {
            status = "Write a scene before saving it"
            return false
        }
        let fm = FileManager.default
        let id = asNew ? UUID() : (sceneID ?? UUID())
        let folder = folder(for: id)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var keep: Set<String> = ["scene.json"]
            func adopt(_ url: URL?) throws -> String? {
                guard let url, Self.exists(url) else { return nil }
                let name = url.lastPathComponent
                let destination = folder.appendingPathComponent(name)
                if url.standardizedFileURL != destination.standardizedFileURL, !Self.exists(destination) {
                    try fm.copyItem(at: url, to: destination)
                }
                keep.insert(name)
                return name
            }
            var stored: [StoredLine] = []
            var adopted = lines
            for index in adopted.indices {
                let name = try adopt(adopted[index].output)
                if let name { adopted[index].output = folder.appendingPathComponent(name) }
                stored.append(Self.stored(adopted[index], path: name))
            }
            let masterName = try adopt(masterURL)
            var refNames: [String: String] = [:]
            for (key, url) in designRefs { if let name = try adopt(url) { refNames[key] = name } }
            let now = Date()
            let name = sceneName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultSceneName : sceneName
            let scene = Scene(id: id, name: name, script: script, assignments: assignments, gapMs: gapMs, room: room,
                              lines: stored, master: masterName,
                              createdAt: scenes.first { $0.id == id }?.createdAt ?? now, updatedAt: now,
                              engine: engine, designRefs: refNames, clips: clips, tracks: tracks, markers: markers)
            try JSONEncoder().encode(scene).write(to: folder.appendingPathComponent("scene.json"), options: .atomic)
            // Drop superseded line files (e.g. a line that was rendered again).
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !keep.contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
            lines = adopted
            if let masterName { masterURL = folder.appendingPathComponent(masterName) }
            designRefs = refNames.mapValues { folder.appendingPathComponent($0) }
            sceneID = id
            sceneName = name
            loadScenes()
            if announce { status = "Saved “\(name)” to Scenes" }
            return true
        } catch {
            status = "Could not save the scene: \(error.localizedDescription)"
            return false
        }
    }

    func openScene(_ scene: Scene) {
        guard !busy else { return }
        let folder = folder(for: scene.id)
        script = scene.script
        assignments = scene.assignments
        gapMs = scene.gapMs
        room = Self.rooms.contains { $0.id == scene.room } ? scene.room : "room"
        engine = scene.engine.flatMap { e in Self.engines.contains { $0.id == e } ? e : nil } ?? "lines"
        designRefs = (scene.designRefs ?? [:]).mapValues { folder.appendingPathComponent($0) }.filter { Self.exists($0.value) }
        lines = scene.lines.map { Self.line($0, folder: folder) }
        clips = (scene.clips ?? []).filter { $0.unit < lines.count }
        tracks = scene.tracks ?? Tracks()
        markers = scene.markers ?? []
        if clips.isEmpty && missing.isEmpty && !lines.isEmpty { layoutAll() }
        markBaseline()
        masterURL = scene.master.map { folder.appendingPathComponent($0) }.flatMap { Self.exists($0) ? $0 : nil }
        sceneID = scene.id
        sceneName = scene.name
        progress = masterURL == nil ? 0 : 1
        status = missing.isEmpty ? "Opened “\(scene.name)”" : "Opened “\(scene.name)” · \(missing.count) lines still need audio"
    }

    func renameScene(_ scene: Scene, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var renamed = scene
        renamed.name = trimmed
        guard let data = try? JSONEncoder().encode(renamed) else { return }
        try? data.write(to: folder(for: scene.id).appendingPathComponent("scene.json"), options: .atomic)
        if sceneID == scene.id { sceneName = trimmed }
        loadScenes()
    }

    func deleteScene(_ scene: Scene) {
        guard !(busy && sceneID == scene.id) else { return }
        try? FileManager.default.removeItem(at: folder(for: scene.id))
        if sceneID == scene.id {
            sceneID = nil
            // The open lines lived in the deleted folder.
            lines = lines.map { line in
                var reset = line
                reset.output = nil; reset.state = "Pending"; reset.error = nil
                return reset
            }
            clips = []
            masterURL = nil
        }
        loadScenes()
    }

    /// Clears the page for a new scene. The previous one stays in the Library if it was saved.
    func newScene() {
        guard !busy else { return }
        script = ""
        lines = []
        clips = []
        tracks = Tracks()
        markers = []
        masterURL = nil
        sceneID = nil
        sceneName = ""
        designRefs = [:]
        progress = 0
        status = ""
    }
}

// MARK: - Cast timeline

extension CastStore {
    /// One line on the timeline: a slice of a rendered unit's audio, placed on its speaker's lane.
    struct Clip: Codable, Identifiable, Equatable {
        var id = UUID()
        var unit: Int            // index into lines
        var part: Int            // index within a Together passage (0 for a single line)
        var lane: String
        var text: String
        var srcIn: Double        // seconds into the unit's audio
        var srcOut: Double
        var start: Double        // seconds on the timeline
        var gainDb: Double = 0
        var cut = false          // cut off by the next line
        var over = false         // talks over the previous line
        var fadeIn: Double? = nil    // seconds; optional so older saved timelines still load
        var fadeOut: Double? = nil
        var length: Double { srcOut - srcIn }
        var end: Double { start + length }
    }

    nonisolated static let cutOverlap = 0.25, overLead = 0.8, minLead = 0.3

    /// Places units one after another. Lines in a Together passage keep MOSS's own timing;
    /// a cut-off line is overlapped by the next one, a ">>" line comes in before the previous ends.
    nonisolated static func layout(_ units: [[Clip]], gap: Double) -> [Clip] {
        var out: [Clip] = []
        for unit in units {
            for (k, var clip) in unit.enumerated() {
                if let prev = out.last {
                    var start = k == 0 ? prev.end + gap : prev.start + (clip.srcIn - unit[k - 1].srcIn)
                    if clip.over {
                        start = min(start, max(prev.start + minLead, prev.end - overLead))
                    } else if prev.cut {
                        start = min(start, max(prev.start + minLead, prev.end - cutOverlap))
                    }
                    clip.start = max(0, start)
                } else {
                    clip.start = 0
                }
                out.append(clip)
            }
        }
        return out
    }

    /// Splits a passage by text length when Whisper timings aren't available.
    nonisolated static func proportionalSlices(_ texts: [String], _ duration: Double) -> [[Double]] {
        let weights = texts.map { Double(max(1, $0.count)) }, total = weights.reduce(0, +)
        var t = 0.0
        return weights.map { w in
            defer { t += duration * w / total }
            return [t, t + duration * w / total]
        }
    }

    func unitDuration(_ index: Int) -> Double? {
        guard lines.indices.contains(index), let url = lines[index].output else { return nil }
        if let known = durations[url] { return known }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        durations[url] = seconds
        return seconds
    }

    /// A unit's clips at unit-relative times (start == srcIn).
    private func unitClips(_ index: Int) -> [Clip]? {
        guard let duration = unitDuration(index) else { return nil }
        let line = lines[index]
        guard let parts = line.parts else {
            return [Clip(unit: index, part: 0, lane: line.speaker, text: line.text, srcIn: 0, srcOut: duration,
                         start: 0, cut: line.cut, over: line.over)]
        }
        let slices = line.slices?.count == parts.count ? line.slices! : Self.proportionalSlices(parts.map(\.text), duration)
        return parts.indices.map { i in
            let a = min(max(0, slices[i][0]), duration - 0.05)
            return Clip(unit: index, part: i, lane: parts[i].speaker, text: parts[i].text, srcIn: a,
                        srcOut: max(a + 0.05, min(duration, slices[i][1])), start: a,
                        cut: parts[i].cut ?? false, over: parts[i].over ?? false)
        }
    }

    /// Lays the whole scene out from the script again, discarding timeline edits.
    func layoutAll() {
        var units: [[Clip]] = []
        for index in lines.indices {
            guard let unit = unitClips(index) else { clips = []; return }
            units.append(unit)
        }
        clips = Self.layout(units, gap: gapMs / 1000)
    }

    /// After a unit is rendered again: keep its start, and shift everything after it by the
    /// change in length so gaps and overlaps the user set stay as they were.
    fileprivate func rippleUnit(_ index: Int) {
        let old = clips.filter { $0.unit == index }
        guard let fresh = unitClips(index), let anchor = old.min(by: { $0.start < $1.start }),
              let oldEnd = old.map(\.end).max() else { layoutAll(); return }
        let base = fresh[0].srcIn
        let placed = fresh.map { clip -> Clip in
            var clip = clip
            clip.start = anchor.start + (clip.srcIn - base)
            if let previous = old.first(where: { $0.part == clip.part }) { clip.id = previous.id; clip.gainDb = previous.gainDb }
            return clip
        }
        let delta = (placed.map(\.end).max() ?? oldEnd) - oldEnd
        clips = (clips.filter { $0.unit != index }.map { clip in
            var clip = clip
            if clip.unit > index { clip.start = max(0, clip.start + delta) }
            return clip
        } + placed).sorted { ($0.unit, $0.part) < ($1.unit, $1.part) }
    }

    /// What /cast/mix receives. Cut-offs and talk-overs follow wherever the clips now sit.
    fileprivate func mixClips() -> [[String: Any]] {
        var items: [[String: Any]] = clips.map { clip in
            ["path": lines[clip.unit].output?.path ?? "", "src_in": clip.srcIn, "src_out": clip.srcOut,
             "at": clip.start, "lane": clip.lane, "gain_db": clip.gainDb + (tracks.gain[clip.lane] ?? 0),
             "fade_in": clip.fadeIn ?? 0, "fade_out": clip.fadeOut ?? 0]
        }
        for i in clips.indices.dropFirst() {
            if clips[i].over { items[i - 1]["duck_from"] = clips[i].start }
            if clips[i - 1].cut { items[i - 1]["cut_at"] = clips[i].start + Self.cutOverlap }
        }
        // Mute and solo decide which lanes are heard; at least one clip always goes to the mixer.
        let audible = clips.indices.filter { isAudible(clips[$0].lane) }
        return audible.isEmpty ? [items[0].merging(["gain_db": -96.0]) { $1 }] : audible.map { items[$0] }
    }

    func isAudible(_ lane: String) -> Bool {
        !tracks.muted.contains(lane) && (tracks.soloed.isEmpty || tracks.soloed.contains(lane))
    }

    var timelineDuration: Double { clips.map(\.end).max() ?? 0 }
    var lanes: [String] {
        var seen: [String] = []
        for clip in clips where !seen.contains(clip.lane) { seen.append(clip.lane) }
        return seen
    }

    // MARK: Editing

    /// Live change while dragging: no save, no mix.
    func editClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        liveEdit = true
        var clip = clips[i]
        change(&clip)
        clip.start = max(0, clip.start)
        if let duration = unitDuration(clip.unit) {
            clip.srcIn = min(max(0, clip.srcIn), duration - 0.05)
            clip.srcOut = min(max(clip.srcIn + 0.05, clip.srcOut), duration)
        }
        clips[i] = clip
        liveEdit = false
    }

    /// After an edit: save, then rebuild the master shortly after the last change. Playback
    /// carries on from the same point in the new mix.
    func commitEdit(_ model: AppModel) {
        recordHistory()
        save()
        scheduleRemix(model)
    }

    private func scheduleRemix(_ model: AppModel) {
        remixTask?.cancel()
        remixTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, !busy, !mixing, missing.isEmpty else { return }
            let player = model.outputPlayer
            let loaded = masterURL != nil && player.loadedURL == masterURL
            let playing = masterURL.map { player.isPlaying($0) } ?? false
            let position = masterURL.map { player.currentTime(for: $0) } ?? 0
            guard await assemble(model, record: false) else { return }
            if sceneID != nil { saveScene(announce: false) }
            // The new mix is a new file: carry the playhead over, paused or playing. (While paused
            // it used to vanish, and the next Play started again from the top.)
            if loaded, let master = masterURL {
                player.seek(master, to: position)
                if playing && !player.isPlaying(master) { player.toggle(master) }
            }
        }
    }

    func resetTimeline(_ model: AppModel) {
        guard !busy, missing.isEmpty else { return }
        layoutAll()
        commitEdit(model)
    }

    /// Writes one dry WAV per lane plus the mix into `folder`, named after the scene.
    func exportStems(_ model: AppModel, to folder: URL) async {
        guard !clips.isEmpty, missing.isEmpty else { return }
        mixing = true
        defer { mixing = false }
        status = "Exporting stems"
        do {
            let data = try await StudioAPI.post("cast/mix", fields: ["clips": try Self.json(mixClips()), "room": room, "stems": "true"])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mix = json["output"] as? String, let stems = json["stems"] as? [String: String] else {
                throw StudioAPI.Failure(message: "The engine returned an unreadable response.")
            }
            let base = (sceneName.isEmpty ? defaultSceneName : sceneName).replacingOccurrences(of: "/", with: "-")
            let fm = FileManager.default
            func place(_ source: String, _ label: String) throws {
                let target = folder.appendingPathComponent("\(base) - \(label).wav")
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: URL(fileURLWithPath: source), to: target)
            }
            for lane in lanes { if let path = stems[lane] { try place(path, lane.localizedCapitalized) } }
            try place(mix, "Mix")
            if let temp = json["stems_folder"] as? String { try? fm.removeItem(atPath: temp) }
            status = "Exported \(stems.count) stems and the mix"
            model.reveal(folder)
        } catch {
            status = "Could not export stems: \(error.localizedDescription)"
        }
    }
}


// MARK: - Scene Editor: history, snapping, text edits, checks

extension CastStore {
    struct Snapshot: Equatable { var clips: [Clip]; var tracks: Tracks; var markers: [Marker] }

    /// The timeline as it is now becomes the starting point; earlier history no longer applies
    /// (after a render, re-render or opening a scene the clips point at different audio).
    func markBaseline() {
        baseline = Snapshot(clips: clips, tracks: tracks, markers: markers)
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false; canRedo = false
    }

    fileprivate func recordHistory() {
        let now = Snapshot(clips: clips, tracks: tracks, markers: markers)
        if let baseline, baseline != now {
            undoStack.append(baseline)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        baseline = now
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
    }

    func undo(_ model: AppModel) {
        guard !busy, let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, tracks: tracks, markers: markers))
        restore(previous, model)
    }

    func redo(_ model: AppModel) {
        guard !busy, let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, tracks: tracks, markers: markers))
        restore(next, model)
    }

    private func restore(_ snapshot: Snapshot, _ model: AppModel) {
        clips = snapshot.clips
        tracks = snapshot.tracks
        markers = snapshot.markers
        baseline = snapshot
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        save()
        scheduleRemix(model)
    }

    // MARK: Snapping and the overlap guard

    /// The nearest target within `within`, if any.
    nonisolated static func snap(_ value: Double, to targets: [Double], within: Double) -> Double? {
        guard let best = targets.min(by: { abs($0 - value) < abs($1 - value) }), abs(best - value) <= within else { return nil }
        return best
    }

    /// The closest start for a clip of `length` that overlaps none of `others` on its track.
    nonisolated static func place(_ start: Double, length: Double, among others: [(start: Double, end: Double)]) -> Double? {
        func free(_ s: Double) -> Bool { s >= 0 && others.allSatisfy { s + length <= $0.start + 1e-6 || s >= $0.end - 1e-6 } }
        if free(start) { return start }
        return others.flatMap { [$0.start - length, $0.end] }.filter(free).min { abs($0 - start) < abs($1 - start) }
    }

    /// Where a dragged or nudged clip lands: snapped to other clips' edges and the playhead (unless
    /// `snapping` is off), and never on top of another clip on the same track.
    /// Returns the start and the edge it snapped to, for the guide line.
    func landing(_ id: UUID, proposed: Double, snapping: Bool, playhead: Double?, tolerance: Double) -> (start: Double, guide: Double?) {
        guard let clip = clips.first(where: { $0.id == id }) else { return (proposed, nil) }
        var start = max(0, proposed), guide: Double?
        if snapping {
            let edges = snapEdges(excluding: id, playhead: playhead)
            if let s = Self.snap(start, to: edges, within: tolerance) {
                start = s; guide = s
            } else if let e = Self.snap(start + clip.length, to: edges, within: tolerance) {
                start = e - clip.length; guide = e
            }
        }
        let others = clips.filter { $0.id != id && $0.lane == clip.lane }.map { (start: $0.start, end: $0.end) }
        guard let placed = Self.place(start, length: clip.length, among: others) else { return (clip.start, nil) }
        return (placed, placed == start ? guide : nil)
    }

    /// How far a clip's edges may be trimmed out before touching its neighbours on the same track.
    func trimLimits(_ id: UUID) -> (earliest: Double, latest: Double) {
        guard let clip = clips.first(where: { $0.id == id }) else { return (0, .infinity) }
        let same = clips.filter { $0.id != id && $0.lane == clip.lane }
        return (same.filter { $0.end <= clip.start + 1e-6 }.map(\.end).max() ?? 0,
                same.filter { $0.start >= clip.end - 1e-6 }.map(\.start).min() ?? .infinity)
    }

    /// The edges a trim can snap to.
    func snapEdges(excluding id: UUID, playhead: Double?) -> [Double] {
        var edges: [Double] = [0]
        for clip in clips where clip.id != id { edges.append(clip.start); edges.append(clip.end) }
        if let playhead { edges.append(playhead) }
        return edges
    }

    // MARK: Editing a line's words

    /// The position of a clip's line in the script (counting every spoken line in order).
    func scriptIndex(of clip: Clip) -> Int {
        lines.prefix(clip.unit).reduce(0) { $0 + ($1.parts?.count ?? 1) } + clip.part
    }

    /// Rewrites one spoken line in the script, keeping its speaker as written; any continuation
    /// lines of that entry are folded into it.
    nonisolated static func replacing(line index: Int, in script: String, with text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"^\s*([A-Za-z][A-Za-z0-9 .'’-]{0,30}?)\s*:\s*(.*)$"#)
        var raws = script.components(separatedBy: "\n")
        var parsed = -1, target: Int?, continuation: [Int] = [], labelled = false
        for (i, raw) in raws.enumerated() where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let ns = raw as NSString
            if pattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) != nil {
                parsed += 1
                if parsed == index { target = i; labelled = true } else if parsed > index { break }
            } else if parsed == -1 {
                parsed = 0
                if index == 0 { target = i; labelled = false }
            } else if parsed == index {
                continuation.append(i)
            }
        }
        guard let target else { return script }
        if labelled {
            let raw = raws[target] as NSString
            let m = pattern.firstMatch(in: raws[target], range: NSRange(location: 0, length: raw.length))!
            raws[target] = raw.substring(with: m.range(at: 1)) + ": " + text
        } else {
            raws[target] = text
        }
        for i in continuation.reversed() { raws.remove(at: i) }
        return raws.joined(separator: "\n")
    }

    /// New words for one clip: the script is updated, then the line (or its Together passage)
    /// is rendered again in place. Cut-off and talk-over marks are kept.
    func editText(_ id: UUID, to text: String, model: AppModel) {
        guard canRetry(model), let ci = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[ci]
        var clean = Self.cue(text).text
        guard !clean.isEmpty else { return }
        if clip.cut && !clean.hasSuffix("—") { clean += "—" }
        var marked = clean
        if clip.cut { marked = String(marked.dropLast()).trimmingCharacters(in: .whitespaces) + "--" }
        if clip.over { marked = ">> " + marked }
        script = Self.replacing(line: scriptIndex(of: clip), in: script, with: marked)
        if var parts = lines[clip.unit].parts, parts.indices.contains(clip.part) {
            parts[clip.part].text = clean
            lines[clip.unit].parts = parts
            lines[clip.unit].text = parts.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        } else {
            lines[clip.unit].text = clean
        }
        clips[ci].text = clean
        retry(clip.unit, model: model)
    }

    // MARK: Checking lines with Whisper

    /// Words Whisper heard wrongly or not at all, at their time in the unit's audio.
    nonisolated static func issues(_ words: [[String: Any]]) -> [Issue] {
        var out: [Issue] = []
        var last = 0.0
        for (i, word) in words.enumerated() {
            let t0 = word["t0"] as? Double
            if let t1 = word["t1"] as? Double { last = t1 }
            guard let status = word["status"] as? String, status != "ok" else { continue }
            let t = t0 ?? words[(i + 1)...].lazy.compactMap { $0["t0"] as? Double }.first ?? last
            out.append(Issue(t: t, word: word["text"] as? String ?? "", heard: word["heard"] as? String))
        }
        return out
    }

    /// Transcribes one rendered unit and records the words that came out wrong.
    func checkUnit(_ index: Int) async {
        guard lines.indices.contains(index), let url = lines[index].output else { return }
        let text = lines[index].parts?.map(\.text).joined(separator: " ") ?? lines[index].text
        guard let data = try? await StudioAPI.post("takes/check", fields: ["script": text, "paths": StudioAPI.jsonList([url.path])]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = json["reports"] as? [String: Any],
              let report = reports.values.first as? [String: Any],
              lines.indices.contains(index), lines[index].output == url else { return }
        lines[index].score = report["score"] as? Int
        lines[index].issues = Self.issues(report["words"] as? [[String: Any]] ?? [])
    }

    var unchecked: [Int] { lines.indices.filter { lines[$0].output != nil && lines[$0].score == nil } }

    /// Checks every rendered line that hasn't been checked yet (older scenes, interrupted renders).
    func checkAll(_ model: AppModel) {
        let todo = unchecked
        guard !todo.isEmpty, canRetry(model) else { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            for (n, index) in todo.enumerated() {
                if Task.isCancelled { break }
                status = "Checking \(n + 1) of \(todo.count)"
                await checkUnit(index)
            }
            let flagged = clips.filter { !issues(for: $0).isEmpty }.count
            status = flagged == 0 ? "Every line matches the script" : "\(flagged) \(flagged == 1 ? "line has" : "lines have") words to check"
            if sceneID != nil { saveScene(announce: false) }
        }
    }

    /// The issues that fall inside a clip, at clip-relative seconds.
    func issues(for clip: Clip) -> [Issue] {
        (lines[safe: clip.unit]?.issues ?? []).filter { $0.t >= clip.srcIn - 0.02 && $0.t < clip.srcOut }
            .map { Issue(t: $0.t - clip.srcIn, word: $0.word, heard: $0.heard) }
    }
}


// MARK: - Scene Editor: pace, subtitles, loudness, markers

extension CastStore {
    /// Every gap between one line and the next (in script order) scaled by `factor`; overlaps —
    /// interruptions and talk-overs — keep their exact amount.
    nonisolated static func paced(_ clips: [Clip], factor: Double) -> [Clip] {
        guard var previous = clips.first else { return clips }
        var out = [previous]
        var shift = 0.0
        for var clip in clips.dropFirst() {
            let gap = clip.start - previous.end   // measured on the original positions
            previous = clip
            if gap > 0 { shift += gap * (factor - 1) }
            clip.start = max(0, clip.start + shift)
            out.append(clip)
        }
        return out
    }

    /// Live preview while the Pace slider moves: no history, no mix.
    func previewClips(_ preview: [Clip]) {
        liveEdit = true
        clips = preview
        liveEdit = false
    }

    // MARK: Subtitles

    enum SubtitleFormat: String { case srt, vtt }

    /// One cue per audible clip, in time order, labelled with the speaker. Cut-off lines end
    /// where the next line takes over.
    nonisolated static func subtitles(_ clips: [Clip], format: SubtitleFormat) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
            return String(format: format == .srt ? "%02d:%02d:%02d,%03d" : "%02d:%02d:%02d.%03d", h, m, s, f)
        }
        var ends: [UUID: Double] = [:]
        for (i, clip) in clips.enumerated() {
            ends[clip.id] = clip.end
            if clip.cut, i + 1 < clips.count { ends[clip.id] = min(clip.end, clips[i + 1].start + cutOverlap) }
        }
        let ordered = clips.sorted { $0.start < $1.start }
        var text = format == .vtt ? "WEBVTT\n\n" : ""
        for (n, clip) in ordered.enumerated() {
            let speaker = clip.lane.localizedCapitalized
            let words = clip.text.replacingOccurrences(of: "\n", with: " ")
            if format == .srt { text += "\(n + 1)\n" }
            text += "\(stamp(clip.start)) --> \(stamp(ends[clip.id] ?? clip.end))\n"
            text += format == .srt ? "\(speaker): \(words)\n\n" : "<v \(speaker)>\(words)\n\n"
        }
        return text
    }

    /// Subtitles for what's heard: muted (or un-soloed) tracks are left out.
    func subtitleText(_ format: SubtitleFormat) -> String {
        Self.subtitles(clips.filter { isAudible($0.lane) }, format: format)
    }

    // MARK: Loudness

    static let loudnessTargets: [(name: String, lufs: Double)] = [("Podcast", -16), ("YouTube", -14), ("Broadcast", -23)]

    /// A copy of the master normalised to `lufs`, for export.
    func loudnessCopy(_ lufs: Double) async throws -> URL {
        guard let master = masterURL else { throw StudioAPI.Failure(message: "Mix the scene first.") }
        status = "Matching \(Int(lufs)) LUFS"
        let data = try await StudioAPI.post("audio/loudness", fields: ["path": master.path, "target": String(lufs)])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["output"] as? String else {
            throw StudioAPI.Failure(message: "The engine returned an unreadable response.")
        }
        let before = json["before"] as? Double ?? 0, after = json["after"] as? Double ?? lufs
        status = String(format: "Mix at %.1f LUFS (was %.1f)", after, before)
        return URL(fileURLWithPath: path)
    }

    // MARK: Markers

    func addMarker(at t: Double, _ model: AppModel) {
        markers.append(Marker(t: max(0, t), name: "Marker \(markers.count + 1)"))
        markers.sort { $0.t < $1.t }
        commitEdit(model)
    }

    func renameMarker(_ id: UUID, to name: String, _ model: AppModel) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        markers[i].name = trimmed.isEmpty ? markers[i].name : trimmed
        commitEdit(model)
    }

    func deleteMarker(_ id: UUID, _ model: AppModel) {
        markers.removeAll { $0.id == id }
        commitEdit(model)
    }
}
