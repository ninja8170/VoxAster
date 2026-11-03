import SwiftUI
import AppKit

// MARK: - Studio: script on paper, output strip beneath

struct StudioView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var doctor: TakeDoctor
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if ui.castActive {
                    CastSheet()
                    CastPanel().frame(height: max(180, geo.size.height * 0.38))
                } else {
                    ScriptSheet(selection: $selection)
                    Group {
                        switch model.scriptMode {
                        case .take: TakesRoll()
                        case .longForm: SegmentsPanel()
                        case .performance: ProductionPanel()
                        }
                    }
                    // The work below the page gets a fixed share, so nothing is squeezed out.
                    .frame(height: max(180, geo.size.height * 0.38))
                }
            }
            .padding(16)
        }
        // Take Doctor listens to each new take against the script it was made from.
        .onChange(of: model.outputURL) { _, url in
            guard let url, !ui.castActive, model.scriptMode == .take else { return }
            let script = model.generations.first { $0.path == url.path }?.text ?? model[keyPath: model.scriptKey]
            doctor.check([url], script: script)
        }
        .onChange(of: model.variantURLs) { _, urls in
            guard !urls.isEmpty, model.scriptMode == .take else { return }
            doctor.check(urls, script: model.cloneText)
        }
    }
}

// MARK: Script page

struct ScriptSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var doctor: TakeDoctor
    @Binding var selection: NSRange

    private var marks: [NSRange] {
        guard model.scriptMode == .take,
              let report = doctor.report(for: model.outputURL, script: text.wrappedValue) else { return [] }
        return report.flagged.map(\.range)
    }

    private var text: Binding<String> { model.binding(model.scriptKey) }
    private var matchMode: String { model[keyPath: model.matchKey] ? "substring" : "words" }

    var body: some View {
        VStack(spacing: 0) {
            VoicePlate()
            Hairline()
            EventBar(text: text, selection: $selection, performance: model.scriptMode == .performance)
            Hairline()
            ZStack(alignment: .topLeading) {
                CursorTextEditor(text: text, selection: $selection, font: Trace.scriptNSFont,
                                 inset: NSSize(width: 44, height: 14), ruledLineHeight: 30, marks: marks,
                                 document: "\(model.scriptKey)")
                if text.wrappedValue.isEmpty {
                    ScriptExample(mode: model.studioMode) { text.wrappedValue = $0 }
                        .padding(.leading, 49).padding(.top, 19).padding(.trailing, 28)
                }
            }
            Hairline()
            ScriptFooter(text: text.wrappedValue, rules: model[keyPath: model.rulesKey], matchMode: matchMode)
        }
        .traceSheet()
    }

}

/// Shown in the empty speech box: a worked example for this mode, how to use
/// it, and a way to drop the example in to try it.
struct ScriptExample: View {
    let mode: StudioMode
    let use: (String) -> Void

    private var example: String {
        switch mode {
        case .clone:
            return "Welcome back to the show. [laughter] I honestly didn't think we'd make it this far. [sigh] So, shall we begin?"
        case .design:
            return "Good evening. This is the late news, read by a voice that has never existed before."
        case .longForm:
            return "Chapter one. The harbour was quiet before dawn, and the boats sat low in the black water. Mara walked the length of the pier twice before she saw the light. It was coming from the lighthouse, which had been dark for eleven years."
        case .performance:
            return "Ladies and gentlemen. [pause 800ms] The moment you have been waiting for. [louder] Here it is! [pause 400ms] [quieter] Thank you."
        case .cast:
            return "NARRATOR: The lighthouse had been dark for eleven years.\nMARA: Did you see that? [surprise-oh]\nTOM: See what? [sigh] It's just the moon.\nMARA: No. Someone is up there."
        }
    }

