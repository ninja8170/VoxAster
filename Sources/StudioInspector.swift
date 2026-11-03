import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StudioInspector: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI

    var body: some View {
        VStack(spacing: 0) {
            InkTabs(options: InspectorTab.allCases.map { ($0.rawValue, $0) }, selection: $ui.inspectorTab)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            Hairline()
            if ui.inspectorTab == .words {
                WordsInspector().padding(18)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if ui.inspectorTab == .voice { VoiceInspector() } else { RenderInspector() }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .traceSheet()
        .padding(.vertical, 16).padding(.trailing, 16).padding(.leading, 2)
        .background(Trace.ground.ignoresSafeArea())
        .buttonStyle(TokenButtonStyle())
    }
}

// MARK: Voice

struct VoiceInspector: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI

    var body: some View {
        if ui.castActive { CastInspector() } else { voiceBody }
    }

    @ViewBuilder private var voiceBody: some View {
        if model.scriptMode != .take {
            Text("\(model.scriptMode.rawValue) speaks with a recorded voice.")
                .font(.traceCaption).foregroundStyle(Trace.graphite)
        }

        if model.voiceSource == .designed && model.scriptMode == .take {
            DesignedVoiceSection()
        } else {
            ReferenceVoiceSection()
        }
    }
}

struct ReferenceVoiceSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @State private var voiceName = ""

    private func metric(_ label: String, _ value: String) -> some View {
        InspectorRow(label) { Text(value).font(.traceValue).foregroundStyle(Trace.ink) }
    }

    /// A saved voice's name typed into its transcript is a common mistake.
    private var transcriptLooksLikeName: Bool {
        let text = model.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        let names = [model.voiceDisplayName, model.referenceURL?.deletingPathExtension().lastPathComponent ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return names.contains(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Source")
                HStack(spacing: 8) {
                    Button("Choose File…") { model.chooseReference() }
                    RecordButton(recorder: model.recorder) { model.startRecording() }
                    Spacer()
                }
                if !model.savedVoices.isEmpty {
                    InspectorRow("Saved") {
                        Picker("Saved voice", selection: Binding(
                            get: { model.currentSavedVoice?.id },
                            set: { id in if let v = model.savedVoices.first(where: { $0.id == id }) { model.useVoice(v) } })) {
                            Text("—").tag(UUID?.none)
                            ForEach(model.savedVoices) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden()
                    }
                }
            }

            if model.referenceURL != nil {
                Hairline()
                CleanerSection()
            }

            if let url = model.referenceURL {
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Words in the clip")
                    TextField("Leave blank to transcribe automatically", text: $model.referenceText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    if transcriptLooksLikeName {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("This is the voice's name, not what is said in the recording. A wrong transcript makes the clone worse.")
                                .font(.traceCaption).foregroundStyle(Trace.record)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Clear") { model.referenceText = "" }
                        }
                    } else {
                        Text("Exactly what the person says in the recording, word for word. It helps the engine match sound to words. Leave it blank and it is transcribed for you. Ignored for clips over 20 s, which are trimmed.")
                            .font(.traceCaption).foregroundStyle(Trace.pencil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let unverified = model.unverifiedReferenceTranscript {
                        Text("Saved transcript needs review: \(unverified)").font(.traceCaption).foregroundStyle(Trace.record)
                            .textSelection(.enabled)
                        Button("Use After Checking the Recording") { model.acceptReviewedTranscript() }
                    }
                }

                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Analysis", trailing: model.referenceAnalysisReady ? "\(model.referenceQualityScore)/100" : nil)
                    if model.referenceAnalyzing {
                        HStack { ProgressView().controlSize(.small); Text("Measuring…").font(.traceBody).foregroundStyle(Trace.graphite) }
                    } else if model.referenceAnalysisReady {
                        metric("Quality", model.referenceQualityLabel)
                        metric("Pace", model.referenceWPM > 0 ? "\(model.referencePaceLabel) · \(Int(model.referenceWPM)) wpm" : model.referencePaceLabel)
                        metric("Pitch", model.referencePitch > 0 ? "\(Int(model.referencePitch)) Hz" : "—")
                        metric("Speech", "\(Int(model.referenceSpeechRatio * 100))% voiced")
                        metric("Level", String(format: "%.0f dB RMS", model.referenceRMS))
                        metric("Suggests", String(format: "%.2f× · %d steps · %.1f", model.recommendedSpeed, Int(model.recommendedSteps), model.recommendedGuidance))
                        HStack(spacing: 8) {
                            Button("Apply Suggestions") { model.applyReferenceRecommendations() }
                            Button("Measure Again") { model.analyzeReference() }
                        }
                        .padding(.top, 2)
                    } else {
                        Text("Measure the clip's quality, pitch and pace to get suggested settings.")
                            .font(.traceCaption).foregroundStyle(Trace.graphite)
                        Button("Analyze Voice") { model.analyzeReference() }
                    }
                }

                Hairline()
                Button("Save as Voice…") { voiceName = model.voiceDisplayName == "No Voice" ? url.deletingPathExtension().lastPathComponent : model.voiceDisplayName; ui.showSaveVoice = true }
                    .disabled(model.currentSavedVoice != nil)
                    .help(model.currentSavedVoice != nil ? "This voice is already saved." : "Keep this reference in your Voices")
            }
        }
        .task(id: "\(model.referenceURL?.path ?? "")|\(model.modelReady)") {
            // Measure automatically once the engine is up and the clip is verified.
            if model.modelReady, model.referenceURL != nil, model.referenceIdentity != nil,
               !model.referenceAnalysisReady, !model.referenceAnalyzing {
                model.analyzeReference()
            }
        }
        .sheet(isPresented: $ui.showSaveVoice) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Voice").font(.traceTitle)
                Text("Name this reference so you can pick it from the toolbar.").font(.traceBody).foregroundStyle(Trace.graphite)
                TextField("Voice name", text: $voiceName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { ui.showSaveVoice = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { model.saveCurrentVoice(named: voiceName); ui.showSaveVoice = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.automatic)
            }
            .padding(22).frame(width: 380)
        }
    }
}

