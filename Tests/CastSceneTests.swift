import Foundation

extension Phase1Tests {
    @MainActor
    static func castSceneTests() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voxaster-cast-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let outputs = root.appendingPathComponent("outputs")
        try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
        let a = outputs.appendingPathComponent("voxaster-aaaa0001.wav"), master = outputs.appendingPathComponent("voxaster-mmmm0001.wav")
        try wave(a); try wave(master)

        // A draft where line 2 failed: it restores with its state and error.
        let draft = CastStore.Saved(script: "ANNA: Hello.\nBEN: Hi there.", assignments: ["ANNA": "design:Woman, warm", "BEN": "design:Young man"],
                                    gapMs: 300, room: "booth",
                                    lines: [.init(speaker: "ANNA", text: "Hello.", path: a.path, error: nil),
                                            .init(speaker: "BEN", text: "Hi there.", path: nil, error: "Engine busy"),
                                            .init(speaker: "ANNA · BEN", text: "", path: nil, error: nil,
                                                  parts: [.init(speaker: "ANNA", text: "So."), .init(speaker: "BEN", text: "Right.")])],
                                    master: nil, sceneID: nil, sceneName: nil)
        let draftFile = root.appendingPathComponent("cast.json")
        try JSONEncoder().encode(draft).write(to: draftFile)
        let scenes = outputs.appendingPathComponent("scenes")
        let cast = CastStore(file: draftFile, scenesRoot: scenes)
        check(cast.lines.map(\.state) == ["Done", "Failed", "Pending"], "draft restores rendered and failed lines")
        check(cast.lines[2].parts?.count == 2 && cast.lines[2].text == "ANNA: So.\nBEN: Right.", "draft restores a Together passage")
        check(cast.missing == [1, 2] && cast.failedCount == 1, "failed and unrendered rows are left to retry")
        check(cast.room == "booth" && cast.gapMs == 300, "draft restores room and gap")

        check(cast.saveScene(), "scene saves")
        guard let id = cast.sceneID else { check(false, "saved scene has an id"); return }
        let folder = cast.folder(for: id)
        check(cast.lines[0].output?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, "lines adopt the scene's own copies")
        check(cast.scenes.count == 1 && cast.scenes[0].name == "Hello.", "scene listed with a default name")

        // Deleting the original take must not break the saved scene.
        try fm.removeItem(at: a)
        let reopened = CastStore(file: root.appendingPathComponent("other.json"), scenesRoot: scenes)
        check(reopened.scenes.count == 1, "scenes load from disk")
        reopened.openScene(reopened.scenes[0])
        check(reopened.lines.map(\.state) == ["Done", "Failed", "Pending"] && reopened.lines[0].output != nil, "opened scene keeps its line audio")
        check(reopened.lines[2].parts?.count == 2, "saved scene keeps Together passages")
        check(reopened.script == cast.script && reopened.assignments == cast.assignments && reopened.room == "booth", "opened scene restores script, voices and room")

        // Save as new keeps the original; rename and delete.
        reopened.sceneName = "Copy"
        check(reopened.saveScene(asNew: true), "save as new")
        check(reopened.scenes.count == 2 && reopened.sceneID != id, "copy is a separate scene")
        reopened.renameScene(reopened.scenes.first { $0.id == id }!, to: "Opening")
        check(reopened.scenes.contains { $0.id == id && $0.name == "Opening" }, "rename")
        reopened.deleteScene(reopened.scenes.first { $0.id == id }!)
        check(!fm.fileExists(atPath: folder.path) && reopened.scenes.count == 1, "delete removes the folder")
        try wave(master)
        reopened.newScene()
        check(reopened.script.isEmpty && reopened.lines.isEmpty && reopened.sceneID == nil, "new scene clears the page")
    }
}

extension Phase1Tests {
    static func castPassageTests() {
        let script: [(speaker: String, text: String)] = (1...8).map { (["ANNA", "BEN"][$0 % 2], "Line \($0).") }
        let passages = CastStore.passages(script)
        check(passages.map(\.count) == [6, 2], "Together splits long scenes into six-line passages")
        let long = [(speaker: "ANNA", text: String(repeating: "a", count: 300)), (speaker: "BEN", text: String(repeating: "b", count: 200))]
        check(CastStore.passages(long).count == 2, "passages stay under the character budget")
        let crowd = (1...6).map { (speaker: "P\($0)", text: "Hi.") }
        check(CastStore.passages(crowd).map(\.count) == [5, 1], "at most five speakers per passage")
        let line = CastStore.Line(passage: [.init(speaker: "ANNA", text: "Hi."), .init(speaker: "BEN", text: "Yo."), .init(speaker: "ANNA", text: "So.")])
        check(line.speaker == "ANNA · BEN" && line.text == "ANNA: Hi.\nBEN: Yo.\nANNA: So." && line.parts?.count == 3, "passage row shows its lines")
    }
}
