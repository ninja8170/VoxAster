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

extension Phase1Tests {
    static func castTimelineTests() {
        let cut = CastStore.cue("I was going to say--"), over = CastStore.cue(">> No, listen!"), plain = CastStore.cue("Hello.")
        check(cut.text == "I was going to say—" && cut.cut && !cut.over, "-- marks a cut-off line and becomes a dash")
        check(over.text == "No, listen!" && over.over && !over.cut, ">> marks a talk-over and is removed")
        check(plain.text == "Hello." && !plain.cut && !plain.over, "plain lines are untouched")
        check(CastStore.cue("Wait—").cut, "an em dash also cuts off")

        typealias Clip = CastStore.Clip
        func clip(_ unit: Int, _ part: Int, _ lane: String, _ a: Double, _ b: Double, cut: Bool = false, over: Bool = false) -> Clip {
            Clip(unit: unit, part: part, lane: lane, text: "", srcIn: a, srcOut: b, start: a, cut: cut, over: over)
        }
        // Line by line: 2 s, 1 s, 3 s with a 0.5 s gap.
        var laid = CastStore.layout([[clip(0, 0, "A", 0, 2)], [clip(1, 0, "B", 0, 1)], [clip(2, 0, "A", 0, 3)]], gap: 0.5)
        check(laid.map(\.start) == [0, 2.5, 4.0], "lines follow each other with the gap")
        // A is cut off: B overlaps A's last 0.25 s. Then C talks over B: starts 0.8 s before B ends.
        laid = CastStore.layout([[clip(0, 0, "A", 0, 2, cut: true)], [clip(1, 0, "B", 0, 2)], [clip(2, 0, "C", 0, 1, over: true)]], gap: 0.5)
        check(abs(laid[1].start - 1.75) < 1e-9, "a cut-off line is overlapped by the next")
        check(abs(laid[2].start - (laid[1].end - 0.8)) < 1e-9, "a >> line comes in before the previous ends")
        // Together passage keeps MOSS's spacing; the next unit follows after the gap.
        laid = CastStore.layout([[clip(0, 0, "A", 0, 1.2), clip(0, 1, "B", 1.2, 2.0)], [clip(1, 0, "A", 0, 1)]], gap: 0.4)
        check(laid.map(\.start) == [0, 1.2, 2.4], "passage parts keep their own timing")
        let split = CastStore.proportionalSlices(["ab", "abcd"], 3)
        check(split.count == 2 && abs(split[0][1] - 1) < 1e-9 && abs(split[1][1] - 3) < 1e-9, "untimed passages split by text length")
    }
}

extension Phase1Tests {
    @MainActor
    static func sceneEditorTests() throws {
        // Snapping and the overlap guard.
        check(CastStore.snap(2.03, to: [0, 2.0, 5.0], within: 0.05) == 2.0, "snaps to a nearby edge")
        check(CastStore.snap(2.3, to: [0, 2.0, 5.0], within: 0.05) == nil, "no snap beyond the tolerance")
        let others = [(start: 1.0, end: 3.0), (start: 4.0, end: 6.0)]
        check(CastStore.place(0.0, length: 1.0, among: others) == 0.0, "a free spot is kept")
        check(CastStore.place(2.5, length: 1.0, among: others) == 3.0, "an overlapping clip moves to the nearest free edge")
        check(CastStore.place(1.2, length: 1.0, among: others) == 0.0, "…on either side")
        check(CastStore.place(3.2, length: 2.0, among: others) == 6.0, "a clip too long for the gap goes past the next clip")

        // Rewriting one line of the script.
        let script = "ANNA: Hello there.\nBEN: Hi.\nmore of Ben's line\nANNA: Bye--"
        check(CastStore.replacing(line: 1, in: script, with: "Hey, Anna.") == "ANNA: Hello there.\nBEN: Hey, Anna.\nANNA: Bye--",
              "an edited line replaces its entry and folds continuation lines")
        check(CastStore.replacing(line: 2, in: script, with: "Goodbye--") == "ANNA: Hello there.\nBEN: Hi.\nmore of Ben's line\nANNA: Goodbye--",
              "the last line is replaced with its mark")
        check(CastStore.replacing(line: 0, in: "Once upon a time.\nANNA: Hi.", with: "Twice.") == "Twice.\nANNA: Hi.",
              "an unlabelled narrator line is replaced as written")

        // Whisper's word check, mapped to times.
        let words: [[String: Any]] = [["text": "voices", "status": "ok", "t0": 0.1, "t1": 0.5],
                                      ["text": "sound", "status": "wrong", "heard": "aren't", "t0": 0.6, "t1": 0.9],
                                      ["text": "great", "status": "missing"],
                                      ["text": "today", "status": "ok", "t0": 1.4, "t1": 1.8]]
        let issues = CastStore.issues(words)
        check(issues == [.init(t: 0.6, word: "sound", heard: "aren't"), .init(t: 1.4, word: "great", heard: nil)],
              "wrong words keep their time; missing words sit where the next word starts")

        // Undo and redo over timeline edits.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voxaster-editor-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        typealias Clip = CastStore.Clip
        let clipsIn = [Clip(unit: 0, part: 0, lane: "ANNA", text: "Hi.", srcIn: 0, srcOut: 1, start: 0),
                       Clip(unit: 1, part: 0, lane: "BEN", text: "Yo.", srcIn: 0, srcOut: 1, start: 1.5),
                       Clip(unit: 2, part: 0, lane: "ANNA", text: "So.", srcIn: 0, srcOut: 1, start: 3)]
        let draft = CastStore.Saved(script: "ANNA: Hi.\nBEN: Yo.\nANNA: So.", assignments: [:], gapMs: 350, room: "dry",
                                    lines: [.init(speaker: "ANNA", text: "Hi.", path: nil, error: nil),
                                            .init(speaker: "BEN", text: "Yo.", path: nil, error: nil),
                                            .init(speaker: "ANNA", text: "So.", path: nil, error: nil)],
                                    master: nil, sceneID: nil, sceneName: nil, clips: clipsIn)
        let file = root.appendingPathComponent("cast.json")
        try JSONEncoder().encode(draft).write(to: file)
        let cast = CastStore(file: file, scenesRoot: root.appendingPathComponent("scenes"))
        let model = AppModel(startServices: false, storageRoot: root.appendingPathComponent("model"))
        cast.markBaseline()
        let ben = cast.clips[1].id, anna = cast.clips[2].id
        check(cast.trimLimits(anna).earliest == 1.0 && cast.trimLimits(cast.clips[0].id).latest == 3.0,
              "trims stop at neighbours on the same track")
        let landed = cast.landing(anna, proposed: 0.4, snapping: false, playhead: nil, tolerance: 0)
        check(landed.start == 1.0, "a drag onto another clip on the same track lands beside it")
        cast.editClip(ben) { $0.start = 2.0 }; cast.commitEdit(model)
        cast.tracks.muted = ["BEN"]; cast.commitEdit(model)
        check(cast.canUndo && !cast.canRedo, "edits can be undone")
        cast.undo(model)
        check(cast.tracks.muted.isEmpty && cast.clips[1].start == 2.0, "undo restores the track settings")
        cast.undo(model)
        check(cast.clips[1].start == 1.5 && !cast.canUndo && cast.canRedo, "undo restores the clip position")
        cast.redo(model); cast.redo(model)
        check(cast.clips[1].start == 2.0 && cast.tracks.muted == ["BEN"] && !cast.canRedo, "redo replays both edits")
        cast.editClip(anna) { $0.start = 4 }; cast.commitEdit(model)
        check(!cast.canRedo, "a new edit clears redo")
    }
}

