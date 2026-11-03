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
    struct Part: Codable, Equatable { var speaker: String; var text: String }

    /// A rendered unit of the scene: one line (Line by line) or a passage of several lines (Together).
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var speaker: String
        var text: String
        var state = "Pending"
        var output: URL?
        var error: String?
        var parts: [Part]? = nil

        init(speaker: String, text: String, state: String = "Pending", output: URL? = nil, error: String? = nil) {
            self.speaker = speaker; self.text = text; self.state = state; self.output = output; self.error = error
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
    }

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
    static let rooms: [(id: String, name: String)] = [("dry", "Dry"), ("booth", "Booth"), ("room", "Room"), ("large", "Large room")]

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
        return line
    }

    private func save() {
        guard !restoring else { return }
        let draft = Saved(script: script, assignments: assignments, gapMs: gapMs, room: room,
                          lines: lines.map { StoredLine(speaker: $0.speaker, text: $0.text, path: $0.output?.path, error: $0.error, parts: $0.parts) },
                          master: masterURL?.path, sceneID: sceneID, sceneName: sceneName,
                          engine: engine, designRefs: designRefs.mapValues(\.path))
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
        var result: [[Part]] = []
        var current: [Part] = []
        func fits(_ line: (speaker: String, text: String)) -> Bool {
            let speakers = Set(current.map(\.speaker) + [line.speaker])
            let chars = current.reduce(0) { $0 + $1.text.count } + line.text.count
            return current.count < passageLines && chars <= passageChars && speakers.count <= passageSpeakers
        }
        for line in lines {
            if !current.isEmpty && !fits(line) { result.append(current); current = [] }
            current.append(Part(speaker: line.speaker, text: line.text))
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
        lines = engine == "moss" ? Self.passages(parsed).map { Line(passage: $0) }
                                 : parsed.map { Line(speaker: $0.speaker, text: $0.text) }
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
                }
                progress = Double(step + 1) / Double(indices.count + 1)
            }
            var joined = false
            if Task.isCancelled {
                status = missing.isEmpty ? "Stopped" : "Stopped · \(missing.count) of \(lines.count) lines left"
            } else if missing.isEmpty {
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

    /// Joins the scene. Returns true when a new master was made.
    @discardableResult
    private func assemble(_ model: AppModel) async -> Bool {
        let paths = lines.compactMap { $0.output?.path }
        guard paths.count == lines.count else { return false }
        status = "Joining \(paths.count) lines"
        do {
            let path = try StudioAPI.outputPath(try await StudioAPI.post("cast/assemble", fields: [
                "paths": StudioAPI.jsonList(paths), "gap_ms": String(Int(gapMs)), "room": room]))
            masterURL = URL(fileURLWithPath: path)
            progress = 1
            status = "Scene ready · \(lines.count) lines, \(Set(lines.map(\.speaker)).count) voices"
            model.recordTake(path: path, text: script, mode: "Cast")
            return true
        } catch {
            status = "Could not join the scene: \(error.localizedDescription)"
            return false
        }
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
                stored.append(StoredLine(speaker: adopted[index].speaker, text: adopted[index].text, path: name,
                                         error: adopted[index].error, parts: adopted[index].parts))
            }
            let masterName = try adopt(masterURL)
            var refNames: [String: String] = [:]
            for (key, url) in designRefs { if let name = try adopt(url) { refNames[key] = name } }
            let now = Date()
            let name = sceneName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultSceneName : sceneName
            let scene = Scene(id: id, name: name, script: script, assignments: assignments, gapMs: gapMs, room: room,
                              lines: stored, master: masterName,
                              createdAt: scenes.first { $0.id == id }?.createdAt ?? now, updatedAt: now,
                              engine: engine, designRefs: refNames)
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
            masterURL = nil
        }
        loadScenes()
    }

    /// Clears the page for a new scene. The previous one stays in the Library if it was saved.
    func newScene() {
        guard !busy else { return }
        script = ""
        lines = []
        masterURL = nil
        sceneID = nil
        sceneName = ""
        designRefs = [:]
        progress = 0
        status = ""
    }
}
