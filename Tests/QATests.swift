import Foundation

extension Phase1Tests {
    /// Fixes from the November 2026 QA pass.
    @MainActor
    static func qaTests() {
        // Long Form splits at every sentence end, not only ". ".
        let mixed = AppModel.segments("Is it here? Yes! It is. Well…  maybe not", limit: 12)
        check(mixed == ["Is it here?", "Yes! It is.", "Well…", "maybe not"],
              "segments split at ? ! . and … and respect the limit")
        let questions = AppModel.segments(String(repeating: "Why does this happen? ", count: 40))
        check(questions.count > 1 && questions.allSatisfy { $0.count <= 420 }, "question-only script is split into segments")
        let runOn = AppModel.segments(String(repeating: "word ", count: 200) + "end, " + String(repeating: "more ", count: 100))
        check(runOn.allSatisfy { $0.count <= 420 } && runOn.joined(separator: " ").split(separator: " ").count == 301,
              "an over-long sentence is broken without losing words")
        check(AppModel.segments("One. Two.") == ["One. Two."], "short sentences are packed together")
        check(AppModel.segments("  \n ").isEmpty, "blank script makes no segments")
        check(AppModel.segments("She said \"stop.\" Then left.", limit: 20) == ["She said \"stop.\"", "Then left."],
              "closing quotes stay with their sentence")

        // Settings errors name the setting.
        func message(_ request: GenerationRequest) -> String {
            do { _ = try request.fields(); return "" } catch { return error.localizedDescription }
        }
        check(message(GenerationRequest(text: "Hi", duration: 900)).contains("Fixed duration"), "duration error names the setting")
        check(message(GenerationRequest(text: "Hi", seed: -1)).contains("Seed"), "seed error names the setting")
        check(message(GenerationRequest(text: "Hi", speed: 3)).contains("Speed"), "speed error names the setting")
        check(message(GenerationRequest(text: "Hi", segments: ["One", " "])).contains("Segment 2 is empty"),
              "an empty segment is named by number")
        check(message(GenerationRequest(text: " ")).contains("Write something"), "empty script says so")

        // New / Open Scene asks before discarding unsaved work.
        let store = CastStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("qa-cast-\(UUID()).json"),
                              scenesRoot: FileManager.default.temporaryDirectory.appendingPathComponent("qa-scenes-\(UUID())"))
        check(!store.hasUnsavedWork, "an empty Cast page has nothing to lose")
        store.script = "A: Hello."
        check(store.hasUnsavedWork, "a written, unsaved scene counts as unsaved work")
    }
}