extension Phase1Tests {
    @MainActor
    static func exportAndPaceTests() throws {
        typealias Clip = CastStore.Clip
        // A: 0–2, B: 2.5–3.5 (0.5 gap), C talks over B: 3.0–4.0 (overlap), D: 5.0–6.0 (1.0 gap).
        let clips = [Clip(unit: 0, part: 0, lane: "ANNA", text: "Hi.", srcIn: 0, srcOut: 2, start: 0),
                     Clip(unit: 1, part: 0, lane: "BEN", text: "Hey--", srcIn: 0, srcOut: 1, start: 2.5, cut: true),
                     Clip(unit: 2, part: 0, lane: "ANNA", text: "Wait.", srcIn: 0, srcOut: 1, start: 3.0, over: true),
                     Clip(unit: 3, part: 0, lane: "BEN", text: "Okay.", srcIn: 0, srcOut: 1, start: 5.0)]
        let tight = CastStore.paced(clips, factor: 0.5)
        check(tight.map(\.start) == [0, 2.25, 2.75, 4.25], "pace halves gaps and keeps overlaps")
        check(CastStore.paced(clips, factor: 1).map(\.start) == clips.map(\.start), "pace 100% changes nothing")
        let loose = CastStore.paced(clips, factor: 1.4)
        check(abs(loose[3].start - 5.6) < 1e-9 && abs(loose[2].start - (loose[1].start + 0.5)) < 1e-9, "looser pace widens gaps only")

        let srt = CastStore.subtitles(clips, format: .srt)
        check(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nAnna: Hi.\n\n2\n00:00:02,500 --> 00:00:03,250\nBen: Hey--"),
              "SRT cues are numbered, speaker-labelled, and a cut-off line ends as the next takes over")
        let vtt = CastStore.subtitles(clips, format: .vtt)
        check(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<v Anna>Hi.\n"), "WebVTT uses voice tags")
        check(vtt.contains("00:00:05.000 --> 00:00:06.000\n<v Ben>Okay."), "every line becomes a cue")

        // Older saved timelines (before fades) still load.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","unit":0,"part":0,"lane":"A","text":"Hi","srcIn":0,"srcOut":1,"start":0,"gainDb":0,"cut":false,"over":false}"#
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(old.utf8))
        check(decoded.fadeIn == nil && decoded.fadeOut == nil, "clips saved before fades decode")

        // Markers are part of undo.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voxaster-markers-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cast = CastStore(file: root.appendingPathComponent("cast.json"), scenesRoot: root.appendingPathComponent("scenes"))
        let model = AppModel(startServices: false, storageRoot: root.appendingPathComponent("model"))
        cast.markBaseline()
        cast.addMarker(at: 3.0, model)
        cast.addMarker(at: 1.0, model)
        check(cast.markers.map(\.t) == [1.0, 3.0] && cast.markers.map(\.name) == ["Marker 2", "Marker 1"], "markers stay in time order")
        cast.renameMarker(cast.markers[0].id, to: "Joke lands", model)
        check(cast.markers[0].name == "Joke lands", "markers can be renamed")
        cast.undo(model)
        check(cast.markers[0].name == "Marker 2", "undo reverts a rename")
        cast.undo(model); cast.undo(model)
        check(cast.markers.isEmpty && !cast.canUndo, "undo removes added markers")
    }
}