    private var tip: String {
        switch mode {
        case .clone:
            return "Write what the recorded voice should say. Drop in a laugh, sigh or question sound at the cursor from the bar above, then press ⌘G. Each result lands in Takes below."
        case .design:
            return "Describe a new voice in the Voice panel (gender, age, pitch, accent) or pick a preset such as Audiobook. Then write the line and press ⌘G."
        case .longForm:
            return "Paste a whole script: a chapter, an article, a narration. It is split at sentence ends into segments below; edit or re-render any one, and they are joined into a single master."
        case .performance:
            return "Place exact pauses in milliseconds and louder/quieter changes from the bar above. Prepare freezes the production so single segments can be re-rendered without changing the rest."
        case .cast:
            return "Start each line with a name and a colon. Give every name a voice in the cast list above (a saved voice or a designed one), then render the scene. Lines without a name continue the previous speaker."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(example)
                .font(.system(size: 17, design: .serif).italic())
                .lineSpacing(9)
                .foregroundStyle(Trace.pencil)
                .allowsHitTesting(false)
            Text(tip)
                .font(.traceCaption)
                .foregroundStyle(Trace.graphite)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
            Button("Use this example") { use(example) }
                .buttonStyle(.link)
                .font(.traceCaption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Example for \(mode.rawValue)")
    }
}

/// The voice, presented like a specimen plate: its name, its particulars, and
/// its line drawn across the page. A designed voice gets a drawn signature.
struct VoicePlate: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var cleaner: ReferenceCleaner
    @State private var dropTarget = false

    private var designed: Bool { model.voiceSource == .designed && model.scriptMode == .take }

    private var particulars: String {
        if designed {
            let d = model.designedDescriptors
            return d.isEmpty ? "designed · set it in the panel" : "designed · " + d.joined(separator: " · ")
        }
        guard model.referenceURL != nil else { return "no reference yet" }
        var parts = ["reference"]
        if model.referenceAnalysisReady {
            parts.append("quality\u{00A0}\(model.referenceQualityScore)")
            if model.referencePitch > 0 { parts.append("\(Int(model.referencePitch))\u{00A0}Hz") }
            parts.append(model.referencePaceLabel.lowercased())
        }
        if model.referenceText.isEmpty { parts.append("no transcript") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.voiceDisplayName)
                    .font(.system(size: 25, weight: .medium, design: .serif))
                    .foregroundStyle(Trace.ink)
                    .lineLimit(2).minimumScaleFactor(0.75)
                Text(particulars)
                    .font(.traceValue).foregroundStyle(Trace.graphite)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !designed && model.referenceURL != nil && !model.referenceAnalysisReady {
                    Button("Analyze voice") {
                        ui.showInspector = true; ui.inspectorTab = .voice; model.analyzeReference()
                    }
                    .buttonStyle(.link).font(.traceCaption)
                    .disabled(model.referenceAnalyzing)
                }
            }
            .frame(width: 210, alignment: .leading)

            Group {
                if designed {
                    DesignedSignature(seedText: model.designedDescriptors.joined() + model.designPreset,
                                      pitch: model.designPitch, whisper: model.designStyle == "whisper")
                } else if let url = model.referenceURL {
                    PlayerTrace(url: url, controller: model.referencePlayer, showRuler: true,
                                highlight: cleaner.result(for: url).map { $0.start...$0.end })
                } else {
                    Button { model.chooseReference() } label: {
                        VStack(spacing: 6) {
                            Rectangle().fill(dropTarget ? Trace.cobalt : Trace.rule).frame(height: 1)
                            Text("Drop a voice clip here, or click to choose one. 5–20 seconds of clear speech works best.")
                                .font(.traceCaption).foregroundStyle(Trace.graphite)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(dropTarget ? Trace.cobalt.opacity(0.06) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            model.setVoiceSource(.reference)
            return model.acceptDroppedAudio(providers)
        }
    }
}

/// Native vocal events and directions, inserted at the cursor.
struct EventBar: View {
    @Binding var text: String
    @Binding var selection: NSRange
    var performance: Bool
    @State private var showPronounce = false
    @State private var pauseMs = "500"

    private func insert(_ value: String) {
        guard let result = SpeechInsertion.insert(value, into: text, selection: selection) else { return }
        text = result.0; selection = result.1
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(NativeEvent.all.filter { $0.group == "Event" }) { event in
                Button(event.label) { insert(event.token) }.help("Insert \(event.token) at the cursor")
            }
            ForEach(["Question", "Surprise"], id: \.self) { group in
                Menu {
                    ForEach(NativeEvent.all.filter { $0.group == group }) { event in
                        Button("\(event.label)  \(event.token)") { insert(event.token) }
                    }
                } label: { Text(group).foregroundStyle(Trace.ink) }
                .menuStyle(.borderlessButton).fixedSize().tint(Trace.ink)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Trace.rule))
            }
            Button("Pronounce…") { showPronounce.toggle() }
                .popover(isPresented: $showPronounce, arrowEdge: .bottom) { PronouncePopover(insert: insert) }
                .help("Insert CMU phonemes or pinyin at the cursor")
            if performance {
                Hairline(vertical: true).frame(height: 16).padding(.horizontal, 4)
                TextField("ms", text: $pauseMs).frame(width: 52).textFieldStyle(.roundedBorder).controlSize(.small)
                    .font(.traceValue)
                Button("Pause") { if let token = PerformanceDirection.pauseInput(pauseMs) { insert(token) } }
                    .disabled(PerformanceDirection.pauseInput(pauseMs) == nil)
                    .help("Exact silence of 1–10000 ms between independently generated segments")
                Button("Louder") { insert(PerformanceDirection.louder) }.help("+3 dB on the following speech, not shouting")
                Button("Quieter") { insert(PerformanceDirection.quieter) }.help("−3 dB on the following speech, not whispering")
            }
            Spacer(minLength: 8)
            Menu {
                // Both are undoable with ⌘Z in the script.
                Button("Replace with Clipboard") { if let s = NSPasteboard.general.string(forType: .string) { text = s } }
                Button("Clear Script", role: .destructive) { text = "" }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Script actions")
        }
        .buttonStyle(TokenButtonStyle())
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct PronouncePopover: View {
    let insert: (String) -> Void
    @State private var phonemes = ""
    @State private var pinyin = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Pronunciation at the cursor")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("CMU phonemes, e.g. B EY1 S", text: $phonemes).textFieldStyle(.roundedBorder).font(.traceValue)
                    Button("Insert") { if let t = NativePronunciation.cmuToken(phonemes) { insert(t); phonemes = "" } }
                        .disabled(NativePronunciation.cmuToken(phonemes) == nil)
                }
                Text(!phonemes.isEmpty && NativePronunciation.cmuToken(phonemes) == nil
                     ? "Uppercase CMU symbols; vowels need stress 0, 1 or 2."
                     : "Select a word first to replace it.")
                    .font(.traceCaption)
                    .foregroundStyle(!phonemes.isEmpty && NativePronunciation.cmuToken(phonemes) == nil ? Trace.record : Trace.graphite)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Pinyin, e.g. ZHE2", text: $pinyin).textFieldStyle(.roundedBorder).font(.traceValue)
                    Button("Insert") { if let v = NativePronunciation.pinyinValue(pinyin) { insert(v); pinyin = "" } }
                        .disabled(NativePronunciation.pinyinValue(pinyin) == nil)
                }
                Text(!pinyin.isEmpty && NativePronunciation.pinyinValue(pinyin) == nil
                     ? "Uppercase syllables with tone 1–5, separated by spaces."
                     : "Check the result in the model preview.")
                    .font(.traceCaption)
                    .foregroundStyle(!pinyin.isEmpty && NativePronunciation.pinyinValue(pinyin) == nil ? Trace.record : Trace.graphite)
            }
        }
        .padding(16).frame(width: 340)
    }
}

