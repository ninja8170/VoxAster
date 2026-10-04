import SwiftUI

struct PerformanceProduction: Decodable, Identifiable {
    struct Voice: Decodable { let engine: String; let reference_name: String; let reference_sha256: String; let resolved_ref_text: String? }
    struct Settings: Decodable {
        let speed: Double; let steps: Int; let guidance: Double; let denoise: Bool
        let t_shift: Double; let position_temperature: Double; let class_temperature: Double; let layer_penalty_factor: Double
        let language: String?
    }
    struct Segment: Decodable, Identifiable {
        let id: String; let kind: String; let state: String
        let text: String?; let milliseconds: Int?; let samples: Int?
        let gain_db: Int?; let seed: Int?; let request: Settings?
        let output: String?; let last_error: String?
    }
    let id: String; let script: String; let pronunciations: String; let pronunciation_mode: String
    let voice: Voice; let base_seed: Int; let revision: Int; let segments: [Segment]
    let master: String?
}
struct PerformanceSummary: Decodable, Identifiable { let id: String; let script: String; let created_at: String }

enum PerformanceDirection {
    static func pause(_ milliseconds: Int) -> String? {
        (1...10_000).contains(milliseconds) ? "[pause \(milliseconds)ms]" : nil
    }
    static func pauseInput(_ input: String) -> String? {
        guard input.range(of:"^[1-9][0-9]{0,4}$",options:.regularExpression) != nil,
              let value = Int(input) else { return nil }
        return pause(value)
    }
    static let louder = "[louder]"
    static let quieter = "[quieter]"
}

extension AppModel {
    private var performanceBackendUnavailableMessage: String {
        if status == "Incompatible backend" {
            return "Performance requires the VoxAster 3.7.0 backend. Close the older app/backend, reopen this build, and wait for Ready."
        }
        return "The OmniVoice model is still loading. Wait for the status to show Ready before preparing a Performance production."
    }

