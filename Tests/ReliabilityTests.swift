import Foundation
import AVFoundation
import AppKit

extension Phase1Tests {
    static func verify(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { let value = try condition(); check(value, label) }
    static func expectFailure(_ label: String, _ action: () throws -> Void) {
        do { try action(); check(false, label + " should fail") }
        catch { check(true, label) }
    }
    static func wave(_ path: URL, amplitude: Float = 0.1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let file = try AVAudioFile(forWriting: path, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        buffer.frameLength = 240
        for i in 0..<240 { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.2) }
        try file.write(from: buffer)
    }
    static func reliabilityTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxaster-p0-swift-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), destination = root.appendingPathComponent("destination.wav")
        try wave(source); try Data("previous destination".utf8).write(to: destination)
        let dropModel = AppModel(startServices: false, storageRoot: root.appendingPathComponent("drop-test"))
        let fileDropProvider = NSItemProvider(object: source as NSURL)
        check(dropModel.acceptDroppedAudio([fileDropProvider]), "file URL drop accepted")
        let validDropDeadline = Date().addingTimeInterval(5)
        while dropModel.referenceURL == nil && Date() < validDropDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        check(dropModel.referenceURL == source, "dropped file is selected through the modern item-provider API")
        check(!dropModel.acceptDroppedAudio([]), "empty audio drop rejected")
        let original = try Data(contentsOf: source), previous = try Data(contentsOf: destination)
        func intact() throws {
            try verify(try Data(contentsOf: source) == original, "export preserves source")
            try verify(try Data(contentsOf: destination) == previous, "failed export preserves existing destination")
            try verify(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".voxaster-export-") }, "export staging cleaned")
        }
        expectFailure("same source/destination") { try SafeFiles.export(source, to: source) }
        let canonical = root.appendingPathComponent("sub/../source.wav")
        expectFailure("canonical path alias") { try SafeFiles.export(source, to: canonical) }
        let symlink = root.appendingPathComponent("source-alias.wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        expectFailure("symlink to source") { try SafeFiles.export(source, to: symlink) }
        let hardlink = root.appendingPathComponent("source-hardlink.wav")
        try FileManager.default.linkItem(at: source, to: hardlink)
        expectFailure("hard link to source") { try SafeFiles.export(source, to: hardlink) }
        try intact()
        expectFailure("temporary copy failure") {
            try SafeFiles.export(source, to: destination, copy: { _, temporary in
                try Data("partial".utf8).write(to: temporary)
                throw ReliabilityError(message: "simulated disk full")
            })
        }
        try intact()
        expectFailure("incomplete copy rejected") {
            try SafeFiles.export(source, to: destination, copy: { _, temporary in try Data("partial".utf8).write(to: temporary) })
        }
        try intact()
        expectFailure("replacement failure") {
            try SafeFiles.export(source, to: destination, replace: { _, _ in throw ReliabilityError(message: "simulated rename permission failure") })
        }
        try intact()
        let directory = root.appendingPathComponent("cannot-replace-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: directory.appendingPathComponent("keep"))
        expectFailure("real filesystem rename failure") { try SafeFiles.export(source, to: directory) }
        check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep").path), "directory preserved on real replacement failure")
        try SafeFiles.export(source, to: destination)
        try verify(try Data(contentsOf: destination) == original, "existing destination replaced completely")
        let fresh = root.appendingPathComponent("fresh.wav")
        try SafeFiles.export(source, to: fresh)
        try verify(try Data(contentsOf: fresh) == original, "new export succeeds")
        let targetAlias = root.appendingPathComponent("target-alias.wav")
        try FileManager.default.createSymbolicLink(at: targetAlias, withDestinationURL: destination)
        try SafeFiles.export(source, to: targetAlias)
        try verify(try Data(contentsOf: destination) == original, "destination symlink target replaced safely")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)
        let storage = root.appendingPathComponent("state")
        let model = AppModel(startServices: false, storageRoot: storage, session: session, recoverDrafts: true)
        model.autoPlay = false
        let second = root.appendingPathComponent("second.wav"); try wave(second, amplitude: 0.2)
        check(model.selectReference(source), "valid imported reference selected")
        let identityA = model.referenceIdentity!
        model.referenceText = "Transcript A"
        check(model.transcriptReferenceID == identityA.id, "manual transcript binds to selected identity")
        CaptureProtocol.routedResponses["/analyze-reference"] = ["quality_score":95,"recommended":["speed":0.8,"steps":40,"guidance":2.3,"denoise":false]]
        model.analyzeReference()
        let stale = model.analysisBinding!
        check(model.selectReference(second), "replacement reference selected")
        check(model.referenceText.isEmpty, "A transcript cleared on B selection")
        check(model.referenceIdentity != identityA, "replacement has explicit distinct identity")
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(!model.referenceAnalysisReady && !model.referenceAnalyzing, "stale analyzer callback does not update B")
        check(!model.analysisIsCurrent(stale), "old response identity rejected")
        let oldSpeed = model.speed
        model.referenceAnalysisReady = true; model.analysisBinding = stale; model.recommendedSpeed = 0.6
        model.applyReferenceRecommendations()
        check(model.speed == oldSpeed && !model.referenceAnalysisReady, "stale recommendations cannot update B settings")
        model.referenceText = "Transcript B"
        model.analyzeReference()
        let analysisDeadline = Date().addingTimeInterval(2)
        while model.referenceAnalyzing && Date() < analysisDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(model.referenceAnalysisReady, "current analyzer result accepted")
        model.applyReferenceRecommendations(); check(model.speed == 0.8, "current recommendations apply")
        model.referenceText = "Corrected transcript B"
        check(!model.referenceAnalysisReady, "transcript edit invalidates pace analysis")
        model.analyzeReference()
        model.referenceText = "Edited while analysis was running"
        let editedDeadline = Date().addingTimeInterval(0.2)
        while Date() < editedDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(!model.referenceAnalysisReady, "in-flight analysis cannot update a changed transcript")
        let known = AppModel.SavedVoice(name:"Known",path:source.path,transcript:"Known A",createdAt:Date(),referenceSHA256:try SafeFiles.digest(source))
        model.useVoice(known)
        check(model.referenceText == "Known A", "Library restores fingerprint-matched transcript")
        model.selectEngineLabVoice(known)
        check(model.referenceText == "Known A" && !model.referenceAnalysisReady, "Engine Lab uses matching provenance and fresh analysis")
        try wave(source, amplitude: 0.3)
        check(model.generationFields(text: "Clone test") == nil, "changed on-disk reference blocks stale conditioning")
        check(model.generationFields(text: "Design test", checkReference: false) != nil, "Design remains independent of Clone reference changes")
        model.useVoice(known)
        check(model.referenceText.isEmpty && model.unverifiedReferenceTranscript == "Known A", "mismatched saved fingerprint requires explicit transcript review")
        let legacy = AppModel.SavedVoice(name:"Legacy",path:source.path,transcript:"Unverified",createdAt:Date())
        model.useVoice(legacy)
        check(model.referenceText.isEmpty && model.errorMessage != nil, "unverified legacy transcript not silently attached")
        check(model.unverifiedReferenceTranscript == "Unverified", "legacy transcript remains available for explicit review")
        model.acceptReviewedTranscript()
        check(model.referenceText == "Unverified" && model.transcriptReferenceID == model.referenceIdentity?.id, "explicit transcript review establishes current provenance")
        let invalid = root.appendingPathComponent("not-audio.txt"); try Data("not audio".utf8).write(to: invalid)
        let beforeBadDrop = model.referenceIdentity
        check(!model.selectReference(invalid) && model.referenceIdentity == beforeBadDrop, "drop/import audio validation preserves existing reference")
        check(!model.selectReference(root), "dropped folder rejected")
        let provider = NSItemProvider(contentsOf: invalid)!
        _ = model.acceptDroppedAudio([provider])
        let dropDeadline = Date().addingTimeInterval(0.2)
        while Date() < dropDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(model.referenceIdentity == beforeBadDrop, "actual drop callback cannot attach invalid audio")
        model.referenceText = "Previous recording transcript"
        model.selectRecordedReference(second)
        check(model.referenceText.isEmpty && model.referenceIdentity != beforeBadDrop, "recording replacement clears unrelated transcript")
        check(model.referenceURL!.path.contains("recorded-references"), "recording retained outside temporary take storage")

        // Minimal draft restoration: text/settings/segment edits, not rendered takes.
        model.projectName = "Project A"
        model.cloneText = "A clone"; model.designText = "A design"; model.longFormText = "A first. A second."
        model.productionChunks = [.init(text:"A first."), .init(text:"A edited second.")]
        model.performanceText = "A [pause 500ms] B"; model.performanceRules = "A=Eh"
        model.engineLabText = "A comparison"; model.speed = 1.23; model.steps = 43; model.generationSeed = 777
        model.clonePronunciationRules = "bass=[B EY1 S]"; model.referenceText = "Recording B"
        model.saveCurrentProject()
        check(model.projectStatus.contains("not a full production session"), "save success accurately describes scope")
        let projectA = model.projects.first!
        model.cloneText = "Dirty A clone"
        check(model.projectStatus.hasPrefix("Edited"), "editing changes saved status")
        let restarted = AppModel(startServices:false,storageRoot:storage,session:session,recoverDrafts:true)
        check(restarted.cloneText == "Dirty A clone" && restarted.designText == "A design", "restart recovers editable scripts")
        check(restarted.performanceText == "A [pause 500ms] B" && restarted.performanceRules == "A=Eh", "Performance draft/rules recovered unchanged")
        check(restarted.productionChunks.map(\.text) == ["A first.","A edited second."], "authoritative Long Form edits recovered")
        check(restarted.speed == 1.23 && restarted.steps == 43 && restarted.generationSeed == 777, "restart restores settings and seed")
        check(restarted.referenceText == "Recording B", "restart restores reference-bound transcript")
        model.newProject()
        check(model.cloneText.isEmpty && model.designText.isEmpty && model.performanceText.isEmpty && model.engineLabText.isEmpty, "new project clears prior scripts")
        check(model.referenceURL == nil && model.referenceText.isEmpty && model.speed == 1 && model.generationSeed == 0, "new project isolates reference/settings")
        check(model.productionChunks.isEmpty && model.performanceProduction == nil && model.variantURLs.isEmpty, "new project clears prior production UI")
        model.projectName = "Project B"; model.cloneText = "B clone"; model.saveCurrentProject()
        let projectB = model.projects.first(where: { $0.name == "Project B" })!
        model.openProject(projectA)
        check(model.cloneText == "Dirty A clone" && model.speed == 1.23 && model.referenceText == "Recording B", "opening A restores dirty A draft without B leakage")
        model.openProject(projectB)
        check(model.cloneText == "B clone" && model.referenceURL == nil && model.speed == 1, "opening B restores isolated B state")
        model.openProject(projectA)
        model.persistenceWrite = { data, url in
            if url.lastPathComponent == "projects.json" { throw ReliabilityError(message:"simulated project write failure") }
            try data.write(to:url,options:.atomic)
        }
        model.saveCurrentProject()
        check(model.projectStatus.hasPrefix("Project save failed") && model.errorMessage != nil, "project save failure never reports Saved")
        let active = model.currentProjectID
        model.persistenceWrite = { _, _ in throw ReliabilityError(message:"simulated disk full") }
        model.cloneText = "Unsaved due to disk failure"
        model.openProject(projectB)
        check(model.currentProjectID == active && model.cloneText == "Unsaved due to disk failure", "failed draft save blocks project switch")
        model.newProject()
        check(model.currentProjectID == active, "failed draft save blocks New Project")
        check(model.draftStatus.contains("NOT saved"), "draft failure visible")
        model.persistenceWrite = { try $0.write(to:$1,options:.atomic) }
        check(model.persistDraft(), "draft save can be retried")
        let oldProject = AppModel.VoiceProject(name:"Old format",referencePath:source.path,referenceText:"Legacy A",pronunciationRules:"x=ex",generationIDs:[],createdAt:Date(),updatedAt:Date())
        let decoded = try JSONDecoder().decode(AppModel.VoiceProject.self,from:JSONEncoder().encode(oldProject))
        model.openProject(decoded)
        check(model.cloneText.isEmpty && model.speed == 1 && model.referenceText.isEmpty, "legacy project starts isolated without unverified transcript")
        check(model.referenceURL != nil && model.pronunciationRules == "x=ex", "legacy project retains usable reference path and dictionary")
        model.newProject()
        model.cloneText = "Unsaved scratch script"
        let scratchKey = model.draftBook.activeKey
        model.newProject()
        model.recoverDraft(scratchKey)
        check(model.cloneText == "Unsaved scratch script" && model.currentProjectID == nil, "unsaved drafts remain explicitly recoverable after New Project")
        let projectsFile = storage.appendingPathComponent("projects.json")
        let originalProjects = try Data(contentsOf: projectsFile)
        try Data("corrupt project record".utf8).write(to: projectsFile)
        let badProjects = AppModel(startServices:false,storageRoot:storage,session:session,recoverDrafts:true)
        badProjects.saveCurrentProject()
        check(badProjects.projectStatus.hasPrefix("Project save failed"), "corrupt project file cannot be silently replaced")
        try verify(try Data(contentsOf: projectsFile) == Data("corrupt project record".utf8), "corrupt project bytes preserved")
        try originalProjects.write(to: projectsFile)
        let draftFile = model.draftsFile
        try Data("corrupt recovery file".utf8).write(to:draftFile)
        let corrupt = AppModel(startServices:false,storageRoot:storage,session:session,recoverDrafts:true)
        corrupt.cloneText = "New edit"
        check(!corrupt.persistDraft(), "corrupt recovery file fails closed")
        try verify(try Data(contentsOf:draftFile) == Data("corrupt recovery file".utf8), "corrupt recovery file never overwritten")
        CaptureProtocol.routedResponses.removeValue(forKey:"/analyze-reference")
    }
}
