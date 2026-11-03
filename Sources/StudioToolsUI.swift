import SwiftUI
import AppKit

// MARK: - Reference Cleaner (Voice inspector)

struct CleanerSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cleaner: ReferenceCleaner
    @State private var duration: Double = 0
    @State private var showSave = false
    @State private var name = ""

    var body: some View {
        if let url = model.referenceURL {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Cleaner", trailing: duration > 0 ? timecode(duration) : nil)
                if let result = cleaner.result(for: url) {
                    InspectorRow("Best part") {
                        Text("\(timecode(result.start)) – \(timecode(result.end)) · \(result.score)/100")
                            .font(.traceValue).foregroundStyle(Trace.ink)
                    }
                    Text("“\(result.transcript)”")
                        .font(.system(size: 13, design: .serif).italic())
                        .foregroundStyle(Trace.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if result.score < 50 {
                        Text("Even the best part of this clip is weak: noisy, quiet or mostly silence. A new recording will clone better.")
                            .font(.traceCaption).foregroundStyle(Trace.record)
                    }
                    HStack(spacing: 8) {
                        Button { model.referencePlayer.toggle(result.url) } label: {
                            Text(model.referencePlayer.isPlaying(result.url) ? "Stop" : "Listen")
                        }
                        Button("Use This Clip") { cleaner.use(model) }
                        Button("Use & Save…") { name = model.voiceDisplayName + " (clean)"; showSave = true }
                    }
                } else if cleaner.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Listening for the cleanest stretch…").font(.traceCaption).foregroundStyle(Trace.graphite)
                    }
                } else {
                    Text(duration > 20
                         ? "This clip is \(timecode(duration)) long. Long clips slow generation and blur the voice. Find the cleanest 12 seconds of one person speaking, transcribed exactly."
                         : "Find the cleanest stretch of the clip and transcribe it exactly.")
                        .font(.traceCaption)
                        .foregroundStyle(duration > 20 ? Trace.ink : Trace.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Find the Best 12 Seconds") { cleaner.run(model) }
                        .disabled(!model.modelReady || model.busy)
                }
            }
            .task(id: url) { duration = audioDuration(url) }
            .sheet(isPresented: $showSave) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Save Clean Voice").font(.traceTitle)
                    Text("The cleaned clip and its transcript are saved as a new voice. The original is kept.")
                        .font(.traceBody).foregroundStyle(Trace.graphite)
                    TextField("Voice name", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Cancel") { showSave = false }.keyboardShortcut(.cancelAction)
                        Button("Use & Save") { cleaner.use(model, saveAs: name); showSave = false }
                            .keyboardShortcut(.defaultAction)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .buttonStyle(.automatic)
                }
                .padding(22).frame(width: 400)
            }
        }
    }
}

// MARK: - Take Doctor

/// Score shown on a take: plain numerals, coloured only when it matters.
struct DoctorScore: View {
    let report: TakeReport?
    var checking = false
    var best = false

    var body: some View {
        Group {
            if checking {
                Text("···").foregroundStyle(Trace.pencil).help("Take Doctor is listening")
            } else if let report {
                HStack(spacing: 4) {
                    Text("\(report.score)")
                        .foregroundStyle(report.score >= 90 ? Trace.ok : (report.score >= 70 ? Trace.graphite : Trace.record))
                    if best { Text("best").foregroundStyle(Trace.cobalt) }
                }
                .help(helpText(report))
            }
        }
        .font(.traceValue)
    }

    private func helpText(_ report: TakeReport) -> String {
        var lines = ["Take Doctor \(report.score)/100", "Heard: \(report.transcript)"]
        if !report.flagged.isEmpty { lines.append("Check: " + report.flagged.map(\.text).joined(separator: ", ")) }
        lines += report.notes
        return lines.joined(separator: "\n")
    }
}

