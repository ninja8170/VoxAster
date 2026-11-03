import SwiftUI
import AppKit

/// The full-window Scene Editor, laid out like Audacity: one toolbar (transport, time, zoom,
/// room and scene actions), the tracks filling the window, and a selection bar for the clip.
struct SceneEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore
    @EnvironmentObject var ui: StudioUI
    @ObservedObject var player: AudioPlayerController
    @State private var selection: UUID?
    @State private var pps: CGFloat = 70
    @State private var fitToken = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Trace.rule).frame(height: 1)
            if cast.clips.isEmpty {
                EmptyNote(title: "Nothing on the timeline yet",
                          detail: cast.busy ? "Rendering…" : "Render the scene, or Retry Failed to finish it.")
            } else {
                CastTimeline(player: player, selection: $selection, pps: $pps, fitToken: fitToken)
            }
            Rectangle().fill(Trace.rule).frame(height: 1)
            selectionBar
        }
        .background(Trace.ground)
        .onExitCommand { ui.sceneEditor = false }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            transportButton("backward.end.fill", "Go to start") {
                if let master = cast.masterURL { player.seek(master, to: 0) }
            }
            Button {
                if let master = cast.masterURL { player.toggle(master) }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15)).frame(width: 34, height: 28)
                    .foregroundStyle(Color.white)
                    .background(playing ? Trace.record : Trace.cobaltFill, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(cast.masterURL == nil)
            .help("Play or pause (Space)")
            transportButton("forward.end.fill", "Go to end") {
                if let master = cast.masterURL { player.seek(master, to: max(0, player.duration(for: master) - 0.05)) }
            }
            Text(timecode(position, tenths: true))
                .font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(Trace.ink)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Trace.sheet, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Trace.rule, lineWidth: 0.5))
            Text("/ \(timecode(cast.timelineDuration, tenths: true))").font(.traceValue).foregroundStyle(Trace.graphite)
            divider
            transportButton("minus.magnifyingglass", "Zoom out") { pps = max(10, pps / 1.4) }
            transportButton("plus.magnifyingglass", "Zoom in") { pps = min(400, pps * 1.4) }
            transportButton("arrow.left.and.right.square", "Fit the scene to the window") { fitToken += 1 }
            divider
            Picker("Room", selection: $cast.room) {
                ForEach(CastStore.rooms, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("The shared space every voice is placed in")
            .onChange(of: cast.room) { _, _ in cast.commitEdit(model) }
            if cast.mixing { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Text(cast.sceneName.isEmpty ? cast.defaultSceneName : cast.sceneName)
                .font(.system(size: 13, design: .serif)).foregroundStyle(Trace.graphite).lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)
            if !cast.missing.isEmpty && !cast.lines.isEmpty {
                Button(cast.failedCount > 0 ? "Retry Failed (\(cast.missing.count))" : "Render Remaining (\(cast.missing.count))") {
                    cast.retryMissing(model)
                }
                .disabled(!cast.canRetry(model))
            }
            Menu {
                Button("Export Mix…") { if let master = cast.masterURL { model.exportOutput(master) } }
                    .disabled(cast.masterURL == nil)
                Button("Export Stems…") { exportStems() }
                Divider()
                Button("Reset Timeline") { selection = nil; cast.resetTimeline(model) }
            } label: { Text("Export") }
            .fixedSize()
            .disabled(cast.busy || cast.mixing || cast.clips.isEmpty)
            Button(cast.sceneID == nil ? "Save Scene" : "Save") { cast.saveScene() }
                .disabled(cast.busy)
            Button("Done") { ui.sceneEditor = false }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Trace.sheet)
    }

    private var divider: some View { Rectangle().fill(Trace.rule).frame(width: 1, height: 22) }

    private func transportButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26).foregroundStyle(Trace.ink)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Selection bar

    private var selected: CastStore.Clip? { cast.clips.first { $0.id == selection } }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            if let clip = selected {
                Text(clip.lane).font(.traceValue.weight(.semibold)).foregroundStyle(Trace.ink)
                Text(clip.text).font(.system(size: 12, design: .serif)).foregroundStyle(Trace.graphite).lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)
                field("Start", timecode(clip.start, tenths: true))
                field("Length", String(format: "%.2f s", clip.length))
                field("End", timecode(clip.end, tenths: true))
                HStack(spacing: 2) {
                    Button { edit(clip) { $0.start -= 0.05 } } label: { Image(systemName: "chevron.left") }.help("Nudge 50 ms earlier")
                    Button { edit(clip) { $0.start += 0.05 } } label: { Image(systemName: "chevron.right") }.help("Nudge 50 ms later")
                }
                Stepper(value: Binding(get: { clip.gainDb }, set: { value in edit(clip) { $0.gainDb = value } }), in: -12...6, step: 1) {
                    Text(String(format: "%+.0f dB", clip.gainDb)).font(.traceValue.monospacedDigit())
                }
                .fixedSize().help("Clip level")
                Toggle("Cut off", isOn: Binding(get: { clip.cut }, set: { value in edit(clip) { $0.cut = value } }))
                    .toggleStyle(.checkbox)
                    .help("The next line comes in over the end of this one, which fades out under it")
                Toggle("Talks over", isOn: Binding(get: { clip.over }, set: { value in edit(clip) { $0.over = value } }))
                    .toggleStyle(.checkbox)
                    .help("The previous line keeps going underneath this one, a little quieter")
                Button("Render Again") { cast.retry(clip.unit, model: model) }
                    .disabled(!cast.canRetry(model))
                    .help(cast.lines[safe: clip.unit]?.parts == nil ? "Render this line again" : "Render this passage again")
            } else {
                Text("Click a clip to select it. Drag to move, drag its edges to trim. Click the ruler to play from there.")
                    .font(.traceCaption).foregroundStyle(Trace.pencil)
            }
            Spacer(minLength: 0)
            Text("\(cast.clips.count) clips · \(cast.lanes.count) tracks").font(.traceCaption).foregroundStyle(Trace.pencil)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14).frame(height: 38)
        .background(Trace.sheet)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.traceCaption).foregroundStyle(Trace.pencil)
            Text(value).font(.traceValue.monospacedDigit()).foregroundStyle(Trace.ink)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Trace.ground, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func edit(_ clip: CastStore.Clip, _ change: (inout CastStore.Clip) -> Void) {
        cast.editClip(clip.id, change)
        cast.commitEdit(model)
    }

    private func exportStems() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Stems Here"
        panel.message = "Each character's track is saved as its own dry WAV, plus the mix."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await cast.exportStems(model, to: folder) }
    }

    private var playing: Bool { cast.masterURL.map { player.isPlaying($0) } ?? false }
    private var position: Double { cast.masterURL.map { player.currentTime(for: $0) } ?? 0 }
}