/// Counts, validation issues and (optionally) what the model receives.
struct ScriptFooter: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    let text: String
    let rules: String
    let matchMode: String
    @State private var inspection: SpeechInspection?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DoctorLine(script: text)
            if ui.showModelPreview, let inspection {
                Text(inspection.text.isEmpty ? "—" : inspection.text)
                    .font(.traceValue).foregroundStyle(Trace.graphite)
                    .textSelection(.enabled).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if let issue = inspection?.issues.first {
                    Label(issue.message, systemImage: issue.level == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(.traceCaption)
                        .foregroundStyle(issue.level == "error" ? Trace.record : Trace.graphite)
                        .lineLimit(1)
                        .help(inspection?.issues.map(\.message).joined(separator: "\n") ?? "")
                }
                Spacer()
                Toggle("Model view", isOn: $ui.showModelPreview)
                    .toggleStyle(.checkbox).controlSize(.small).font(.traceCaption)
                    .help("Show the text after pronunciation rules, exactly as the model receives it")
                Text("≈ \(timecode(model.estimatedSeconds(text))) spoken · \(text.split { $0.isWhitespace }.count) words")
                    .font(.traceCaption.monospacedDigit()).foregroundStyle(Trace.graphite)
                    .help("Estimate at the current Speed; the engine decides the exact length.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .task(id: [text, rules, matchMode, String(model.scriptMode == .performance)]) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                inspection = try await model.inspectSpeech(text: text, rules: rules, matchMode: matchMode,
                                                           performance: model.scriptMode == .performance)
            } catch is CancellationError {
            } catch { inspection = nil }
        }
    }
}