/// Under the script: what Take Doctor heard in the current take.
struct DoctorLine: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var doctor: TakeDoctor
    let script: String

    private var take: URL? { model.outputURL }

    var body: some View {
        if let take, model.scriptMode == .take {
            HStack(spacing: 8) {
                Text("Take Doctor").font(.traceCaption.weight(.semibold)).foregroundStyle(Trace.graphite)
                if doctor.isChecking(take) {
                    ProgressView().controlSize(.mini)
                    Text("listening to the take…").font(.traceCaption).foregroundStyle(Trace.graphite)
                } else if doctor.repairing {
                    ProgressView().controlSize(.mini)
                    Text("re-rendering a sentence…").font(.traceCaption).foregroundStyle(Trace.graphite)
                } else if let report = doctor.report(for: take, script: script) {
                    DoctorScore(report: report)
                    if report.flagged.isEmpty {
                        Text(report.notes.isEmpty ? "every word heard" : report.notes.joined(separator: " · "))
                            .font(.traceCaption).foregroundStyle(Trace.graphite).lineLimit(1)
                    } else {
                        Text("check").font(.traceCaption).foregroundStyle(Trace.graphite)
                        ForEach(Array(report.flagged.prefix(6).enumerated()), id: \.offset) { _, word in
                            Menu {
                                Text(word.status == "missing" ? "Not heard in the take" : "Heard as “\(word.heard ?? "?")”")
                                Button("Re-render This Sentence") {
                                    doctor.repair(take, sentence: word.sentence, script: script, model: model)
                                }
                                .disabled(model.busy)
                                Button("Add Pronunciation Rule") { addRule(for: word.text) }
                            } label: {
                                Text(word.text).underline(pattern: .dot, color: Trace.record)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .font(.traceCaption)
                        }
                        if report.flagged.count > 6 {
                            Text("+\(report.flagged.count - 6)").font(.traceCaption).foregroundStyle(Trace.graphite)
                        }
                    }
                } else if doctor.report(for: take) != nil {
                    Text("script changed since this take was checked").font(.traceCaption).foregroundStyle(Trace.pencil)
                } else if doctor.enabled {
                    Button("Check this take") { doctor.check([take], script: script) }
                        .buttonStyle(.link).font(.traceCaption)
                }
            }
        }
    }

    private func addRule(for word: String) {
        let key = model.rulesKey
        let rules = model[keyPath: key]
        let line = "\(word) = "
        if !rules.contains(line) {
            model[keyPath: key] = rules.isEmpty || rules.hasSuffix("\n") ? rules + line : rules + "\n" + line
        }
        ui.showInspector = true
        ui.inspectorTab = .words
    }
}

// MARK: - Cast

