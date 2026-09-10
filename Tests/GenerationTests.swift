import Foundation

final class CaptureProtocol: URLProtocol {
    static var captured: [[String: String]] = []
    static var response: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                data.append(contentsOf: bytes.prefix(n))
            }
            stream.close()
        }
        let body = String(decoding: data, as: UTF8.self)
        let boundary = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=").last!
        var fields = ["route": request.url!.path]
        for part in body.components(separatedBy: "--" + boundary) {
            guard let begin = part.range(of: "name=\""), let end = part[begin.upperBound...].firstIndex(of: "\""),
                  let separator = part.range(of: "\r\n\r\n") else { continue }
            let name = String(part[begin.upperBound..<end])
            var value = String(part[separator.upperBound...])
            if value.hasSuffix("\r\n") { value.removeLast() }
            fields[name] = value
        }
        Self.captured.append(fields)
        let dataOut = try! JSONSerialization.data(withJSONObject: Self.response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: dataOut)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct Phase1Tests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { fatalError("FAIL: " + label) }
    }
    static func wait(_ model: AppModel) {
        let deadline = Date().addingTimeInterval(10)
        while (model.isGenerating || model.engineLabRunning) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(!model.isGenerating && !model.engineLabRunning, "request completed")
    }
    static func common(_ fields: [String:String]) {
        check(fields["speed"] == "1.23", "Speed forwarded")
        check(fields["steps"] == "43", "Steps forwarded")
        check(fields["guidance"] == "3.1", "Guidance forwarded")
        check(fields["seed"] == "123", "Seed forwarded")
        check(fields["denoise"] == "false", "Denoise forwarded")
        check(fields["ref_text"] == "Reference transcript.", "reference forwarded")
    }
    static func main() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-ui-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("ref.wav")
        try Data("reference".utf8).write(to: reference)
        let output = root.appendingPathComponent("output.wav").path
        let model = AppModel(startServices: false, storageRoot: root, session: session)
        model.modelReady = true
        model.autoPlay = false
        model.referenceURL = reference
        model.referenceText = "Reference transcript."
        model.speed = 1.23; model.steps = 43; model.guidance = 3.1
        model.generationSeed = 123; model.denoiseOutput = false
        model.cloneLanguage = "English"
        model.clonePronunciationRules = "bass=[B EY1 S]"
        model.cloneText = "Clone bass."
        CaptureProtocol.response = ["output": output]
        model.generateClone(); wait(model)
        common(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["language"] == "English", "clone language")
        check(CaptureProtocol.captured.last!["pronunciations"] == model.clonePronunciationRules, "clone pronunciation")

        model.designMode = "Design"; model.designGender = "male"; model.designStyle = "whisper"
        model.generateDesign(); wait(model)
        common(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["instruct"] == "male, whisper", "design attributes")
        check(CaptureProtocol.captured.last!["pronunciations"] == "", "clone rules do not leak to Design")
        check(CaptureProtocol.captured.last!["language"] == "Auto detect", "clone language does not leak to Design")

        CaptureProtocol.response = ["outputs": [output, output]]
        model.generateVariants(); wait(model)
        common(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["pronunciations"] == model.clonePronunciationRules, "variant pronunciation")
        check(CaptureProtocol.captured.last!["language"] == "English", "variant language")

        model.longFormText = "Original."
        model.productionChunks = [.init(text: "First."), .init(text: "Second.")]
        model.updateChunk(1, text: "Edited bass.")
        check(model.longFormText == "First. Edited bass.", "segment edit updates authoritative text")
        model.pronunciationRules = "bass=base"
        CaptureProtocol.response = ["output":output, "chunks":2, "segment_outputs":[output,output]]
        model.generateLongForm(); wait(model)
        let long = CaptureProtocol.captured.last!
        common(long)
        let segments = try JSONDecoder().decode([String].self, from: Data(long["segments"]!.utf8))
        check(segments == ["First.", "Edited bass."], "edited segments sent unchanged")
        check(long["pronunciations"] == "bass=base", "Long Form uses its own rules")
        check(model.productionChunks.allSatisfy { $0.state == "Complete" }, "segment responses recorded")
        check(model.longFormOutputURL != nil, "master produced")

        model.updateChunk(1, text:"Retry edited text.")
        check(model.longFormOutputURL == nil, "edit invalidates old master")
        CaptureProtocol.response = ["output":output, "retry_index":1, "segment_outputs":[output]]
        model.retryChunk(1); wait(model)
        common(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["retry_index"] == "1", "retry calls backend for selected segment")
        check(CaptureProtocol.captured.last!["text"] == "First. Retry edited text.", "retry uses edited source")
        check(model.productionChunks[1].state == "Complete", "retry result recorded")
        check(model.longFormOutputURL == nil, "retry does not claim new master assembly")
        model.longFormText = "New master text."
        check(model.productionChunks.isEmpty, "master edit invalidates stale production list")

        model.engineLabText = "Comparison."
        model.engineLabEngineA = "OmniVoice Zero-Shot"; model.engineLabEngineB = "My Voice"
        CaptureProtocol.response = ["A":output,"B":output,"map":["A":"OmniVoice Zero-Shot","B":"My Voice"]]
        model.runEngineComparison(); wait(model)
        common(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["pronunciations"] == model.clonePronunciationRules, "Omni comparison uses clone pronunciation")
        check(CaptureProtocol.captured.last!["language"] == "English", "Omni comparison language")

        model.referenceAnalysisReady = true
        model.recommendedSpeed = 0.87; model.recommendedSteps = 40
        model.recommendedGuidance = 2.2; model.recommendedDenoise = false
        model.applyReferenceRecommendations()
        model.applyPreset(model.preset) // Exercise the SwiftUI onChange callback.
        check(model.speed == 0.87 && model.steps == 40 && model.guidance == 2.2 && !model.denoiseOutput,
              "analyzer values survive preset callback")
        model.applyPreset("Natural")
        check(model.speed == 1 && model.steps == 32 && model.guidance == 2, "ordinary presets still apply")

        var invalid = GenerationRequest(text: "valid")
        invalid.speed = .nan
        check((try? invalid.fields()) == nil, "invalid settings rejected")
        invalid = GenerationRequest(text:"valid", segments:[""], retryIndex:0)
        check((try? invalid.fields()) == nil, "empty segments rejected")
        print("PASS: \(checks) Swift UI/request assertions across Clone, Design, Variants, Long Form, Retry and Engine Lab")
    }
}