// MARK: Long Form segments

struct SegmentsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Segments", trailing: model.productionChunks.isEmpty ? nil : "\(model.productionChunks.filter { $0.state == "Complete" }.count)/\(model.productionChunks.count) rendered")
                if model.longFormOutputURL == nil && model.canRebuildLongForm {
                    Button("Rebuild Master") { model.rebuildLongFormMaster() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent).tint(Trace.cobaltFill)
                        .disabled(model.isGenerating || !model.modelReady)
                        .help("Join the segments as they are into a new master, without rendering any again")
                }
                Button("Split Script") { model.prepareProductionChunks() }
                    .controlSize(.small)
                    .disabled(model.longFormText.isEmpty || model.isGenerating)
                    .help("Split the script at sentence boundaries so segments can be edited and retried individually")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Hairline()
            if model.isGenerating {
                Stylus(progress: model.longFormProgress, label: model.longFormStatus.lowercased())
                    .frame(height: 40).padding(.horizontal, 14).padding(.vertical, 8)
                Hairline()
            } else if let master = model.longFormOutputURL {
                MasterRow(url: master)
                Hairline()
            }
            if model.productionChunks.isEmpty {
                EmptyNote(title: "No segments yet", detail: "Render splits the script automatically, or split it now to edit segments first.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.productionChunks.enumerated()), id: \.element.id) { index, chunk in
                            SegmentRow(index: index, chunk: chunk)
                            Hairline()
                        }
                    }
                }
            }
        }
        .traceSheet()
        .padding(.top, 10)
    }
}

