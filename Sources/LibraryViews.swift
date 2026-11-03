import SwiftUI
import AppKit

// MARK: - Takes (history), also used for a project's outputs

struct TakesLibrary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    let items: [AppModel.Generation]
    let title: String
    @State private var search = ""
    @State private var mode = "All"
    @State private var selection = Set<AppModel.Generation.ID>()
    @State private var sortOrder = [KeyPathComparator(\AppModel.Generation.createdAt, order: .reverse)]
    @State private var confirmClear = false

    private var rows: [AppModel.Generation] {
        items.filter { item in
            (mode == "All" || item.mode == mode)
                && (search.isEmpty || item.text.localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    private var modes: [String] { ["All"] + Array(Set(items.map(\.mode))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.traceTitle)
                Text("\(rows.count)").font(.traceValue).foregroundStyle(Trace.graphite)
                Spacer()
                Picker("Kind", selection: $mode) { ForEach(modes, id: \.self) { Text($0).tag($0) } }
                    .fixedSize()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Hairline()
            if rows.isEmpty {
                EmptyNote(title: items.isEmpty ? "No takes yet" : "No matching takes",
                          detail: items.isEmpty ? "Everything you generate is listed here." : nil)
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("") { item in
                        PlayToggle(player: model.outputPlayer, url: item.url)
                    }
                    .width(28)
                    TableColumn("Trace") { item in
                        TraceView(url: item.url, progress: nil, showRuler: false).frame(height: 22)
                    }
                    .width(min: 90, ideal: 140, max: 200)
                    TableColumn("Script", value: \.text) { item in
                        Text(item.text).lineLimit(1).font(.system(size: 13, design: .serif))
                    }
                    TableColumn("Kind", value: \.mode) { item in
                        Text(item.mode).font(.traceCaption).foregroundStyle(Trace.graphite)
                    }
                    .width(min: 80, ideal: 96, max: 120)
                    TableColumn("Created", value: \.createdAt) { item in
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.traceValue).foregroundStyle(Trace.graphite)
                    }
                    .width(min: 120, ideal: 150, max: 180)
                }
                .contextMenu(forSelectionType: AppModel.Generation.ID.self) { ids in
                    let picked = items.filter { ids.contains($0.id) }
                    if let first = picked.first {
                        PlayMenuItem(player: model.outputPlayer, url: first.url)
                        Button("Open in Studio") { model.outputURL = first.url; model.setStudioMode(.clone); ui.place = .studio }
                        Button("Export…") { model.exportOutput(first.url) }
                        Button("Show in Finder") { model.reveal(first.url) }
                        Divider()
                    }
                    Button(picked.count > 1 ? "Delete \(picked.count) Takes" : "Delete Take", role: .destructive) {
                        picked.forEach { model.deleteGeneration($0) }
                    }
                    .disabled(picked.isEmpty)
                } primaryAction: { ids in
                    if let item = items.first(where: { ids.contains($0.id) }) { model.outputPlayer.toggle(item.url) }
                }
                .onDeleteCommand { items.filter { selection.contains($0.id) }.forEach { model.deleteGeneration($0) } }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search scripts")
        .confirmationDialog("Clear all \(model.generations.count) takes?", isPresented: $confirmClear) {
            Button("Clear All Takes", role: .destructive) { model.clearHistory() }
        } message: {
            Text("They are removed from this list. The audio files stay in your outputs folder.")
        }
        .toolbar {
            if title == "Takes" {
                ToolbarItem {
                    Menu {
                        Button("Clear All Takes…", role: .destructive) { confirmClear = true }
                            .disabled(model.generations.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .help("More")
                }
            }
        }
    }
}

// MARK: - Voices

struct VoicesLibrary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<AppModel.SavedVoice.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Voices").font(.traceTitle)
                Text("\(model.savedVoices.count)").font(.traceValue).foregroundStyle(Trace.graphite)
                Spacer()
                Button("Add Voice from File…") { model.setStudioMode(.clone); model.chooseReference(); ui.place = .studio }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Hairline()
            if model.savedVoices.isEmpty {
                EmptyNote(title: "No saved voices", detail: "Load or record a reference in the Studio, then choose Save as Voice.")
            } else {
                Table(model.savedVoices, selection: $selection) {
                    TableColumn("") { voice in
                        PlayToggle(player: model.referencePlayer, url: voice.url)
                    }
                    .width(28)
                    TableColumn("Name") { voice in Text(voice.name).font(.traceBody.weight(.medium)) }
                        .width(min: 120, ideal: 170)
                    TableColumn("Trace") { voice in TraceView(url: voice.url, showRuler: false).frame(height: 22) }
                        .width(min: 100, ideal: 180)
                    TableColumn("Transcript") { voice in
                        Text(voice.transcript.isEmpty ? "—" : voice.transcript).lineLimit(1)
                            .font(.traceCaption).foregroundStyle(Trace.graphite)
                    }
                    TableColumn("Added") { voice in
                        Text(voice.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.traceValue).foregroundStyle(Trace.graphite)
                    }
                    .width(min: 90, ideal: 110, max: 130)
                }
                .contextMenu(forSelectionType: AppModel.SavedVoice.ID.self) { ids in
                    if let voice = model.savedVoices.first(where: { ids.contains($0.id) }) {
                        Button("Use in Studio") { model.useVoice(voice); ui.place = .studio }
                        Button("Compare in Engine Lab") { model.selectEngineLabVoice(voice); openWindow(id: "engine-lab") }
                        PlayMenuItem(player: model.referencePlayer, url: voice.url)
                        Button("Show in Finder") { model.reveal(voice.url) }
                        Divider()
                        Button("Move Voice to Trash", role: .destructive) { model.deleteVoice(voice) }
                    }
                } primaryAction: { ids in
                    if let voice = model.savedVoices.first(where: { ids.contains($0.id) }) { model.useVoice(voice); ui.place = .studio }
                }
            }
            if !model.trainedEngines.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Trained engines", trailing: "\(model.trainedEngines.count)")
                    ForEach(model.trainedEngines, id: \.self) { name in
                        HStack {
                            Text(name).font(.traceBody)
                            Spacer()
                            Button("Compare in Engine Lab") { model.engineLabEngineB = name; openWindow(id: "engine-lab") }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Productions (Performance)

struct ProductionsLibrary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @State private var selection = Set<PerformanceSummary.ID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Productions").font(.traceTitle)
                Text("\(model.performanceHistory.count)").font(.traceValue).foregroundStyle(Trace.graphite)
                Spacer()
                Button("Refresh") { model.refreshPerformances() }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Hairline()
            if model.performanceHistory.isEmpty {
                EmptyNote(title: "No productions", detail: "Prepare one in the Studio's Performance mode.")
            } else {
                Table(model.performanceHistory, selection: $selection) {
                    TableColumn("Script") { item in Text(item.script).lineLimit(1).font(.system(size: 13, design: .serif)) }
                    TableColumn("Created") { item in
                        Text(prettyTimestamp(item.created_at)).font(.traceValue).foregroundStyle(Trace.graphite)
                    }
                    .width(min: 140, ideal: 170, max: 200)
                }
                .contextMenu(forSelectionType: PerformanceSummary.ID.self) { ids in
                    if let id = ids.first {
                        Button("Open in Studio") { open(id) }
                    }
                } primaryAction: { ids in if let id = ids.first { open(id) } }
            }
        }
        .onAppear { model.refreshPerformances() }
    }

    private func open(_ id: String) {
        model.loadPerformance(id)
        model.setScriptMode(.performance)
        ui.place = .studio
    }
}

// MARK: - Scenes (Cast)

struct ScenesLibrary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    @EnvironmentObject var cast: CastStore
    @State private var selection = Set<CastStore.Scene.ID>()
    @State private var renaming: CastStore.Scene?
    @State private var newName = ""
    @State private var masters: [CastStore.Scene.ID: URL] = [:]
    @State private var pending: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scenes").font(.traceTitle)
                Text("\(cast.scenes.count)").font(.traceValue).foregroundStyle(Trace.graphite)
                Spacer()
                Button("New Scene") { pending = { cast.newScene(); ui.setMode(.cast, model) } }.disabled(cast.busy)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Hairline()
            if cast.scenes.isEmpty {
                EmptyNote(title: "No scenes", detail: "Write a scene in Cast, then choose Save Scene.")
            } else {
                Table(cast.scenes, selection: $selection) {
                    TableColumn("") { scene in
                        if let url = masterURL(scene) {
                            PlayToggle(player: model.outputPlayer, url: url, help: "Play the joined scene")
                        }
                    }
                    .width(28)
                    TableColumn("Trace") { scene in
                        if let url = masterURL(scene) { TraceView(url: url, progress: nil, showRuler: false).frame(height: 22) }
                    }
                    .width(min: 90, ideal: 140, max: 200)
                    TableColumn("Name") { scene in
                        Text(scene.name).font(.system(size: 13, design: .serif)).lineLimit(1)
                    }
                    TableColumn("Cast") { scene in
                        Text(speakers(scene)).font(.traceCaption).foregroundStyle(Trace.graphite).lineLimit(1)
                    }
                    .width(min: 100, ideal: 160)
                    TableColumn("Lines") { scene in
                        let done = scene.lines.filter { $0.path != nil }.count
                        Text(done == scene.lines.count ? "\(done)" : "\(done) of \(scene.lines.count)")
                            .font(.traceValue.monospacedDigit())
                            .foregroundStyle(done == scene.lines.count ? Trace.graphite : Trace.record)
                    }
                    .width(min: 50, ideal: 64, max: 80)
                    TableColumn("Updated") { scene in
                        Text(scene.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.traceValue).foregroundStyle(Trace.graphite)
                    }
                    .width(min: 120, ideal: 150, max: 180)
                }
                .contextMenu(forSelectionType: CastStore.Scene.ID.self) { ids in
                    if let scene = cast.scenes.first(where: { ids.contains($0.id) }) {
                        Button("Open in Cast") { open(scene) }.disabled(cast.busy)
                        if let url = masterURL(scene) {
                            PlayMenuItem(player: model.outputPlayer, url: url)
                            Button("Export…") { model.exportOutput(url) }
                        }
                        Button("Rename…") { newName = scene.name; renaming = scene }
                        Button("Show in Finder") { model.reveal(cast.folder(for: scene.id)) }
                        Divider()
                        Button("Move Scene to Trash", role: .destructive) { cast.deleteScene(scene) }
                            .disabled(cast.busy && cast.sceneID == scene.id)
                    }
                } primaryAction: { ids in
                    if let scene = cast.scenes.first(where: { ids.contains($0.id) }) { open(scene) }
                }
            }
        }
        .unsavedSceneGuard($pending)
        .onAppear { cast.loadScenes(); findMasters() }
        .onChange(of: cast.scenes) { _, _ in findMasters() }
        .sheet(item: $renaming) { scene in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Scene").font(.traceSection)
                TextField("Name", text: $newName).frame(width: 280).onSubmit { commitRename(scene) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename(scene) }.keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func masterURL(_ scene: CastStore.Scene) -> URL? { masters[scene.id] }

    /// Which scenes have their joined audio on disk. Checked when the list changes; checking
    /// inside every row on every redraw hit the disk once per scene, many times a second.
    private func findMasters() {
        var found: [CastStore.Scene.ID: URL] = [:]
        for scene in cast.scenes {
            if let name = scene.master {
                let url = cast.folder(for: scene.id).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { found[scene.id] = url }
            }
        }
        masters = found
    }

    private func speakers(_ scene: CastStore.Scene) -> String {
        var seen: [String] = []
        for line in scene.lines where !seen.contains(line.speaker) { seen.append(line.speaker) }
        return seen.map(\.localizedCapitalized).joined(separator: ", ")
    }

    private func open(_ scene: CastStore.Scene) {
        guard !cast.busy else { return }
        if cast.sceneID == scene.id { ui.setMode(.cast, model); return }   // already open: just go there
        pending = { cast.openScene(scene); ui.setMode(.cast, model) }
    }

    private func commitRename(_ scene: CastStore.Scene) {
        cast.renameScene(scene, to: newName)
        renaming = nil
    }
}

// MARK: - Project

struct ProjectLibrary: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: StudioUI
    let projectID: UUID

    private var project: AppModel.VoiceProject? { model.projects.first { $0.id == projectID } }

    var body: some View {
        VStack(spacing: 0) {
            if let project {
                HStack(spacing: 12) {
                    TextField("Project name", text: $model.projectName)
                        .textFieldStyle(.plain).font(.traceTitle)
                        .frame(maxWidth: 360)
                    Spacer()
                    Text(model.projectStatus).font(.traceCaption).foregroundStyle(Trace.graphite).lineLimit(1)
                    Button("Save Changes") { model.saveCurrentProject() }
                    Button("Open in Studio") { ui.place = .studio }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                HStack(spacing: 16) {
                    Label(project.referencePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "No voice",
                          systemImage: "person.wave.2")
                    Label("Updated \(project.updatedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                    if !model.recoverableDrafts.isEmpty {
                        Menu("Recover Draft") {
                            ForEach(model.recoverableDrafts) { draft in Button(draft.name) { model.recoverDraft(draft.id) } }
                        }
                        .fixedSize()
                    }
                    Spacer()
                }
                .font(.traceCaption).foregroundStyle(Trace.graphite)
                .padding(.horizontal, 20).padding(.bottom, 10)
                Hairline()
                TakesLibrary(items: model.projectOutputs(project), title: "Project Takes")
            } else {
                EmptyNote(title: "Project not found")
            }
        }
    }
}
