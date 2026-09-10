import Foundation
import SwiftUI
import AppKit

final class CaptureProtocol: URLProtocol {
    static var captured: [[String: String]] = []
    static var response: [String: Any] = [:]
    static var routedResponses: [String: Any] = [:]
    static var routedStatus: [String: Int] = [:]
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
        let boundary = request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last ?? "no-multipart-body"
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
        let dataOut = try! JSONSerialization.data(withJSONObject: Self.routedResponses[request.url!.path] ?? Self.response)
        let status = Self.routedStatus[request.url!.path] ?? 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
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

        model.analysisBinding = ReferenceAnalysisBinding(identity: model.referenceIdentity!, transcript: model.referenceText, requestID: UUID())
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
        // Native event catalog and the exact insertion path used by toolbar buttons.
        let expected = "laughter sigh confirmation-en question-en question-ah question-oh question-ei question-yi surprise-ah surprise-oh surprise-wa surprise-yo dissatisfaction-hnn".split(separator:" ").map(String.init)
        check(NativeEvent.all.map(\.name) == expected, "all 13 verified events and no sniff")
        check(NativeEvent.all.filter { $0.group == "Question" }.count == 5, "five Question variants")
        check(NativeEvent.all.filter { $0.group == "Surprise" }.count == 4, "four Surprise variants")
        for event in NativeEvent.all {
            check(NativeEvent.isValid(event.token), "manual native token accepted")
            check(!NativeEvent.isValid(event.token.uppercased()), "exact case sensitivity")
            let inserted = SpeechInsertion.insert(event.token, into:"Setup. Punchline.", selection:NSRange(location:7,length:0))!
            check(inserted.0 == "Setup. " + event.token + " Punchline.", "event inserted at cursor, not end")
            check(inserted.1.location == 8 + event.token.utf16.count, "caret follows inserted event")
        }
        let selected = SpeechInsertion.insert("[B EY1 S]", into:"The bass.", selection:NSRange(location:4,length:4))!
        check(selected.0 == "The [B EY1 S].", "selected word replaced with phonemes")
        check(SpeechInsertion.insert("[sigh]", into:"Hi", selection:NSRange(location:0,length:0))!.0 == "[sigh] Hi", "start insertion")
        check(SpeechInsertion.insert("[sigh]", into:"Hi", selection:NSRange(location:2,length:0))!.0 == "Hi [sigh] ", "end insertion")
        check(SpeechInsertion.insert("[sigh]", into:"", selection:NSRange(location:99,length:0))!.0 == "[sigh] ", "stale cursor after Clear is clamped")
        check(SpeechInsertion.insert("[sigh]", into:"😀 hi", selection:NSRange(location:3,length:0))!.0 == "😀 [sigh] hi", "UTF-16 cursor insertion")
        check(SpeechInsertion.insert("[sigh]", into:"😀", selection:NSRange(location:1,length:0)) == nil, "invalid surrogate boundary rejected")
        var boundText = "Setup. Punchline."
        var boundSelection = NSRange(location:0,length:0)
        let editor = CursorTextEditor(text:Binding(get:{boundText},set:{boundText=$0}), selection:Binding(get:{boundSelection},set:{boundSelection=$0}))
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.string = boundText
        textView.setSelectedRange(NSRange(location:7,length:0))
        coordinator.textViewDidChangeSelection(Notification(name:NSTextView.didChangeSelectionNotification,object:textView))
        check(boundSelection.location == 7, "native editor selection reaches toolbar binding")
        textView.string = "Edited."; textView.setSelectedRange(NSRange(location:4,length:0))
        coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:textView))
        check(boundText == "Edited." && boundSelection.location == 4, "native edits update text and cursor")
        check(NativePronunciation.cmuToken(" B   EY1 S ") == "[B EY1 S]", "CMU helper normalizes phoneme spacing")
        for malformed in ["B EY S", "B EY3 S", "b ey1 s", "[B EY1 S]"] {
            check(NativePronunciation.cmuToken(malformed) == nil, "CMU authoring rejects malformed input")
        }
        check(NativePronunciation.pinyinValue("NI3 HAO3") == "NI3 HAO3", "native pinyin authoring")
        for malformed in ["zhe2", "ZHE0", "ZHE6", "ZHE", "[ZHE2]"] {
            check(NativePronunciation.pinyinValue(malformed) == nil, "pinyin authoring validation")
        }

        model.timeShift = 0.3; model.positionTemperature = 7
        model.classTemperature = 0.6; model.layerPenaltyFactor = 4
        model.useDuration = true; model.targetDuration = 2.5
        model.cloneMatchInsideWords = true
        func advanced(_ fields: [String:String], duration: Bool = true) {
            check(fields["t_shift"] == "0.3", "time shift forwarded")
            check(fields["position_temperature"] == "7.0", "position temperature forwarded")
            check(fields["class_temperature"] == "0.6", "class temperature forwarded")
            check(fields["layer_penalty_factor"] == "4.0", "layer penalty forwarded")
            check(fields["duration"] == (duration ? "2.5" : nil), "duration respects route")
        }
        CaptureProtocol.response = ["output":output]
        model.generateClone(); wait(model); advanced(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["pronunciation_mode"] == "substring", "explicit Clone legacy mode")
        model.designPronunciationRules = "bass=base"; model.designMatchInsideWords = false
        model.generateDesign(); wait(model); advanced(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["pronunciations"] == "bass=base", "Design has its own dictionary")
        check(CaptureProtocol.captured.last!["pronunciation_mode"] == "words", "Design does not inherit Clone replacement mode")
        CaptureProtocol.response = ["outputs":[output,output]]
        model.generateVariants(); wait(model); advanced(CaptureProtocol.captured.last!)
        check(CaptureProtocol.captured.last!["pronunciation_mode"] == "substring", "Variants use Clone replacement mode")
        model.longFormMatchInsideWords = true
        model.productionChunks = [.init(text:"Edited production text.")]
        CaptureProtocol.response = ["output":output,"chunks":1,"segment_outputs":[output]]
        model.generateLongForm(); wait(model); advanced(CaptureProtocol.captured.last!, duration:false)
        check(CaptureProtocol.captured.last!["pronunciation_mode"] == "substring", "Long Form mode forwarded")
        CaptureProtocol.response = ["output":output,"retry_index":0,"segment_outputs":[output]]
        model.retryChunk(0); wait(model); advanced(CaptureProtocol.captured.last!, duration:false)
        CaptureProtocol.response = ["A":output,"B":output,"map":["A":"OmniVoice Zero-Shot","B":"My Voice"]]
        model.runEngineComparison(); wait(model); advanced(CaptureProtocol.captured.last!)
        check(model.engineLabSupportsNative, "native controls visible for both Omni engines")
        model.engineLabEngineB = "F5-TTS"
        model.cloneLanguage = "Auto detect"; model.clonePronunciationRules = ""
        check(!model.engineLabSupportsNative, "native controls hidden for mixed F5 comparison")
        model.runEngineComparison(); wait(model)
        let mixed = CaptureProtocol.captured.last!
        check(mixed["duration"] == nil && mixed["t_shift"] == "0.1", "mixed comparison drops hidden advanced selections")
        check(mixed["position_temperature"] == "5.0" && mixed["class_temperature"] == "0.0" && mixed["layer_penalty_factor"] == "5.0", "mixed native decoding defaults")
        check(model.timeShift == 0.3 && model.useDuration, "filtering preserves native user settings")
        model.resetGenerationDefaults()
        model.applyPreset(model.preset)
        check(model.speed == 1 && model.steps == 32 && model.guidance == 2 && model.denoiseOutput && model.generationSeed == 0, "reset restores established defaults")
        check(!model.useDuration && model.timeShift == 0.1 && model.positionTemperature == 5 && model.classTemperature == 0 && model.layerPenaltyFactor == 5, "reset restores native advanced defaults")
        invalid = GenerationRequest(text:"valid"); invalid.duration = .infinity
        check((try? invalid.fields()) == nil, "invalid duration rejected")
        invalid = GenerationRequest(text:"valid"); invalid.timeShift = 0
        check((try? invalid.fields()) == nil, "invalid schedule rejected")
        invalid = GenerationRequest(text:"valid"); invalid.pronunciationMode = "invalid"
        check((try? invalid.fields()) == nil, "invalid replacement mode rejected")
        CaptureProtocol.response = ["text":"base [laughter]", "can_generate":true,
            "issues":[["level":"warning","message":"Example warning"]]]
        var inspection: SpeechInspection?
        var inspectionError: Error?
        Task {
            do { inspection = try await model.inspectSpeech(text:"bass [laughter]", rules:"bass=base", matchMode:"words") }
            catch { inspectionError = error }
        }
        let previewDeadline = Date().addingTimeInterval(10)
        while inspection == nil && inspectionError == nil && Date() < previewDeadline {
            RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        }
        check(inspection?.text == "base [laughter]" && inspection?.can_generate == true, "preview result decoded")
        check(inspection?.issues.first?.level == "warning", "preview warnings available to editor")
        check(CaptureProtocol.captured.last?["route"] == "/preview-speech", "editor uses preview API")
        check(CaptureProtocol.captured.last?["text"] == "bass [laughter]" && CaptureProtocol.captured.last?["pronunciations"] == "bass=base" && CaptureProtocol.captured.last?["pronunciation_mode"] == "words", "preview forwards current text and rule mode")
        try performanceTests(model:model, output:output)
        try reliabilityTests()
        print("PASS: \(checks) Swift UI/request assertions across Clone, Design, Variants, Long Form, Retry, Engine Lab and Performance")
    }
}
