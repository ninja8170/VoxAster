import SwiftUI
import AppKit

struct NativeEvent: Identifiable {
    let label: String
    let name: String
    let group: String
    var id: String { name }
    var token: String { "[\(name)]" }
    static let all: [NativeEvent] = [
        .init(label:"Laugh", name:"laughter", group:"Event"),
        .init(label:"Sigh", name:"sigh", group:"Event"),
        .init(label:"Confirm", name:"confirmation-en", group:"Event"),
        .init(label:"En", name:"question-en", group:"Question"),
        .init(label:"Ah", name:"question-ah", group:"Question"),
        .init(label:"Oh", name:"question-oh", group:"Question"),
        .init(label:"Ei", name:"question-ei", group:"Question"),
        .init(label:"Yi", name:"question-yi", group:"Question"),
        .init(label:"Ah", name:"surprise-ah", group:"Surprise"),
        .init(label:"Oh", name:"surprise-oh", group:"Surprise"),
        .init(label:"Wa", name:"surprise-wa", group:"Surprise"),
        .init(label:"Yo", name:"surprise-yo", group:"Surprise"),
        .init(label:"Hmm", name:"dissatisfaction-hnn", group:"Event")
    ]
    static func isValid(_ token: String) -> Bool { all.contains { $0.token == token } }
}

enum NativePronunciation {
    static func cmuToken(_ input: String) -> String? {
        let vowels = "AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW".split(separator: " ")
        let consonants = "B CH D DH F G HH JH K L M N NG P R S SH T TH V W Y Z ZH".split(separator: " ").map(String.init)
        let allowed = Set(consonants + vowels.flatMap { vowel in ["0", "1", "2"].map { String(vowel) + $0 } })
        let tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "[" + tokens.joined(separator: " ") + "]"
    }
    static func pinyinValue(_ input: String) -> String? {
        let tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ $0.range(of: "^[A-Z]+[1-5]$", options: .regularExpression) != nil }) else { return nil }
        return tokens.joined(separator: " ")
    }
}

enum SpeechInsertion {
    /// NSTextView selections use UTF-16 offsets; never split a Unicode character.
    static func insert(_ value: String, into text: String, selection: NSRange) -> (String, NSRange)? {
        let current = selection.location > text.utf16.count ? NSRange(location: text.utf16.count, length: 0) : selection
        guard let range = Range(current, in: text),
              range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound),
              range.upperBound == text.endIndex || text.indices.contains(range.upperBound) else { return nil }
        let before = String(text[..<range.lowerBound])
        let after = String(text[range.upperBound...])
        let leading = before.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trailing = after.first.map { $0.isWhitespace || ".,!?;:".contains($0) ? "" : " " } ?? " "
        let insertion = leading + value + trailing
        return (before + insertion + after, NSRange(location: (before + insertion).utf16.count, length: 0))
    }
}

/// Plain NSTextView keeps the cursor/selection when a toolbar button is clicked.
struct CursorTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .systemFont(ofSize: 14)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.delegate = context.coordinator
        view.allowsUndo = true
        view.setAccessibilityLabel("Speech script")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if view.string != text { view.string = text }
        let current = Range(selection, in: text) == nil ? NSRange(location: text.utf16.count, length: 0) : selection
        if view.selectedRange() != current {
            view.setSelectedRange(current)
            view.scrollRangeToVisible(current)
        }
        if current != selection {
            let old = selection
            DispatchQueue.main.async {
                if self.selection == old { self.selection = current }
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CursorTextEditor
        var updating = false
        init(_ parent: CursorTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }
}

struct SpeechInspection: Decodable {
    struct Issue: Decodable { let level: String; let message: String }
    let text: String
    let issues: [Issue]
    let can_generate: Bool
}

struct SpeechPreview: View {
    @EnvironmentObject var model: AppModel
    let text: String
    let rules: String
    let matchMode: String
    @State private var result: SpeechInspection?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let result {
                ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.level == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(issue.level == "error" ? .red : .orange)
                }
                DisclosureGroup("What OmniVoice receives") {
                    Text(result.text.isEmpty ? "No speech preview available." : result.text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Target text after pronunciation processing and native whitespace normalization. Events and phonemes stay intact; audio timing and reference conditioning are not shown.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: [text, rules, matchMode]) {
            result = nil; error = nil
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let inspection = try await model.inspectSpeech(text: text, rules: rules, matchMode: matchMode)
                try Task.checkCancellation()
                result = inspection
            } catch is CancellationError { }
            catch { self.error = "Preview unavailable. Generation still validates the script before synthesis." }
        }
    }
}

