import Foundation

extension Phase1Tests {
    static func waitPerformance(_ model: AppModel) {
        let deadline = Date().addingTimeInterval(10)
        while model.performanceBusy && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(!model.performanceBusy,"performance operation completes")
    }
    static func performanceTests(model: AppModel, output: String) throws {
        check(PerformanceDirection.pause(500) == "[pause 500ms]", "Pause chip exact syntax")
        check(PerformanceDirection.pause(1) != nil && PerformanceDirection.pause(10000) != nil, "pause authoring bounds inclusive")
        check(PerformanceDirection.pause(0) == nil && PerformanceDirection.pause(10001) == nil, "out-of-range pause disabled")
        check(PerformanceDirection.pauseInput("500") == "[pause 500ms]", "exact pause text input")
        for input in ["500.5","0","-1","10001","0500","500ms"] {
            check(PerformanceDirection.pauseInput(input) == nil, "malformed duration cannot be rounded or inserted")
        }
        for direction in [PerformanceDirection.pause(500)!,PerformanceDirection.louder,PerformanceDirection.quieter] {
            let inserted=SpeechInsertion.insert(direction,into:"Setup. Line.",selection:NSRange(location:7,length:0))!
            check(inserted.0 == "Setup. " + direction + " Line.","performance chips insert at cursor")
        }
        let id=String(repeating:"a",count:32)
        let settings:[String:Any] = ["speed":1.2,"steps":43,"guidance":2.3,"denoise":false,"t_shift":0.3,
            "position_temperature":7,"class_temperature":0.6,"layer_penalty_factor":4,"language":"en"]
        func segment(_ id:String, outputPath:String? = nil) -> [String:Any] {
            ["id":id,"kind":"speech","state":outputPath == nil ? "pending" : "complete",
             "text":id == "0" ? "[B EY1 S] [laughter]" : "Next.", "seed":id == "0" ? 777 : 778,
             "gain_db":id == "0" ? 0 : 3,"request":settings,"output":outputPath as Any? ?? NSNull(),"last_error":NSNull()]
        }
        let pause:[String:Any] = ["id":"1","kind":"pause","state":"ready","milliseconds":500,"samples":12000]
        var job:[String:Any] = ["id":id,"script":"bass [laughter][pause 500ms][louder]Next.","pronunciations":"bass=[B EY1 S]",
            "pronunciation_mode":"words","voice":["engine":"OmniVoice Zero-Shot","reference_name":"ref.wav","reference_sha256":"abc"],
            "base_seed":777,"revision":0,"segments":[segment("0"),pause,segment("2")],"master":NSNull()]
        CaptureProtocol.routedResponses = ["/performance":[],"/performance/prepare":job]
        model.performanceText=job["script"] as! String
        model.performanceRules="bass=[B EY1 S]"
        model.performanceMatchInsideWords=false
        model.speed=1.2; model.steps=43; model.guidance=2.3; model.denoiseOutput=false
        model.timeShift=0.3; model.positionTemperature=7; model.classTemperature=0.6; model.layerPenaltyFactor=4
        model.generationSeed=0; model.cloneLanguage="English"
        model.useDuration=true; model.targetDuration=7
        model.preparePerformance(); waitPerformance(model)
        let request=CaptureProtocol.captured.last(where:{$0["route"] == "/performance/prepare"})!
        let sent=try JSONDecoder().decode([String:String].self,from:Data(request["settings"]!.utf8))
        check(request["script"] == model.performanceText,"prepare sends raw performance script to dedicated route")
        check(request["engine"] == "OmniVoice Zero-Shot","performance engine boundary")
        check(sent["seed"] == "0" && sent["duration"] == nil,"prepare sends random-base request without native fixed duration")
        check(sent["pronunciations"] == model.performanceRules && sent["pronunciation_mode"] == "words","performance dictionary mode forwarded")
        check(sent["language"] == "English" && sent["denoise"] == "false","performance language/denoise forwarded")
        check(sent["speed"] == "1.2" && sent["steps"] == "43" && sent["guidance"] == "2.3","performance core settings forwarded")
        check(sent["t_shift"] == "0.3" && sent["position_temperature"] == "7.0" && sent["class_temperature"] == "0.6" && sent["layer_penalty_factor"] == "4.0","performance advanced settings forwarded")
        check(model.performanceProduction?.segments.count == 3 && model.performanceProduction?.base_seed == 777,"frozen production and assigned seed decoded")
        let before=CaptureProtocol.captured.count
        job["segments"]=[segment("0",outputPath:output),pause,segment("2",outputPath:output)]
        CaptureProtocol.routedResponses["/performance/\(id)/render/0"]=job
        CaptureProtocol.routedResponses["/performance/\(id)/render/2"]=job
        model.renderPerformance(); waitPerformance(model)
        let renders=CaptureProtocol.captured.dropFirst(before).filter{$0["route"]?.contains("/render/") == true}
        check(renders.count == 2,"render missing sends only speech segments")
        check(!renders.contains{$0["route"]?.hasSuffix("/1") == true},"pause is never synthesized")
        check(model.performanceProduction?.segments[2].seed == 778,"per-segment seed stays saved")
        model.performanceText="Changed draft [quieter] hello."
        model.generationSeed=999; model.steps=8
        let count=CaptureProtocol.captured.count
        model.renderPerformance("2"); waitPerformance(model)
        let retry=Array(CaptureProtocol.captured.dropFirst(count))
        check(retry.count == 1 && retry[0]["route"] == "/performance/\(id)/render/2","retry calls only selected segment")
        check(retry[0].count == 1,"retry sends no mutable draft/settings/seed overrides")
        check(model.performanceProduction?.segments[2].request?.steps == 43,"retry retains frozen settings")
        job["master"]=output
        CaptureProtocol.routedResponses["/performance/\(id)/rebuild"]=job
        let beforeRebuild=CaptureProtocol.captured.count
        model.rebuildPerformance(); waitPerformance(model)
        let rebuild=Array(CaptureProtocol.captured.dropFirst(beforeRebuild))
        check(rebuild.count == 1 && rebuild[0]["route"] == "/performance/\(id)/rebuild","master rebuild has no synthesis requests")
        check(model.performanceProduction?.master == output,"rebuilt master available")
        let complete=CaptureProtocol.captured.count
        model.renderPerformance(); waitPerformance(model)
        check(CaptureProtocol.captured.count == complete,"render missing retains all completed segments")
        CaptureProtocol.routedResponses["/performance/\(id)"]=job
        model.loadPerformance(id); waitPerformance(model)
        check(model.performanceText == job["script"] as? String,"load restores saved production draft")
        check(model.performanceRules == "bass=[B EY1 S]","load restores saved pronunciation rules")
        check(AppSection.allCases.contains(.performance),"dedicated Performance workspace exposed")
        CaptureProtocol.routedResponses.removeAll()
    }
}
