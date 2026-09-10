import Foundation
import AppKit

struct EditableDraft: Codable {
    var projectID: UUID?
    var referencePath: String?
    var referenceSHA256: String?
    var referenceText = ""
    var unverifiedTranscript: String?
    var chunks: [String] = []
    var cloneText: String = ""
    var cloneLanguage: String = "Auto detect"
    var clonePronunciationRules: String = ""
    var designMode: String = "Design"
    var designDialect: String = "Auto"
    var designPreset: String = "Custom"
    var designText: String = ""
    var designGender: String = "Auto"
    var designAge: String = "Auto"
    var designPitch: String = "Auto"
    var designAccent: String = "Auto"
    var designStyle: String = "Auto"
    var designPronunciationRules: String = ""
    var engineLabText: String = ""
    var engineLabEngineA: String = "OmniVoice Zero-Shot"
    var engineLabEngineB: String = "F5-TTS"
    var preset: String = "Natural"
    var pronunciationRules: String = ""
    var projectName: String = "Untitled Project"
    var performanceText: String = ""
    var performanceRules: String = ""
    var speed: Double = 1.0
    var steps: Double = 32.0
    var guidance: Double = 2.0
    var targetDuration: Double = 10.0
    var timeShift: Double = 0.1
    var positionTemperature: Double = 5.0
    var classTemperature: Double = 0.0
    var layerPenaltyFactor: Double = 5.0
    var generationSeed: Int = 0
    var variantCount: Int = 2
    var denoiseOutput: Bool = true
    var useDuration: Bool = false
    var cloneMatchInsideWords: Bool = false
    var longFormMatchInsideWords: Bool = false
    var designMatchInsideWords: Bool = false
    var performanceMatchInsideWords: Bool = false
    var longFormText: String = ""
}
struct DraftBook: Codable {
    var schema = 1
    var activeKey = UUID().uuidString
    var drafts: [String: EditableDraft] = [:]
}
struct DraftSummary: Identifiable { let id: String; let name: String }

