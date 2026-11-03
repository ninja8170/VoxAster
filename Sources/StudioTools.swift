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
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var speaker: String
        var text: String
        var state = "Pending"
        var output: URL?
    }

    struct Saved: Codable { var script: String; var assignments: [String: String]; var gapMs: Double }

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

    @Published var script: String { didSet { save() } }
    @Published var assignments: [String: String] { didSet { save() } }
    @Published var gapMs: Double { didSet { save() } }
    @Published private(set) var lines: [Line] = []
    @Published private(set) var masterURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    private var task: Task<Void, Never>?

    private let file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OmniVoice/cast.json")

    init() {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        script = saved?.script ?? ""
        assignments = saved?.assignments ?? [:]
        gapMs = saved?.gapMs ?? 350
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(script: script, assignments: assignments, gapMs: gapMs)) else { return }
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

    func canRender(_ model: AppModel) -> Bool {
        model.modelReady && !model.busy && !busy && !parsed.isEmpty
            && speakers.allSatisfy { voiceName(for: $0, model: model) != nil }
    }

    func cancel() { task?.cancel() }

    func render(_ model: AppModel) {
        guard canRender(model) else { return }
        lines = parsed.map { Line(speaker: $0.speaker, text: $0.text) }
        masterURL = nil
        busy = true
        model.isGenerating = true
        progress = 0
        task = Task {
            defer { busy = false; model.isGenerating = false; task = nil }
            var locked: [String: (URL, String)] = [:]   // designed speaker → first line audio + its text
            for index in lines.indices {
                if Task.isCancelled { status = "Stopped"; return }
                status = "Line \(index + 1) of \(lines.count) · \(lines[index].speaker)"
                lines[index].state = "Rendering"
                do {
                    let url = try await renderLine(index, model: model, locked: &locked)
                    lines[index].output = url
                    lines[index].state = "Done"
                } catch {
                    lines[index].state = "Failed"
                    status = "Line \(index + 1) failed: \(error.localizedDescription)"
                    return
                }
                progress = Double(index + 1) / Double(lines.count + 1)
            }
            await assemble(model)
        }
    }

    func retry(_ index: Int, model: AppModel) {
        guard lines.indices.contains(index), !busy, !model.busy else { return }
        busy = true
        model.isGenerating = true
        lines[index].state = "Rendering"
        task = Task {
            defer { busy = false; model.isGenerating = false; task = nil }
            var locked: [String: (URL, String)] = [:]
            if let first = lines.firstIndex(where: { $0.speaker == lines[index].speaker && $0.output != nil }), first != index,
               assignments[lines[index].speaker]?.hasPrefix("design:") == true, let url = lines[first].output {
                locked[lines[index].speaker] = (url, lines[first].text)
            }
            do {
                lines[index].output = try await renderLine(index, model: model, locked: &locked)
                lines[index].state = "Done"
                if lines.allSatisfy({ $0.output != nil }) { await assemble(model) }
            } catch {
                lines[index].state = "Failed"
                status = error.localizedDescription
            }
        }
    }

    private func renderLine(_ index: Int, model: AppModel, locked: inout [String: (URL, String)]) async throws -> URL {
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

    private func assemble(_ model: AppModel) async {
        let paths = lines.compactMap { $0.output?.path }
        guard paths.count == lines.count else { return }
        status = "Joining \(paths.count) lines"
        do {
            let path = try StudioAPI.outputPath(try await StudioAPI.post("cast/assemble", fields: [
                "paths": StudioAPI.jsonList(paths), "gap_ms": String(Int(gapMs))]))
            masterURL = URL(fileURLWithPath: path)
            progress = 1
            status = "Scene ready · \(lines.count) lines, \(speakers.count) voices"
            model.recordTake(path: path, text: script, mode: "Cast")
            if model.autoPlay { model.outputPlayer.toggle(URL(fileURLWithPath: path)) }
        } catch {
            status = "Could not join the scene: \(error.localizedDescription)"
        }
    }
}
