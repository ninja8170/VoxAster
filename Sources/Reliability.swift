import Foundation
import CryptoKit
import AVFoundation
import Darwin

struct ReliabilityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SafeFiles {
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if canonical(a) == canonical(b) { return true }
        var x = stat(), y = stat()
        return stat(a.path, &x) == 0 && stat(b.path, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }
    static func renameAtomically(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not replace \(destination.lastPathComponent): \(String(cString: strerror(errno))). The previous file was preserved."])
        }
    }
    /// Resolve destination symlinks deliberately; stage on its actual filesystem.
    static func export(_ source: URL, to destination: URL,
                       copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                       replace: (URL, URL) throws -> Void = renameAtomically) throws {
        let source = canonical(source), destination = canonical(destination)
        guard !sameFile(source, destination) else {
            throw ReliabilityError(message: "The export destination is the source audio (or an equivalent path). Choose a different filename or folder. No file was changed.")
        }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".voxaster-export-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let expected = try digest(source)
        try copy(source, temporary)
        guard try digest(temporary) == expected, try digest(source) == expected else {
            throw ReliabilityError(message: "The export copy did not match the source, or the source changed. The previous destination was preserved; retry the export.")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        guard !sameFile(source, destination) else {
            throw ReliabilityError(message: "The destination now identifies the source. Export cancelled without replacing it.")
        }
        try replace(temporary, destination)
    }
}

struct ReferenceIdentity: Codable, Equatable {
    var id = UUID()
    let sha256: String
}
struct ReferenceAnalysisBinding: Equatable {
    let identity: ReferenceIdentity
    let transcript: String
    let requestID: UUID
}

extension AppModel {
    func invalidateReferenceAnalysis() {
        analysisBinding = nil
        referenceAnalyzing = false; referenceAnalysisReady = false
        referenceAnalysisStatus = "Analyze the current reference and transcript."
        referenceDuration = 0; referencePitch = 0; referencePitchRange = 0
        referenceRMS = -60; referencePeak = -60; referenceSpeechRatio = 0; referencePauseRatio = 0
        referenceWPM = 0; referenceQualityScore = 0; referenceQualityLabel = "Not analyzed"; referencePaceLabel = "Unknown"
        recommendedSpeed = 1; recommendedSteps = 32; recommendedGuidance = 2; recommendedDenoise = true
    }
    func referenceDidChange() {
        referencePlayer.stop()
        unverifiedReferenceTranscript = nil
        referenceIdentity = referenceURL.flatMap { url in (try? SafeFiles.digest(url)).map { ReferenceIdentity(sha256: $0) } }
        referenceText = ""
        transcriptReferenceID = referenceIdentity?.id
        invalidateReferenceAnalysis()
        draftChanged()
    }
    func transcriptDidChange() {
        transcriptReferenceID = referenceIdentity?.id
        invalidateReferenceAnalysis()
        draftChanged()
    }
    func referenceMatches(_ identity: ReferenceIdentity) -> Bool {
        guard identity == referenceIdentity, let url = referenceURL else { return false }
        return (try? SafeFiles.digest(url)) == identity.sha256
    }
    func analysisIsCurrent(_ binding: ReferenceAnalysisBinding) -> Bool {
        analysisBinding == binding && referenceMatches(binding.identity) && referenceText == binding.transcript && transcriptReferenceID == binding.identity.id
    }
    @discardableResult
    func selectReference(_ url: URL, transcript: String = "", expectedSHA256: String? = nil) -> Bool {
        do {
            let canonical = SafeFiles.canonical(url)
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw ReliabilityError(message: "Choose a regular audio file, not a folder.") }
            let audio = try AVAudioFile(forReading: canonical)
            guard audio.length > 0, audio.fileFormat.sampleRate > 0 else { throw ReliabilityError(message: "The recording contains no usable audio.") }
            let suspended = draftSuspended
            draftSuspended = true
            defer { draftSuspended = suspended; draftChanged() }
            referenceURL = canonical
            if let expectedSHA256, expectedSHA256 == referenceIdentity?.sha256 { referenceText = transcript }
            else if !transcript.isEmpty {
                unverifiedReferenceTranscript = transcript
                errorMessage = "Reference selected, but its saved transcript has no matching audio fingerprint. Review and enter the transcript before using it; the old saved record is unchanged."
            }
            return true
        } catch {
            errorMessage = "Reference import failed: \(error.localizedDescription) Choose a readable audio recording. The previous reference was kept."
            return false
        }
    }
    func acceptReviewedTranscript() {
        guard let text = unverifiedReferenceTranscript, let identity = referenceIdentity, referenceMatches(identity) else { return }
        referenceText = text
        unverifiedReferenceTranscript = nil
        draftChanged()
    }
    func selectRecordedReference(_ url: URL) {
        do {
            let folder = appSupport.appendingPathComponent("recorded-references")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let retained = folder.appendingPathComponent(UUID().uuidString + ".wav")
            try SafeFiles.export(url, to: retained)
            if !selectReference(retained) { try? FileManager.default.removeItem(at: retained) }
        } catch { errorMessage = "Could not retain the recording: \(error.localizedDescription). Original recording: \(url.path)" }
    }
    func exportAudio(_ source: URL, to destination: URL) {
        do { try SafeFiles.export(source, to: destination) }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
}