struct SegmentRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let chunk: AppModel.ProductionChunk

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1)).font(.traceValue).foregroundStyle(Trace.pencil)
                .padding(.top, 3)
            TextField("Segment text", text: Binding(
                get: { model.productionChunks.indices.contains(index) ? model.productionChunks[index].text : "" },
                set: { model.updateChunk(index, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .serif))
                .lineLimit(1...4)
            Text(chunk.state)
                .font(.traceValue)
                .foregroundStyle(chunk.state == "Complete" ? Trace.ok : (chunk.state == "Generating" ? Trace.record : Trace.graphite))
                .frame(width: 76, alignment: .trailing)
            if let output = chunk.output {
                PlayToggle(player: model.outputPlayer, url: output, help: "Play segment")
            }
            Button { model.retryChunk(index) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isGenerating || !model.modelReady)
                .help("Render this segment again")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: Performance production

struct ProductionPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let job = model.performanceProduction {
                    Text("Production").font(.traceSection)
                    Text("\(job.id.prefix(8)) · seed \(job.base_seed) · \(job.voice.reference_name)")
                        .font(.traceValue).foregroundStyle(Trace.graphite).lineLimit(1)
                        .help("Engine \(job.voice.engine) · reference \(job.voice.reference_sha256.prefix(12))\n\(job.voice.resolved_ref_text ?? "")")
                } else {
                    Text("No production").font(.traceSection)
                }
                Spacer()
                Menu("Open") {
                    if model.performanceHistory.isEmpty { Text("No saved productions") }
                    ForEach(model.performanceHistory) { item in
                        Button("\(prettyTimestamp(item.created_at)) — \(item.script.prefix(40))") { model.loadPerformance(item.id) }
                    }
                }
                .fixedSize().controlSize(.small).disabled(model.performanceBusy)
                if let job = model.performanceProduction {
                    Button("Render Missing") { model.renderPerformance() }
                        .controlSize(.small)
                        .disabled(model.busy || !model.modelReady)
                    Button("Rebuild Master") { model.rebuildPerformance() }
                        .controlSize(.small)
                        .disabled(model.performanceBusy || job.segments.contains { $0.kind == "speech" && $0.output == nil })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            if model.performanceProduction != nil && model.performanceNeedsPrepare {
                Text("The script has changed since this production was prepared. Prepare again to use the edits.")
                    .font(.traceCaption).foregroundStyle(Trace.record)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            Hairline()
            if model.performanceBusy {
                Stylus(label: model.performanceStatus.lowercased())
                    .frame(height: 40).padding(.horizontal, 14).padding(.vertical, 8)
                Hairline()
            } else if let master = model.performanceProduction?.master {
                MasterRow(url: URL(fileURLWithPath: master))
                Hairline()
            }
            if let job = model.performanceProduction {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(job.segments) { segment in
                            PerformanceSegmentRow(segment: segment)
                            Hairline()
                        }
                    }
                }
            } else {
                EmptyNote(title: "Prepare a production to freeze its segments",
                          detail: "Prepared segments keep their seeds and settings, so retries match.")
            }
            Text(model.performanceStatus).font(.traceCaption).foregroundStyle(Trace.graphite)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .traceSheet()
        .padding(.top, 10)
        .onAppear { model.refreshPerformances() }
    }
}

struct PerformanceSegmentRow: View {
    @EnvironmentObject var model: AppModel
    let segment: PerformanceProduction.Segment

    var body: some View {
        if segment.kind == "pause" {
            // A pause is a flat line with its exact length written above it.
            HStack(spacing: 10) {
                Rectangle().fill(Trace.ink).frame(height: 1)
                Text("\(segment.milliseconds ?? 0) ms").font(.traceValue).foregroundStyle(Trace.graphite)
                Rectangle().fill(Trace.ink).frame(height: 1)
            }
            .padding(.horizontal, 40).padding(.vertical, 8)
            .help("\(segment.samples ?? 0) exact samples of silence")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    Text(segment.text ?? "").font(.system(size: 13, design: .serif)).textSelection(.enabled)
                    Spacer()
                    Text(segment.state).font(.traceValue)
                        .foregroundStyle(segment.output != nil ? Trace.ok : Trace.graphite)
                    Button { model.renderPerformance(segment.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(model.busy || !model.modelReady)
                        .help("Render only this segment again (keeps its seed)")
                }
                if let path = segment.output {
                    PlayerTrace(url: URL(fileURLWithPath: path), controller: model.outputPlayer, showRuler: false)
                        .frame(height: 30)
                }
                HStack(spacing: 10) {
                    Text("seed \(segment.seed ?? 0)")
                    Text("gain \(segment.gain_db ?? 0) dB")
                    if let s = segment.request { Text("speed \(String(format: "%.2f", s.speed)) · steps \(s.steps)") }
                }
                .font(.traceValue).foregroundStyle(Trace.pencil)
                if let error = segment.last_error {
                    Text(error).font(.traceCaption).foregroundStyle(Trace.record)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }
}

// MARK: - Takes roll

/// Every take collects under the page like a chart-recorder roll; the newest on top.
struct TakesRoll: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI

    private var allTakes: [AppModel.Generation] { model.generations.filter { $0.mode != "Long Form" } }

    var body: some View {
        // Takes shown in the comparison lanes above aren't listed again below them.
        let every = allTakes
        let comparing = model.voiceSource == .reference ? Set(model.variantURLs.map(\.path)) : []
        let numbered = Array(every.enumerated().lazy.filter { !comparing.contains($0.element.path) }.prefix(40))
        let takes = numbered.map(\.element)
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Takes", trailing: allTakes.isEmpty ? nil : "\(allTakes.count)")
                Button("Show All") { ui.place = .takes }
                    .buttonStyle(.borderless).font(.traceCaption)
                    .disabled(allTakes.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Hairline()
            if takes.isEmpty && !model.isGenerating && (model.variantURLs.isEmpty || model.voiceSource != .reference) {
                EmptyNote(title: "Your takes collect here", detail: model.modelReady ? "Write a line above and press ⌘G." : model.status)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.isGenerating {
                            Stylus(label: model.variantCount > 1 && ui.takes > 1 ? "drawing \(ui.takes) takes" : "drawing take")
                                .frame(height: 44)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                            Hairline()
                        }
                        if !model.variantURLs.isEmpty && model.voiceSource == .reference {
                            VariantLanes().padding(.horizontal, 14).padding(.vertical, 10)
                            Hairline()
                        }
                        ForEach(numbered, id: \.element.id) { index, item in
                            TakeStrip(item: item, number: every.count - index, current: item.url == model.outputURL)
                            Hairline()
                        }
                    }
                }
            }
        }
        .traceSheet()
        .padding(.top, 10)
    }
}

