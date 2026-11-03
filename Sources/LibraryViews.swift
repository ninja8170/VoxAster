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
                        Button { model.outputPlayer.toggle(item.url) } label: {
                            Image(systemName: model.outputPlayer.isPlaying(item.url) ? "pause.fill" : "play.fill")
                                .foregroundStyle(model.outputPlayer.isPlaying(item.url) ? Trace.record : Trace.ink)
                        }
                        .buttonStyle(.borderless)
                        .help("Play")
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
                        Button("Play") { model.outputPlayer.toggle(first.url) }
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
        .toolbar {
            if title == "Takes" {
                ToolbarItem {
                    Menu {
                        Button("Clear All Takes…", role: .destructive) { model.clearHistory() }
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
                        Button { model.referencePlayer.toggle(voice.url) } label: {
                            Image(systemName: model.referencePlayer.isPlaying(voice.url) ? "pause.fill" : "play.fill")
                                .foregroundStyle(model.referencePlayer.isPlaying(voice.url) ? Trace.record : Trace.ink)
                        }
                        .buttonStyle(.borderless)
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
                        Button("Play") { model.referencePlayer.toggle(voice.url) }
                        Button("Show in Finder") { model.reveal(voice.url) }
                        Divider()
                        Button("Delete Voice", role: .destructive) { model.deleteVoice(voice) }
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