/// The cast list at the top of the Cast page, like a play's dramatis personae.
struct CastPlate: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore

    var body: some View {
        let speakers = cast.speakers
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cast").font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(Trace.ink)
                Text(speakers.isEmpty ? "no characters yet" : "\(speakers.count) characters · \(cast.parsed.count) lines")
                    .font(.traceValue).foregroundStyle(Trace.graphite)
                Spacer()
                TextField(cast.defaultSceneName, text: $cast.sceneName)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .serif)).foregroundStyle(Trace.ink)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 220)
                    .help("Scene name in the Library")
                Menu {
                    Button("Save as New Scene") { cast.saveScene(asNew: true) }
                        .disabled(cast.sceneID == nil)
                    Divider()
                    Button("New Scene") { cast.newScene() }.disabled(cast.busy)
                } label: {
                    Text(cast.sceneID == nil ? "Save Scene" : "Save")
                } primaryAction: {
                    cast.saveScene()
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.traceBody)
                .disabled(cast.script.isEmpty && cast.lines.isEmpty)
                .help(cast.sceneID == nil ? "Keep this scene, its voices and every rendered line in Library › Scenes" : "Update this scene in Library › Scenes")
            }
            if !speakers.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 6) {
                    ForEach(speakers, id: \.self) { speaker in
                        HStack(spacing: 10) {
                            Text(speaker).font(.traceValue.weight(.semibold)).foregroundStyle(Trace.ink)
                                .frame(width: 92, alignment: .leading).lineLimit(1)
                            CastVoicePicker(speaker: speaker)
                            Spacer(minLength: 4)
                            if let voice = cast.savedVoice(cast.assignments[speaker], model: model) {
                                TraceView(url: voice.url, showRuler: false, excerptSeconds: 3).frame(width: 56, height: 14)
                            } else if let value = cast.assignments[speaker], value.hasPrefix("design:") {
                                DesignedSignature(seedText: value, pitch: value, whisper: value.contains("Whisper")).frame(width: 56, height: 14)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}

struct CastVoicePicker: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore
    let speaker: String

    var body: some View {
        Menu {
            if !model.savedVoices.isEmpty {
                Section("Saved voices") {
                    ForEach(model.savedVoices) { voice in
                        Button(voice.name) { cast.assignments[speaker] = "voice:\(voice.id.uuidString)" }
                    }
                }
            }
            Section("Designed voices") {
                ForEach(CastStore.designedVoices, id: \.0) { item in
                    Button(item.0) { cast.assignments[speaker] = "design:\(item.0)" }
                }
            }
        } label: {
            Text(cast.voiceName(for: speaker, model: model) ?? "Choose a voice")
                .foregroundStyle(cast.voiceName(for: speaker, model: model) == nil ? Trace.record : Trace.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.traceBody)
    }
}

struct CastSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(spacing: 0) {
            CastPlate()
            Hairline()
            EventBar(text: $cast.script, selection: $selection, performance: false)
            Hairline()
            ZStack(alignment: .topLeading) {
                CursorTextEditor(text: $cast.script, selection: $selection, font: Trace.scriptNSFont,
                                 inset: NSSize(width: 44, height: 14), ruledLineHeight: 30)
                if cast.script.isEmpty {
                    ScriptExample(mode: .cast) { cast.script = $0 }
                        .padding(.leading, 49).padding(.top, 19).padding(.trailing, 28)
                }
            }
            Hairline()
            HStack {
                if !cast.unassigned.isEmpty {
                    Text("Give a voice to \(cast.unassigned.joined(separator: ", "))")
                        .font(.traceCaption).foregroundStyle(Trace.record).lineLimit(1)
                }
                Spacer()
                Text("≈ \(timecode(model.estimatedSeconds(cast.parsed.map(\.text).joined(separator: " ")) + Double(max(0, cast.parsed.count - 1)) * cast.gapMs / 1000)) scene · \(cast.parsed.count) lines")
                    .font(.traceCaption.monospacedDigit()).foregroundStyle(Trace.graphite)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .traceSheet()
    }
}

struct CastPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Scene", trailing: cast.status.isEmpty ? nil : cast.status)
                if cast.busy {
                    Button("Stop") { cast.cancel() }.controlSize(.small)
                } else if !cast.missing.isEmpty, !cast.lines.isEmpty {
                    Button(cast.failedCount > 0 ? "Retry Failed (\(cast.missing.count))" : "Render Remaining (\(cast.missing.count))") {
                        cast.retryMissing(model)
                    }
                    .controlSize(.small)
                    .disabled(!cast.canRetry(model))
                    .help("Render every line without audio, keep the rest, then join the scene")
                } else if !cast.lines.isEmpty {
                    Button("Join Again") { cast.rejoin(model) }
                        .controlSize(.small)
                        .disabled(!cast.canRetry(model))
                        .help("Join the rendered lines again with the current gap and room, without re-rendering")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Hairline()
            if cast.busy {
                Stylus(progress: cast.progress, label: cast.status.lowercased())
                    .frame(height: 40).padding(.horizontal, 14).padding(.vertical, 8)
                Hairline()
            } else if let master = cast.masterURL {
                MasterRow(url: master)
                Hairline()
            }
            if cast.lines.isEmpty {
                EmptyNote(title: "No scene rendered yet",
                          detail: "Each line is rendered in its character's voice, then joined with a \(Int(cast.gapMs)) ms gap in one shared room.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(cast.lines.enumerated()), id: \.element.id) { index, line in
                            HStack(alignment: .center, spacing: 12) {
                                Text(line.speaker).font(.traceValue.weight(.semibold)).foregroundStyle(Trace.ink)
                                    .frame(width: 84, alignment: .leading).lineLimit(1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.text).font(.system(size: 13, design: .serif)).lineLimit(line.parts == nil ? 2 : 7)
                                    if let error = line.error {
                                        Text(error).font(.traceCaption).foregroundStyle(Trace.record).lineLimit(1)
                                            .help(error)
                                    }
                                }
                                .frame(width: 220, alignment: .leading)
                                if let url = line.output {
                                    PlayerTrace(url: url, controller: model.outputPlayer, showRuler: false).frame(height: 26)
                                } else {
                                    Text(line.state).font(.traceValue)
                                        .foregroundStyle(line.state == "Failed" ? Trace.record : Trace.graphite)
                                    Spacer()
                                }
                                Button { cast.retry(index, model: model) } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.borderless)
                                    .disabled(!cast.canRetry(model))
                                    .help(line.parts == nil ? "Render this line again" : "Render this passage again")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
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

/// Voice tab while in Cast: the gap and how voices behave.
struct CastInspector: View {
    @EnvironmentObject var cast: CastStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Cast voices")
            Text("Choose each character's voice on the page. Saved voices sound like their recording. A designed voice is invented on its first line, then every later line is cloned from that line, so the character stays the same person.")
                .font(.traceCaption).foregroundStyle(Trace.graphite)
                .fixedSize(horizontal: false, vertical: true)
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                Text("Engine").font(.traceCaption).foregroundStyle(Trace.graphite)
                Picker("Engine", selection: $cast.engine) {
                    ForEach(CastStore.engines, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if cast.engine == "moss" {
                    if let status = cast.mossStatus, !status.available {
                        Text(status.reason).font(.traceCaption).foregroundStyle(Trace.record)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("MOSS-TTSD performs up to six lines at a time as one exchange, so voices react to each other. Each voice is first sampled cleanly by OmniVoice, which MOSS then copies. Each passage is checked against the script and rendered again once if it was misheard. Pronunciation rules and language from the other tabs don't apply.")
                            .font(.traceCaption).foregroundStyle(Trace.pencil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Each line is rendered on its own in its character's voice.")
                        .font(.traceCaption).foregroundStyle(Trace.pencil)
                }
            }
            Hairline()
            ValueSlider(label: "Gap between lines (ms)", value: $cast.gapMs, range: 0...1500, format: "%.0f",
                        help: "Silence inserted between consecutive lines in the joined scene")
            VStack(alignment: .leading, spacing: 6) {
                Text("Room").font(.traceCaption).foregroundStyle(Trace.graphite)
                Picker("Room", selection: $cast.room) {
                    ForEach(CastStore.rooms, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(cast.room == "dry"
                     ? "Lines are joined exactly as rendered."
                     : "Voices are evened out to one level and placed in the same space, with quiet room tone under the gaps.")
                    .font(.traceCaption).foregroundStyle(Trace.pencil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cast.engine == "lines" {
                Text("Speed, steps, language and pronunciation rules from the other tabs apply to every line.")
                    .font(.traceCaption).foregroundStyle(Trace.pencil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { cast.refreshEngines() }
        .onChange(of: cast.engine) { _, _ in cast.refreshEngines() }
    }
}
