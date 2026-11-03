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
    var font: NSFont = .systemFont(ofSize: 14)
    var lineSpacing: CGFloat = 0
    var inset = NSSize(width: 8, height: 8)
    /// Fixed line height draws ruled "notebook" paper; 0 keeps natural lines.
    var ruledLineHeight: CGFloat = 0
    /// Character ranges to underline (Take Doctor); display only, never part of the text.
    var marks: [NSRange] = []
    /// Which text this editor shows (e.g. the mode's script). Replacing text within the same
    /// document is undoable; switching to another document is not.
    var document: String = ""
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var paragraph: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        if ruledLineHeight > 0 {
            paragraph.minimumLineHeight = ruledLineHeight
            paragraph.maximumLineHeight = ruledLineHeight
        } else {
            paragraph.lineSpacing = lineSpacing
        }
        return paragraph
    }

    /// Font, line spacing and the appearance-aware text colour every character must carry.
    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll: NSScrollView
        let view: NSTextView
        if ruledLineHeight > 0 {
            scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let ruled = RuledTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            ruled.lineHeight = ruledLineHeight
            ruled.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            ruled.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ruled.isVerticallyResizable = true
            ruled.isHorizontallyResizable = false
            ruled.autoresizingMask = [.width]
            ruled.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            ruled.textContainer?.widthTracksTextView = true
            scroll.documentView = ruled
            view = ruled
        } else {
            scroll = NSTextView.scrollableTextView()
            view = scroll.documentView as! NSTextView
        }
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = font
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        view.drawsBackground = false
        view.textContainerInset = inset
        scroll.drawsBackground = false
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
        if view.string != text {
            let sameDocument = context.coordinator.document == document
            context.coordinator.document = document
            if sameDocument, let storage = view.textStorage,
               view.shouldChangeText(in: NSRange(location: 0, length: storage.length), replacementString: text) {
                // Through the text system, so ⌘Z takes back Clear Script, Paste Script, examples and
                // inserted tokens (setting `string` directly could not be undone).
                // With explicit attributes: a bare string here had no colour and drew black on the
                // dark page (Cast script unreadable in dark mode, 2026-11-03).
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                          with: NSAttributedString(string: text, attributes: textAttributes))
                view.didChangeText()
            } else {
                view.string = text
            }
            if let storage = view.textStorage, storage.length > 0 {
                storage.addAttributes(textAttributes, range: NSRange(location: 0, length: storage.length))
            }
        }
        if context.coordinator.marks != marks, let layout = view.layoutManager {
            context.coordinator.marks = marks
            let full = NSRange(location: 0, length: (view.string as NSString).length)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            let red = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xFF5B3F) : NSColor(hex: 0xD9301C) }
            for range in marks where NSMaxRange(range) <= full.length {
                layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                               .underlineColor: red], forCharacterRange: range)
            }
        }
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
        var marks: [NSRange] = []
        var document: String
        init(_ parent: CursorTextEditor) { self.parent = parent; document = parent.document }
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

/// Text view on ruled paper: a faint rule under every line and a margin rule.
final class RuledTextView: NSTextView {
    var lineHeight: CGFloat = 28
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let rule = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: 0x2F2E2A) : NSColor(hex: 0xE3DED2)
        }
        rule.setFill()
        let top = textContainerInset.height
        let bottomPadding: CGFloat = 6
        var y = top + lineHeight - bottomPadding
        let lastY = max(bounds.maxY, rect.maxY)
        while y < lastY {
            if y >= rect.minY - 1 { NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill() }
            y += lineHeight
        }
        let margin = textContainerInset.width - 12
        if margin > 0 {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(hex: 0x3A2A27) : NSColor(hex: 0xEBC9C0)
            }.setFill()
            NSRect(x: margin, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }
}

struct SpeechInspection: Decodable {
    struct Issue: Decodable { let level: String; let message: String }
    let text: String
    let issues: [Issue]
    let can_generate: Bool
}
