import SwiftUI
import AppKit

// MARK: - Window state

enum ScriptMode: String, CaseIterable, Identifiable {
    case take = "Take", longForm = "Long Form", performance = "Performance"
    var id: String { rawValue }
}

enum StudioMode: String, CaseIterable, Identifiable {
    case clone = "Voice Clone", design = "Voice Design", longForm = "Long Form", performance = "Performance", cast = "Cast"
    var id: String { rawValue }
    var shortcut: KeyEquivalent {
        switch self { case .clone: "1"; case .design: "2"; case .longForm: "3"; case .performance: "4"; case .cast: "5" }
    }
}

enum VoiceSource: String, CaseIterable, Identifiable {
    case reference = "Reference", designed = "Designed"
    var id: String { rawValue }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case voice = "Voice", render = "Render", words = "Words"
    var id: String { rawValue }
}

enum Place: Hashable {
    case studio, takes, voices, productions, scenes, project(UUID)
}

/// View state for the single studio window. The model's `selectedSection`
/// stays the persisted source of truth for the mode and voice source.
final class StudioUI: ObservableObject {
    @Published var place: Place = .studio
    @Published var showInspector = true
    @Published var inspectorTab: InspectorTab = .voice
    @Published var showModelPreview = false
    @Published var castActive = false
    /// The full-window Scene Editor over the whole studio (Cast only).
    @Published var sceneEditor = false
    @Published var showSaveVoice = false
    @Published var takes: Int = UserDefaults.standard.integer(forKey: "studioTakes").clamped(1, 4) {
        didSet { UserDefaults.standard.set(takes, forKey: "studioTakes") }
    }

    static let languages = ["Auto detect", "English", "French", "Spanish", "German", "Italian", "Portuguese", "Dutch",
                            "Polish", "Russian", "Arabic", "Hindi", "Japanese", "Korean", "Chinese"]
}

@MainActor
extension StudioUI {
    func mode(_ model: AppModel) -> StudioMode { castActive ? .cast : model.studioMode }

    func setMode(_ mode: StudioMode, _ model: AppModel) {
        if mode == .cast {
            model.setStudioMode(.clone)  // Cast uses the Voice Clone rules and language
            castActive = true
        } else {
            castActive = false
            sceneEditor = false
            model.setStudioMode(mode)
        }
        place = .studio
    }

    func primaryTitle(_ model: AppModel) -> String { castActive ? "Render Scene" : model.primaryTitle(takes: takes) }
    func canRunPrimary(_ model: AppModel, _ cast: CastStore) -> Bool {
        castActive ? cast.canRender(model) : model.canRunPrimary(takes: takes)
    }
    func runPrimary(_ model: AppModel, _ cast: CastStore) {
        if castActive { cast.render(model) } else { model.runPrimary(takes: takes) }
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

extension AppModel {
    var scriptMode: ScriptMode {
        switch selectedSection {
        case .longForm: return .longForm
        case .performance: return .performance
        default: return .take
        }
    }

    var voiceSource: VoiceSource {
        selectedSection == .design ? .designed : .reference
    }

    var studioMode: StudioMode {
        switch selectedSection {
        case .design: return .design
        case .longForm: return .longForm
        case .performance: return .performance
        default: return .clone
        }
    }

    /// Clone and Design share the script text; switching carries it across.
    func setStudioMode(_ mode: StudioMode) {
        switch mode {
        case .clone: if selectedSection == .design { setVoiceSource(.reference) } else { selectedSection = .clone }
        case .design: setVoiceSource(.designed)
        case .longForm: selectedSection = .longForm
        case .performance: selectedSection = .performance
        case .cast: break  // Cast is window state (StudioUI.castActive), not a model section
        }
    }

    /// One plain status line, shown under the window title.
    var statusLine: String {
        if isGenerating || performanceBusy { return "Generating…" }
        if engineLabRunning { return "Comparing engines…" }
        if modelReady { return "Engine ready · runs on this Mac" }
        return runtimeSelection == nil ? "Engine setup needed" : "Loading engine…"
    }

    func setScriptMode(_ mode: ScriptMode) {
        switch mode {
        case .take: selectedSection = voiceSource == .designed ? .design : .clone
        case .longForm: selectedSection = .longForm
        case .performance: selectedSection = .performance
        }
    }

    /// Clone and Design share one script: carry the text and rules across.
    func setVoiceSource(_ source: VoiceSource) {
        guard source != voiceSource || scriptMode != .take else { return }
        if source == .designed {
            if scriptMode == .take {
                designText = cloneText; designPronunciationRules = clonePronunciationRules
                designMatchInsideWords = cloneMatchInsideWords
            }
            selectedSection = .design
        } else {
            if selectedSection == .design {
                cloneText = designText; clonePronunciationRules = designPronunciationRules
                cloneMatchInsideWords = designMatchInsideWords
            }
            if scriptMode == .take { selectedSection = .clone }
        }
    }

    var scriptKey: ReferenceWritableKeyPath<AppModel, String> {
        switch selectedSection {
        case .longForm: return \.longFormText
        case .performance: return \.performanceText
        case .design: return \.designText
        default: return \.cloneText
        }
    }

    var rulesKey: ReferenceWritableKeyPath<AppModel, String> {
        switch selectedSection {
        case .longForm: return \.pronunciationRules
        case .performance: return \.performanceRules
        case .design: return \.designPronunciationRules
        default: return \.clonePronunciationRules
        }
    }

    var matchKey: ReferenceWritableKeyPath<AppModel, Bool> {
        switch selectedSection {
        case .longForm: return \.longFormMatchInsideWords
        case .performance: return \.performanceMatchInsideWords
        case .design: return \.designMatchInsideWords
        default: return \.cloneMatchInsideWords
        }
    }

    func binding<T>(_ key: ReferenceWritableKeyPath<AppModel, T>) -> Binding<T> {
        Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0 })
    }