struct TakeStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var doctor: TakeDoctor
    let item: AppModel.Generation
    let number: Int
    let current: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(number)").font(.traceValue).foregroundStyle(current ? Trace.cobalt : Trace.graphite)
                Text(item.createdAt.formatted(date: .omitted, time: .shortened)).font(.traceValue).foregroundStyle(Trace.pencil)
            }
            .frame(width: 58, alignment: .leading)
            Text(item.text)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(Trace.ink)
                .lineLimit(2)
                .frame(width: 200, alignment: .leading)
                .help(item.text)
            PlayerTrace(url: item.url, controller: model.outputPlayer, showRuler: current)
                .frame(height: current ? 50 : 28)
            DoctorScore(report: doctor.report(for: item.url), checking: doctor.isChecking(item.url))
                .frame(width: 30, alignment: .trailing)
            Menu {
                Button("Export…") { model.exportOutput(item.url) }
                ShareLink(item: item.url) { Text("Share…") }
                Button("Show in Finder") { model.reveal(item.url) }
                Divider()
                Button("Delete Take", role: .destructive) { model.deleteGeneration(item) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Take actions")
        }
        .padding(.horizontal, 14).padding(.vertical, current ? 12 : 8)
        .background(current ? Trace.cobalt.opacity(0.05) : Color.clear)
        .overlay(alignment: .leading) {
            if current { Rectangle().fill(Trace.cobalt).frame(width: 2) }
        }
        .contentShape(Rectangle())
    }
}

/// Master output of a Long Form or Performance render, shown at the top of its panel.
struct MasterRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Master").font(.traceSection)
                Spacer()
                OutputActions(url: url)
            }
            PlayerTrace(url: url, controller: model.outputPlayer).frame(height: 52)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct OutputActions: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    var body: some View {
        HStack(spacing: 14) {
            Button { model.exportOutput(url) } label: { Label("Export", systemImage: "square.and.arrow.down") }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { model.reveal(url) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.traceCaption)
        .foregroundStyle(Trace.graphite)
    }
}

struct VariantLanes: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var doctor: TakeDoctor
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(model.variantURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 10) {
                        Text("Take \(index + 1)").font(.traceValue).foregroundStyle(Trace.graphite).frame(width: 46, alignment: .leading)
                        PlayerTrace(url: url, controller: model.outputPlayer, showRuler: false).frame(height: 26)
                        DoctorScore(report: doctor.report(for: url), checking: doctor.isChecking(url),
                                    best: doctor.best(of: model.variantURLs) == url)
                            .frame(width: 64, alignment: .trailing)
                        Button { model.exportOutput(url) } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(.borderless).help("Export take \(index + 1)")
                        Button { model.reveal(url) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
            }
        }
    }
}