    @MainActor
    func performanceCall<T: Decodable>(_ path: String, fields: [String:String]? = nil,
                                      reference: URL? = nil, post: Bool = false) async throws -> T {
        guard modelReady else {
            throw NSError(domain:"Performance", code:503,
                userInfo:[NSLocalizedDescriptionKey:performanceBackendUnavailableMessage])
        }
        var request = URLRequest(url:URL(string:"http://127.0.0.1:8011/" + path)!)
        request.timeoutInterval = 3600
        if let fields {
            let boundary = UUID().uuidString
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
            var body = Data()
            for (key,value) in fields {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".data(using:.utf8)!)
            }
            if let reference {
                let safeName = reference.lastPathComponent.replacingOccurrences(of:"\"",with:"_").replacingOccurrences(of:"\r",with:"_").replacingOccurrences(of:"\n",with:"_")
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"ref_audio\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using:.utf8)!)
                body.append(try Data(contentsOf:reference)); body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8)); request.httpBody = body
        } else if post { request.httpMethod = "POST" }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message: String
            if statusCode == 404 {
                message = "The Performance API is unavailable on the backend at port 8011. Close any older app/backend, reopen VoxAster 3.7.0, and wait for Ready."
            } else {
                message = detail?["detail"] as? String ?? detail?["error"] as? String ??
                    "Performance request failed with HTTP status \(statusCode)."
            }
            throw NSError(domain:"Performance", code:statusCode,
                userInfo:[NSLocalizedDescriptionKey:message])
        }
        return try JSONDecoder().decode(T.self,from:data)
    }

    func preparePerformance() {
        guard !performanceBusy, !isGenerating, !engineLabRunning else { return }
        guard modelReady else {
            errorMessage = performanceBackendUnavailableMessage
            return
        }
        guard let reference = referenceURL else { return }
        guard let settings = generationFields(text:performanceText, pronunciations:performanceRules,
            language:cloneLanguage, matchInsideWords:performanceMatchInsideWords, allowDuration:false) else { return }
        let script = performanceText
        guard let data = try? JSONSerialization.data(withJSONObject:settings), let json = String(data:data,encoding:.utf8) else { return }
        performanceBusy = true
        Task { @MainActor in
            defer { performanceBusy = false }
            do {
                let job: PerformanceProduction = try await performanceCall("performance/prepare",
                    fields:["script":script,"settings":json,"engine":"OmniVoice Zero-Shot"],reference:reference)
                performanceProduction = job
                performanceStatus = "Prepared. Reference, text, settings and per-segment seeds are frozen."
                refreshPerformances()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func renderPerformance(_ segmentID: String? = nil) {
        guard !performanceBusy, !isGenerating, !engineLabRunning, let snapshot = performanceProduction else { return }
        let selected = snapshot.segments.filter { $0.kind == "speech" && (segmentID == nil ? $0.output == nil : $0.id == segmentID) }
        guard !selected.isEmpty else { performanceStatus = "All speech is retained. Rebuild the master without synthesis."; return }
        performanceBusy = true
        Task { @MainActor in
            defer { performanceBusy = false }
            for segment in selected {
                performanceStatus = "Rendering segment \(segment.id)…"
                do {
                    let job: PerformanceProduction = try await performanceCall("performance/\(snapshot.id)/render/\(segment.id)",post:true)
                    performanceProduction = job
                    if let result = job.segments.first(where:{$0.id == segment.id}), let error = result.last_error {
                        performanceStatus = "Segment \(segment.id) failed: \(error). Earlier successful audio is retained."
                    } else { performanceStatus = "Segment \(segment.id) retained. Rebuild the master when ready." }
                } catch {
                    performanceStatus = "Request failed; reload this production to recover server-retained results."
                    errorMessage = error.localizedDescription
                    break
                }
            }
        }
    }

    func rebuildPerformance() {
        guard !performanceBusy, let snapshot = performanceProduction else { return }
        performanceBusy = true
        Task { @MainActor in
            defer { performanceBusy = false }
            do {
                let job: PerformanceProduction = try await performanceCall("performance/\(snapshot.id)/rebuild",post:true)
                performanceProduction = job
                performanceStatus = "Master rebuilt from retained audio. No speech was regenerated."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func loadPerformance(_ id: String) {
        guard !performanceBusy else { return }
        performanceBusy = true
        Task { @MainActor in
            defer { performanceBusy = false }
            do {
                let job: PerformanceProduction = try await performanceCall("performance/\(id)")
                performanceProduction = job
                performanceText = job.script; performanceRules = job.pronunciations
                performanceMatchInsideWords = job.pronunciation_mode == "substring"
                performanceStatus = "Loaded frozen production. Retry uses its saved reference, settings and seeds."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func refreshPerformances() {
        Task { @MainActor in
            do { performanceHistory = try await performanceCall("performance") }
            catch { performanceStatus = "Saved productions unavailable: \(error.localizedDescription)" }
        }
    }
}

struct PerformanceWorkspace: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing:0) {
            WorkspaceHeader(eyebrow:"App-level timing and loudness",title:"Performance",
                subtitle:"Exact pauses and retained segments. This does not add emotional acting.")
            HStack(alignment:.top,spacing:16) {
                ScrollView {
                    VStack(spacing:14) {
                        ReferenceCard()
                        Card {
                            VStack(alignment:.leading,spacing:10) {
                                Text("Performance script").font(.headline)
                                SpeechEditor(text:$model.performanceText,rules:model.performanceRules,
                                    matchMode:model.performanceMatchInsideWords ? "substring" : "words",minimumHeight:180,performance:true)
                                PronunciationRulesEditor(rules:$model.performanceRules,matchInsideWords:$model.performanceMatchInsideWords)
                                Button("Prepare new production") { model.preparePerformance() }
                                    .disabled(model.performanceBusy || model.isGenerating || model.engineLabRunning || !model.modelReady || model.referenceURL == nil || model.performanceText.isEmpty)
                                if !model.modelReady {
                                    Text(model.status == "Incompatible backend"
                                         ? "Close the older app/backend, reopen this build, and wait for Ready."
                                         : "Performance preparation becomes available when the OmniVoice model finishes loading.")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                Text("Prepare freezes a new production. Editing this draft or global settings never changes retained segments; prepare again to use those edits.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let job = model.performanceProduction {
                            PerformanceProductionCard(job:job)
                        }
                    }.padding(.bottom,20)
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        Card {
                            VStack(alignment:.leading,spacing:12) {
                                Text("Next production settings").font(.headline)
                                Text("Engine: OmniVoice Zero-Shot reference clone. Uses the current reference recording and transcript.").font(.caption)
                                Picker("Language",selection:$model.cloneLanguage) {
                                    ForEach(["Auto detect","English","French","Spanish","German","Italian","Portuguese","Dutch","Polish","Russian","Arabic","Hindi","Japanese","Korean","Chinese"],id:\.self) { Text($0).tag($0) }
                                }
                                SliderRow(title:"Speed",value:$model.speed,range:0.5...1.5,display:String(format:"%.2f",model.speed))
                                SliderRow(title:"Steps",value:$model.steps,range:8...64,display:"\(Int(model.steps))")
                                SliderRow(title:"Guidance",value:$model.guidance,range:0...4,display:String(format:"%.1f",model.guidance))
                                Text("Speed controls pacing; Guidance controls conditioning. Neither controls emotional intensity.").font(.caption2)
                                NativeAdvancedControls(allowDuration:false)
                                Text("Seed 0 chooses and saves one random base seed at Prepare. Retries keep their assigned positive seed.").font(.caption2)
                            }
                        }
                        Card {
                            VStack(alignment:.leading,spacing:8) {
                                Text("Saved productions").font(.headline)
                                Button("Refresh") { model.refreshPerformances() }
                                ForEach(model.performanceHistory) { item in
                                    Button { model.loadPerformance(item.id) } label: {
                                        VStack(alignment:.leading) {
                                            Text(item.script).lineLimit(2)
                                            Text(item.created_at).font(.caption2)
                                        }
                                    }.disabled(model.performanceBusy)
                                }
                            }
                        }
                    }
                }.frame(width:310)
            }.padding(18)
        }.onAppear { model.refreshPerformances() }
    }
}

struct PerformanceProductionCard: View {
    @EnvironmentObject var model: AppModel
    let job: PerformanceProduction
    var body: some View {
        Card {
            VStack(alignment:.leading,spacing:12) {
                Text("Frozen production • \(job.id.prefix(8))").font(.headline)
                Text("\(job.voice.engine) • \(job.voice.reference_name) • reference \(job.voice.reference_sha256.prefix(12)) • base seed \(job.base_seed)")
                    .font(.caption).textSelection(.enabled)
                if let transcript = job.voice.resolved_ref_text {
                    DisclosureGroup("Frozen reference transcript") { Text(transcript).font(.caption).textSelection(.enabled) }
                }
                if job.script != model.performanceText || job.pronunciations != model.performanceRules || job.pronunciation_mode != (model.performanceMatchInsideWords ? "substring" : "words") {
                    Text("The draft differs. These retained segments still belong to the frozen production shown below.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Render missing / failed") { model.renderPerformance() }
                        .disabled(model.performanceBusy || model.isGenerating || model.engineLabRunning || !model.modelReady)
                    Button("Rebuild master") { model.rebuildPerformance() }
                        .disabled(model.performanceBusy || job.segments.contains { $0.kind == "speech" && $0.output == nil })
                    if model.performanceBusy { ProgressView().controlSize(.small) }
                }
                Text(model.performanceStatus).font(.caption)
                ForEach(job.segments) { segment in
                    VStack(alignment:.leading,spacing:6) {
                        if segment.kind == "pause" {
                            Label("Pause \(segment.milliseconds ?? 0) ms • \(segment.samples ?? 0) exact samples",systemImage:"pause.circle")
                                .foregroundStyle(.purple)
                        } else {
                            HStack {
                                Text("Speech \(segment.id) • \(segment.state)").bold()
                                Spacer()
                                Button("Retry only this segment") { model.renderPerformance(segment.id) }
                                    .disabled(model.performanceBusy || model.isGenerating || model.engineLabRunning || !model.modelReady)
                            }
                            Text(segment.text ?? "").textSelection(.enabled)
                            Text("Seed \(segment.seed ?? 0) • gain \(segment.gain_db ?? 0) dB (before common −4 dB headroom)").font(.caption)
                            if let settings = segment.request {
                                DisclosureGroup("Frozen generation settings") {
                                    Text("Speed \(settings.speed), Steps \(settings.steps), Guidance \(settings.guidance), Denoise \(settings.denoise ? "on" : "off"), Language \(settings.language ?? "Auto detect"); t_shift \(settings.t_shift), position temperature \(settings.position_temperature), token temperature \(settings.class_temperature), layer penalty \(settings.layer_penalty_factor)").font(.caption)
                                }
                            }
                            if let error = segment.last_error { Text("Last attempt: \(error)").font(.caption).foregroundStyle(.red) }
                            if let path = segment.output { FullPlayer(url:URL(fileURLWithPath:path),controller:model.outputPlayer) }
                        }
                    }.font(.callout)
                    Divider()
                }
                if let path = job.master {
                    Text("Assembled master").font(.headline)
                    FullPlayer(url:URL(fileURLWithPath:path),controller:model.outputPlayer)
                    Button("Export master WAV") { model.exportOutput(URL(fileURLWithPath:path)) }
                }
                Text("Assembly: mono 24 kHz float WAV. Edge padding below −80 dBFS is removed before 5 ms speech fades; pause nodes are then inserted without trimming or overlap. Louder/Quieter change loudness, not acting.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