struct RecordButton: View {
    @ObservedObject var recorder: RecorderController
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(Trace.record).frame(width: 7, height: 7)
                    .opacity(recorder.isRecording ? 1 : 0.85)
                Text(recorder.isRecording ? "Stop  \(timecode(recorder.elapsed, tenths: true))" : "Record")
                    .monospacedDigit()
            }
        }
        .help(recorder.isRecording ? "Stop recording" : "Record a reference with the Mac microphone (⇧⌘R)")
    }
}

struct DesignedVoiceSection: View {
    @EnvironmentObject var model: AppModel

    private let presets = ["Audiobook", "News Anchor", "NPC", "Podcast", "Language Tutor", "Customer Support", "Whisper"]

    private func picker(_ label: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        InspectorRow(label) {
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { Text($0 == "Auto" ? "Auto" : $0.capitalized).tag($0) }
            }
            .labelsHidden()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorRow("Mode") {
                InkTabs(options: [("Describe", "Design"), ("Automatic", "Auto")], selection: $model.designMode, size: 12)
            }
            if model.designMode == "Auto" {
                Text("The engine invents a fitting speaker for the script.").font(.traceCaption).foregroundStyle(Trace.graphite)
            } else {
                InspectorRow("Preset") {
                    Menu(model.designPreset == "Custom" ? "Custom" : model.designPreset) {
                        ForEach(presets, id: \.self) { name in Button(name) { model.applyDesignPreset(name) } }
                    }
                }
                Hairline()
                picker("Gender", $model.designGender, ["Auto", "male", "female"])
                picker("Age", $model.designAge, ["Auto", "child", "teenager", "young adult", "middle-aged", "elderly"])
                picker("Pitch", $model.designPitch, ["Auto", "very low pitch", "low pitch", "moderate pitch", "high pitch", "very high pitch"])
                picker("Delivery", $model.designStyle, ["Auto", "whisper"])
                picker("Accent", $model.designAccent, ["Auto", "American accent", "British accent", "Australian accent", "Canadian accent", "Indian accent", "Chinese accent", "Japanese accent", "Korean accent", "Portuguese accent", "Russian accent"])
                if model.designAccent == "Chinese accent" {
                    picker("Dialect", $model.designDialect, ["Auto", "河南话", "陕西话", "四川话", "贵州话", "云南话", "桂林话", "济南话", "石家庄话", "甘肃话", "宁夏话", "青岛话", "东北话"])
                }
            }
        }
    }
}

// MARK: Render