struct SpeechEditor: View {
    @Binding var text: String
    var rules: String = ""
    var matchMode: String = "words"
    var nativeControls: Bool = true
    var minimumHeight: CGFloat = 110
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var phonemes = ""
    @State private var pinyin = ""
    private func insert(_ value: String) {
        guard let result = SpeechInsertion.insert(value, into: text, selection: selection) else { return }
        text = result.0; selection = result.1
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CursorTextEditor(text: $text, selection: $selection)
                .frame(height: minimumHeight).background(Color.black.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if nativeControls {
                HStack(spacing: 6) {
                    ForEach(NativeEvent.all.filter { $0.group == "Event" }) { event in
                        Button(event.label) { insert(event.token) }.help(event.token)
                    }
                    ForEach(["Question", "Surprise"], id: \.self) { group in
                        Menu(group) {
                            ForEach(NativeEvent.all.filter { $0.group == group }) { event in
                                Button("\(event.label) — \(event.token)") { insert(event.token) }.help(event.token)
                            }
                        }
                    }
                }.controlSize(.small)
                Text("Vocal events at the cursor, not persistent emotions. Native tags must use exact lowercase spelling.")
                    .font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Native pronunciation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Select a word to replace it. CMU uses uppercase symbols such as B EY1 S. Vowel stress 0/1/2 is pronunciation, not performance emphasis.").font(.caption)
                        HStack {
                            TextField("CMU phonemes: B EY1 S", text: $phonemes)
                            Button("Insert phonemes") { if let token = NativePronunciation.cmuToken(phonemes) { insert(token) } }
                                .disabled(NativePronunciation.cmuToken(phonemes) == nil)
                        }
                        if !phonemes.isEmpty && NativePronunciation.cmuToken(phonemes) == nil {
                            Text("Use uppercase CMU symbols without brackets; vowels require stress 0, 1 or 2.").font(.caption).foregroundStyle(.orange)
                        }
                        Text("Chinese: uppercase pinyin syllable + tone 1–5, for example ZHE2. Check the preview for errors; the app does not translate words into phonemes.").font(.caption)
                        HStack {
                            TextField("Pinyin: ZHE2", text: $pinyin)
                            Button("Insert pinyin") { if let value = NativePronunciation.pinyinValue(pinyin) { insert(value) } }
                                .disabled(NativePronunciation.pinyinValue(pinyin) == nil)
                        }
                        if !pinyin.isEmpty && NativePronunciation.pinyinValue(pinyin) == nil {
                            Text("Use uppercase pinyin with tone 1–5, separated by spaces. Spelling and the intended pronunciation must be checked by you.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            SpeechPreview(text: text, rules: rules, matchMode: matchMode)
        }
    }
}

struct PronunciationRulesEditor: View {
    @Binding var rules: String
    @Binding var matchInsideWords: Bool
    var body: some View {
        DisclosureGroup("Pronunciation Dictionary / replacements") {
            Text("One original=replacement rule per line. Use ordinary respelling, [B EY1 S] or uppercase pinyin tones. Native markup is protected; empty replacements do not delete text.")
                .font(.caption)
            TextEditor(text: $rules).font(.system(.caption, design: .monospaced)).frame(height: 80)
            Toggle("Match inside words (legacy substring behavior)", isOn: $matchInsideWords).font(.caption)
            Text("Default matches whole Latin words/phrases, case-sensitively. Chinese phrases match directly. Rules run in order; preview the result above.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