    var currentProject: VoiceProject? {
        guard let id = currentProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var performanceNeedsPrepare: Bool {
        guard let job = performanceProduction else { return true }
        return job.script != performanceText || job.pronunciations != performanceRules
            || job.pronunciation_mode != (performanceMatchInsideWords ? "substring" : "words")
    }

    var busy: Bool { isGenerating || performanceBusy || engineLabRunning }

    /// The saved voice the current reference came from (matched by content hash, then path).
    var currentSavedVoice: SavedVoice? {
        if let sha = referenceIdentity?.sha256, let match = savedVoices.first(where: { $0.referenceSHA256 == sha }) {
            return match
        }
        guard let ref = referenceURL?.standardizedFileURL else { return nil }
        return savedVoices.first { $0.url.standardizedFileURL == ref }
    }

    var designedDescriptors: [String] {
        if designMode == "Auto" { return ["automatic speaker"] }
        return [designGender, designAge, designPitch, designStyle, designAccent, designAccent == "Chinese accent" ? designDialect : "Auto"]
            .filter { $0 != "Auto" }
    }

    var voiceDisplayName: String {
        if voiceSource == .designed && scriptMode == .take {
            if designMode == "Auto" { return "Auto Voice" }
            return designPreset == "Custom" ? "Designed Voice" : designPreset
        }
        if let saved = currentSavedVoice { return saved.name }
        guard let name = referenceURL?.deletingPathExtension().lastPathComponent else { return "No Voice" }
        return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// Rough spoken length at ~155 words per minute, scaled by Speed.
    func estimatedSeconds(_ text: String) -> Double {
        let stripped = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let words = stripped.split { $0.isWhitespace }.count
        var pauses = 0.0
        if let regex = try? NSRegularExpression(pattern: #"\[pause (\d+)ms\]"#) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                pauses += (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 1000
            }
        }
        return Double(words) / (155 * max(0.5, speed)) * 60 + pauses
    }

    func primaryTitle(takes: Int) -> String {
        switch scriptMode {
        case .take: return takes > 1 && voiceSource == .reference ? "Generate \(takes) Takes" : "Generate"
        case .longForm: return "Render Voiceover"
        case .performance: return performanceNeedsPrepare ? "Prepare Production" : "Render Segments"
        }
    }

    func canRunPrimary(takes: Int) -> Bool {
        guard modelReady, !busy else { return false }
        let text = self[keyPath: scriptKey].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if scriptMode == .take && voiceSource == .designed { return true }
        return referenceURL != nil
    }

    func runPrimary(takes: Int) {
        guard canRunPrimary(takes: takes) else { return }
        switch scriptMode {
        case .take:
            if voiceSource == .designed { generateDesign() }
            else if takes > 1 { variantCount = takes; generateVariants() }
            else { variantURLs = []; generateClone() }
        case .longForm: generateLongForm()
        case .performance: performanceNeedsPrepare ? preparePerformance() : renderPerformance()
        }
    }

    var currentOutput: URL? {
        switch scriptMode {
        case .take: return outputURL
        case .longForm: return longFormOutputURL
        case .performance: return performanceProduction?.master.map { URL(fileURLWithPath: $0) }
        }
    }
}

// MARK: - Root

struct StudioRoot: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            StudioSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: Trace.sidebarWidth, max: 280)
        } detail: {
            Group {
                switch ui.place {
                case .studio: StudioView()
                case .takes: TakesLibrary(items: model.generations, title: "Takes")
                case .voices: VoicesLibrary()
                case .productions: ProductionsLibrary()
                case .scenes: ScenesLibrary()
                case .project(let id): ProjectLibrary(projectID: id)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(Trace.ground.ignoresSafeArea())
        }
        .inspector(isPresented: Binding(get: { ui.showInspector && ui.place == .studio }, set: { ui.showInspector = $0 })) {
            StudioInspector()
                .inspectorColumnWidth(min: 260, ideal: Trace.inspectorWidth, max: 360)
        }
        .toolbar { StudioToolbar() }
        .overlay {
            if ui.sceneEditor && ui.castActive && ui.place == .studio {
                SceneEditor(player: model.outputPlayer)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: ui.sceneEditor)
        .navigationTitle(model.currentProject?.name ?? "VoxAster")
        .navigationSubtitle(model.statusLine)
        .background(RuntimeSetupPresentation(setup: model.runtimeSetup))
        .onChange(of: model.selectedSection) { _, section in route(section) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard ui.place == .studio else { return false }
            return model.acceptDroppedAudio(providers)
        }
        .alert("VoxAster", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Model code still navigates with AppSection; map it onto the new window.
    private func route(_ section: AppSection) {
        switch section {
        case .clone: ui.place = .studio
        case .design, .longForm, .performance: ui.place = .studio; ui.castActive = false
        case .library: ui.place = .voices; model.setScriptMode(.take)
        case .history: ui.place = .takes; model.setScriptMode(.take)
        case .projects: ui.place = .takes; model.setScriptMode(.take)
        case .engineLab: openWindow(id: "engine-lab"); model.setScriptMode(.take)
        case .settings: openSettings(); model.setScriptMode(.take)
        }
    }
}

// MARK: - Sidebar

struct StudioSidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var cast: CastStore
    @State private var newProjectPending = false

    var body: some View {
        List(selection: Binding<Place?>(get: { ui.place }, set: { if let p = $0 { select(p) } })) {
            Label("Studio", systemImage: "waveform").tag(Place.studio)

            Section("Library") {
                Label("Takes", systemImage: "clock").badge(model.generations.count).tag(Place.takes)
                Label("Voices", systemImage: "person.wave.2").badge(model.savedVoices.count).tag(Place.voices)
                Label("Productions", systemImage: "rectangle.split.3x1").badge(model.performanceHistory.count).tag(Place.productions)
                Label("Scenes", systemImage: "person.2.wave.2").badge(cast.scenes.count).tag(Place.scenes)
            }

            Section("Voices") {
                if model.savedVoices.isEmpty {
                    Text("Saved voices appear here").font(.traceCaption).foregroundStyle(Trace.pencil)
                }
                ForEach(model.savedVoices) { voice in
                    Button { model.useVoice(voice); ui.place = .studio } label: {
                        HStack(spacing: 8) {
                            Text(voice.name).lineLimit(1)
                                .fontWeight(model.currentSavedVoice?.id == voice.id ? .semibold : .regular)
                            Spacer(minLength: 4)
                            TraceView(url: voice.url, showRuler: false, excerptSeconds: 3)
                                .frame(width: 46, height: 14)
                                .opacity(model.currentSavedVoice?.id == voice.id ? 1 : 0.55)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Use Voice") { model.useVoice(voice); ui.place = .studio }
                        PlayMenuItem(player: model.referencePlayer, url: voice.url)
                        Button("Show in Finder") { model.reveal(voice.url) }
                        Divider()
                        Button("Move Voice to Trash", role: .destructive) { model.deleteVoice(voice) }
                    }
                }
            }

            Section("Projects") {
                ForEach(model.projects) { project in
                    Label(project.name, systemImage: model.currentProjectID == project.id ? "folder.fill" : "folder")
                        .tag(Place.project(project.id))
                        .contextMenu {
                            Button("Open in Studio") { model.openProject(project); ui.place = .studio }
                            Divider()
                            Button("Delete Project", role: .destructive) { model.deleteProject(project) }
                        }
                }
                Button { model.newProject(); ui.place = .studio } label: {
                    Label("New Project", systemImage: "plus").foregroundStyle(Trace.graphite)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .onAppear { model.refreshPerformances() }
    }

    private func select(_ place: Place) {
        if case .project(let id) = place, let p = model.projects.first(where: { $0.id == id }), model.currentProjectID != id {
            model.openProject(p)
        }
        ui.place = place
    }
}

// MARK: - Toolbar

struct StudioToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var cast: CastStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if ui.place == .studio {
                Picker("Mode", selection: Binding(get: { ui.mode(model) }, set: { ui.setMode($0, model) })) {
                    ForEach(StudioMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 500)
                .help("Voice Clone: speak as a recorded voice · Voice Design: describe a new voice · Long Form: a script in segments · Performance: exact pauses and loudness")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if ui.place == .studio {
                if !ui.castActive { VoiceMenu() }
                Menu {
                    Picker("Language", selection: $model.cloneLanguage) {
                        ForEach(StudioUI.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.voiceSource == .designed && model.scriptMode == .take ? "Auto"
                          : (model.cloneLanguage == "Auto detect" ? "Any Language" : model.cloneLanguage),
                          systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.voiceSource == .designed && model.scriptMode == .take)
                .help(model.voiceSource == .designed && model.scriptMode == .take
                      ? "Designed voices choose the language automatically." : "Output language")
            }
            if ui.place == .studio {
                Button { ui.runPrimary(model, cast) } label: {
                    Text(ui.primaryTitle(model))
                }
                .buttonStyle(.borderedProminent)
                .tint(Trace.cobaltFill)
                .disabled(!ui.canRunPrimary(model, cast))
                .help("\(ui.primaryTitle(model)) (⌘G)")
                Button { ui.showInspector.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(ui.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
        }
    }
}

struct VoiceMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    var body: some View {
        Menu {
            if !model.savedVoices.isEmpty {
                Section("Saved Voices") {
                    ForEach(model.savedVoices) { voice in
                        Button(voice.name) { model.setVoiceSource(.reference); model.useVoice(voice) }
                    }
                }
            }
            Section {
                Button("Choose Audio File…") { model.setVoiceSource(.reference); model.chooseReference() }
                RecordMenuItem(recorder: model.recorder) { model.setVoiceSource(.reference); model.startRecording() }
                Button("Design a New Voice") { model.setStudioMode(.design); ui.inspectorTab = .voice; ui.showInspector = true }
            }
        } label: {
            Label(model.voiceDisplayName, systemImage: model.voiceSource == .designed && model.scriptMode == .take ? "slider.horizontal.3" : "person.wave.2")
                .labelStyle(.titleAndIcon)
        }
        .help("Voice")
    }
}

// MARK: - Menu commands

struct StudioCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: StudioUI
    @ObservedObject var cast: CastStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject(); ui.place = .studio }.keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.saveCurrentProject() }.keyboardShortcut("s")
            Button("Export Audio…") { model.exportOutput(model.currentOutput) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.currentOutput == nil)
        }
        CommandMenu("Speech") {
            Button(ui.primaryTitle(model)) { ui.place = .studio; ui.runPrimary(model, cast) }
                .keyboardShortcut("g")
                .disabled(!ui.canRunPrimary(model, cast))
            Button("Play / Pause Output") { if let url = model.currentOutput { model.outputPlayer.toggle(url) } }
                .keyboardShortcut(.space, modifiers: [.option])
                .disabled(model.currentOutput == nil)
            Divider()
            Picker("Mode", selection: Binding(get: { ui.mode(model) }, set: { ui.setMode($0, model) })) {
                ForEach(StudioMode.allCases) { mode in Text(mode.rawValue).tag(mode).keyboardShortcut(mode.shortcut) }
            }
            Divider()
            Button("Choose Reference Audio…") { model.setVoiceSource(.reference); model.chooseReference() }.keyboardShortcut("o")
            RecordMenuItem(recorder: model.recorder) { model.setVoiceSource(.reference); model.startRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Analyze Reference") { ui.place = .studio; ui.showInspector = true; ui.inspectorTab = .voice; model.analyzeReference() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.referenceURL == nil || model.referenceAnalyzing)
            Divider()
            Toggle("Show What the Model Receives", isOn: $ui.showModelPreview)
        }
        CommandGroup(after: .sidebar) {
            Button(ui.showInspector ? "Hide Inspector" : "Show Inspector") { ui.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(before: .windowList) {
            EngineLabMenuItem()
            Divider()
        }
    }
}

struct EngineLabMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Engine Lab") { openWindow(id: "engine-lab") }.keyboardShortcut("l", modifiers: [.command, .option])
    }
}