struct RenderInspector: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @AppStorage("inspectorAdvancedOpen") private var showAdvanced = true
    @AppStorage(TakeDoctor.enabledKey) private var doctorOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorRow("Preset") {
                Picker("Preset", selection: Binding(get: { model.preset }, set: { model.applyPreset($0) })) {
                    ForEach(["Fast Preview", "Natural", "Narration", "Maximum Quality", "Auto Tuned"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            ValueSlider(label: "Speed", value: $model.speed, range: 0.5...1.5, format: "%.2f",
                        help: "Overall pacing of the speech")
            ValueSlider(label: "Steps", value: $model.steps, range: 8...64, format: "%.0f",
                        help: "More steps: slower, often cleaner")
            if model.scriptMode != .longForm {
                ValueSlider(label: "Guidance", value: $model.guidance, range: 0...4, format: "%.1f",
                            help: "How strongly the voice and text are followed. Not emotional intensity.")
            }
            if model.scriptMode == .take && model.voiceSource == .reference {
                InspectorRow("Takes") {
                    InkTabs(options: (1...4).map { ("\($0)", $0) }, selection: $ui.takes, size: 13)
                        .help("Generate up to four takes of the same line with different seeds")
                }
            }
            Toggle("Take Doctor: listen to every take", isOn: $doctorOn)
                .toggleStyle(.checkbox).font(.traceBody)
                .help("Transcribe each take on this Mac, score it against the script and flag wrong or missing words")
            Hairline()
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                AdvancedRender(allowDuration: model.scriptMode == .take)
                    .padding(.top, 10)
            }
            .font(.traceSection)
        }
    }
}

struct AdvancedRender: View {
    @EnvironmentObject var model: AppModel
    var allowDuration: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Denoise output", isOn: $model.denoiseOutput).font(.traceBody)
                .help("Cleaner-speech conditioning when a reference is present")
            InspectorRow("Seed") {
                TextField("0 = random", value: $model.generationSeed, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder).font(.traceValue)
                    .help("0 keeps sampling random. A fixed seed repeats a result for comparisons.")
            }
            if allowDuration {
                Toggle("Fixed duration", isOn: $model.useDuration).font(.traceBody)
                    .help("Overrides speed-based length. Silence trimming can still shorten the result.")
                if model.useDuration {
                    InspectorRow("Seconds") {
                        TextField("10", value: $model.targetDuration, format: .number)
                            .textFieldStyle(.roundedBorder).font(.traceValue)
                    }
                }
            }
            ValueSlider(label: "Time shift", value: $model.timeShift, range: 0.001...1, format: "%.3f",
                        help: "t_shift: the decoding schedule, not speech timing. Default 0.1.")
            ValueSlider(label: "Position temperature", value: $model.positionTemperature, range: 0...20, format: "%.1f",
                        help: "Randomness in which audio positions are filled next. Default 5.")
            ValueSlider(label: "Token temperature", value: $model.classTemperature, range: 0...20, format: "%.1f",
                        help: "Randomness in token choice; 0 is greedy. Default 0.")
            ValueSlider(label: "Layer penalty", value: $model.layerPenaltyFactor, range: 0...20, format: "%.1f",
                        help: "Prefers filling earlier codebook layers first. Default 5.")
            Button("Reset to Defaults") { model.resetGenerationDefaults() }
        }
    }
}

// MARK: Words

struct WordsInspector: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Pronunciation", trailing: model.scriptMode.rawValue.lowercased())
            Text("One rule per line, original = replacement. Plain respelling, CMU phonemes or pinyin.")
                .font(.traceCaption).foregroundStyle(Trace.graphite)
            ZStack(alignment: .topLeading) {
                CursorTextEditor(text: model.binding(model.rulesKey), selection: $selection,
                                 font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                 inset: NSSize(width: 6, height: 6), ruledLineHeight: 26)
                if model[keyPath: model.rulesKey].isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(["Siobhan = Shiv-awn", "bass = [B EY1 S]", "VoxAster = Vox Aster"], id: \.self) { line in
                            Text(line).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Trace.pencil)
                                .frame(height: 26, alignment: .bottomLeading)
                        }
                    }
                    .padding(.leading, 11).padding(.top, 2)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().fill(Trace.rule).frame(height: 1), alignment: .top)
            Toggle("Match inside words", isOn: model.binding(model.matchKey))
                .toggleStyle(.checkbox)
                .font(.traceBody)
                .help("Off: whole words and phrases only, case-sensitive. On: legacy substring matching.")
            Text("Tick Model view under the script to see the result.").font(.traceCaption).foregroundStyle(Trace.pencil)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