extension AppModel {
    var draftsFile: URL { appSupport.appendingPathComponent("editable-drafts.json") }
    func captureDraft() -> EditableDraft {
        var draft = EditableDraft()
        draft.projectID = currentProjectID
        draft.referencePath = referenceURL?.path
        draft.referenceSHA256 = referenceIdentity?.sha256
        draft.referenceText = referenceText
        draft.unverifiedTranscript = unverifiedReferenceTranscript
        draft.chunks = productionChunks.map(\.text)
        draft.cloneText = cloneText
        draft.cloneLanguage = cloneLanguage
        draft.clonePronunciationRules = clonePronunciationRules
        draft.designMode = designMode
        draft.designDialect = designDialect
        draft.designPreset = designPreset
        draft.designText = designText
        draft.designGender = designGender
        draft.designAge = designAge
        draft.designPitch = designPitch
        draft.designAccent = designAccent
        draft.designStyle = designStyle
        draft.designPronunciationRules = designPronunciationRules
        draft.engineLabText = engineLabText
        draft.engineLabEngineA = engineLabEngineA
        draft.engineLabEngineB = engineLabEngineB
        draft.preset = preset
        draft.pronunciationRules = pronunciationRules
        draft.projectName = projectName
        draft.performanceText = performanceText
        draft.performanceRules = performanceRules
        draft.speed = speed
        draft.steps = steps
        draft.guidance = guidance
        draft.targetDuration = targetDuration
        draft.timeShift = timeShift
        draft.positionTemperature = positionTemperature
        draft.classTemperature = classTemperature
        draft.layerPenaltyFactor = layerPenaltyFactor
        draft.generationSeed = generationSeed
        draft.variantCount = variantCount
        draft.denoiseOutput = denoiseOutput
        draft.useDuration = useDuration
        draft.cloneMatchInsideWords = cloneMatchInsideWords
        draft.longFormMatchInsideWords = longFormMatchInsideWords
        draft.designMatchInsideWords = designMatchInsideWords
        draft.performanceMatchInsideWords = performanceMatchInsideWords
        draft.longFormText = longFormText
        return draft
    }
    func applyDraft(_ draft: EditableDraft) {
        draftSuspended = true
        defer { draftSuspended = false }
        outputPlayer.stop(); referencePlayer.stop()
        outputURL = nil; longFormOutputURL = nil; variantURLs = []
        engineLabA = nil; engineLabB = nil; engineLabMap = [:]; engineLabWinner = nil; engineLabRevealed = false
        performanceProduction = nil; performanceStatus = "Load a saved production separately, or prepare this draft."
        activeProjectGenerationIDs = []; currentProjectID = draft.projectID
        referenceURL = nil
        if let path = draft.referencePath {
            _ = selectReference(URL(fileURLWithPath: path), transcript: draft.referenceText, expectedSHA256: draft.referenceSHA256)
        }
        if referenceURL != nil, let unverified = draft.unverifiedTranscript { unverifiedReferenceTranscript = unverified }
        cloneText = draft.cloneText
        cloneLanguage = draft.cloneLanguage
        clonePronunciationRules = draft.clonePronunciationRules
        designMode = draft.designMode
        designDialect = draft.designDialect
        designPreset = draft.designPreset
        designText = draft.designText
        designGender = draft.designGender
        designAge = draft.designAge
        designPitch = draft.designPitch
        designAccent = draft.designAccent
        designStyle = draft.designStyle
        designPronunciationRules = draft.designPronunciationRules
        engineLabText = draft.engineLabText
        engineLabEngineA = draft.engineLabEngineA
        engineLabEngineB = draft.engineLabEngineB
        preset = draft.preset
        pronunciationRules = draft.pronunciationRules
        projectName = draft.projectName
        performanceText = draft.performanceText
        performanceRules = draft.performanceRules
        speed = draft.speed
        steps = draft.steps
        guidance = draft.guidance
        targetDuration = draft.targetDuration
        timeShift = draft.timeShift
        positionTemperature = draft.positionTemperature
        classTemperature = draft.classTemperature
        layerPenaltyFactor = draft.layerPenaltyFactor
        generationSeed = draft.generationSeed
        variantCount = draft.variantCount
        denoiseOutput = draft.denoiseOutput
        useDuration = draft.useDuration
        cloneMatchInsideWords = draft.cloneMatchInsideWords
        longFormMatchInsideWords = draft.longFormMatchInsideWords
        designMatchInsideWords = draft.designMatchInsideWords
        performanceMatchInsideWords = draft.performanceMatchInsideWords
        longFormText = draft.longFormText
        productionChunks = draft.chunks.map { ProductionChunk(text: $0) }
    }
    func refreshDraftSummaries() {
        recoverableDrafts = draftBook.drafts.map { DraftSummary(id: $0.key, name: $0.value.projectName + " • " + String($0.key.prefix(8))) }.sorted { $0.name < $1.name }
    }
    func restoreDrafts() {
        guard FileManager.default.fileExists(atPath: draftsFile.path) else { draftStatus = "Editable drafts recover automatically; productions are separate."; return }
        do {
            let recovered = try JSONDecoder().decode(DraftBook.self, from: Data(contentsOf: draftsFile))
            guard recovered.schema == 1 else { throw ReliabilityError(message: "Unsupported draft format; existing file was preserved.") }
            draftBook = recovered
            guard let draft = recovered.drafts[recovered.activeKey] else { throw ReliabilityError(message: "Active draft is missing from the recovery file.") }
            applyDraft(draft)
            refreshDraftSummaries()
            draftStatus = "Recovered editable draft — takes and masters are stored separately"
            projectStatus = "Recovered draft; project record may differ"
        } catch {
            draftLoadFailed = true
            draftStatus = "Draft recovery failed — existing recovery file preserved"
            errorMessage = "Could not recover \(draftsFile.path): \(error.localizedDescription). Back up/repair that file before saving; it will not be overwritten."
        }
    }
    @discardableResult
    func persistDraft() -> Bool {
        guard draftsEnabled, !draftSuspended else { return true }
        guard !draftLoadFailed else { draftStatus = "Draft storage needs repair; switching is blocked to protect work."; return false }
        var candidate = draftBook
        candidate.drafts[candidate.activeKey] = captureDraft()
        do {
            try persistenceWrite(JSONEncoder().encode(candidate), draftsFile)
            draftBook = candidate; refreshDraftSummaries()
            draftStatus = "Editable draft recovered on restart — takes/masters are separate"
            return true
        } catch {
            draftStatus = "Draft NOT saved — keep this window open and retry saving"
            projectStatus = "Unsaved changes — draft persistence failed"
            errorMessage = "Draft save failed: \(error.localizedDescription). Check storage space and permissions for \(appSupport.path)."
            return false
        }
    }
    func draftChanged() {
        guard draftsEnabled, !draftSuspended else { return }
        projectStatus = "Edited — recoverable draft, not a complete saved production"
        _ = persistDraft()
    }
    func canSwitchDraft() -> Bool {
        guard !isGenerating, !engineLabRunning, !performanceBusy, !recorder.isRecording else {
            errorMessage = "Finish the active generation or recording before switching projects/drafts."
            return false
        }
        return persistDraft()
    }
    func recoverDraft(_ key: String) {
        guard let draft = draftBook.drafts[key], canSwitchDraft() else { return }
        applyDraft(draft); draftBook.activeKey = key
        if let id = currentProjectID { activeProjectGenerationIDs = projects.first(where: { $0.id == id })?.generationIDs ?? [] }
        projectStatus = "Recovered editable draft; productions remain separate"
        _ = persistDraft()
    }
}

final class DraftQuitDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.recorder.isRecording { model.recorder.stop() }
        if model.persistDraft() { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your editable draft could not be saved"
        alert.informativeText = "Cancel quitting to fix storage/permissions and retry. Quitting now may lose the changes since the last successful recovery save."
        alert.addButton(withTitle: "Cancel Quit")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
