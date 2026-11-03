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
            return "Performance requires the VoxAster 3.8.2 backend. Close the older app/backend, reopen this build, and wait for Ready."
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
                message = "The Performance API is unavailable on the backend at port 8011. Close any older app/backend, reopen VoxAster 3.8.2, and wait for Ready."
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

/// "2026-09-11T02:23:50.025740+00:00" → "11 Sep 2026, 03:23" in the user's locale.
func prettyTimestamp(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = parser.date(from: iso)
    if date == nil {
        // Python emits microseconds; trim to milliseconds for ISO8601DateFormatter.
        let trimmed = iso.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        date = parser.date(from: trimmed)
    }
    guard let date else { return iso }
    return date.formatted(date: .abbreviated, time: .shortened)
}
