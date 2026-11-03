import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @State private var editing: CastStore.Clip?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var loop: ClosedRange<Double>?
    @State private var looping = false
    @State private var renaming: CastStore.Marker?
    @State private var markerName = ""
    @State private var paceOpen = false
    @State private var pace = 1.0
    @State private var paceBase: [CastStore.Clip]?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Trace.rule).frame(height: 1)
            if cast.clips.isEmpty {
                EmptyNote(title: "Nothing on the timeline yet",
                          detail: cast.busy ? "Rendering…" : "Render the scene, or Retry Failed to finish it.")
            } else {
                CastTimeline(player: player, selection: $selection, pps: $pps, fitToken: fitToken,
                             onEdit: { clip in draft = clip.text; editing = clip },
                             onRenameMarker: { marker in markerName = marker.name; renaming = marker },
                             loop: $loop)
            }
            Rectangle().fill(Trace.rule).frame(height: 1)
            selectionBar
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Trace.ground)
        .onExitCommand { ui.sceneEditor = false }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: selection) { _, _ in focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .tab, .home, .end]) { press in key(press) }
        .onKeyPress(characters: CharacterSet(charactersIn: "mMlL")) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            if press.characters.lowercased() == "m" { cast.addMarker(at: position, model) } else { toggleLoop() }
            return .handled
        }
        .onChange(of: player.currentTime) { _, t in
            // Loop playback: back to the start of the region whenever the playhead leaves it.
            guard looping, let loop, let master = cast.masterURL, player.isPlaying(master),
                  t >= loop.upperBound || t < loop.lowerBound - 0.25 else { return }
            player.seek(master, to: loop.lowerBound)
        }
        .onChange(of: loop) { _, region in if region == nil { looping = false } else if !looping { looping = true } }
        .sheet(item: $editing) { clip in editSheet(clip) }
        .sheet(item: $renaming) { marker in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Marker").font(.traceSection)
                TextField("Name", text: $markerName).frame(width: 280)
                    .onSubmit { cast.renameMarker(marker.id, to: markerName, model); renaming = nil }
                HStack {
                    Button("Delete Marker", role: .destructive) { cast.deleteMarker(marker.id, model); renaming = nil }
                    Spacer()
                    Button("Cancel", role: .cancel) { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { cast.renameMarker(marker.id, to: markerName, model); renaming = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private func toggleLoop() {
        if loop == nil {
            // No region yet: loop the selected clip, or the next 4 s from the playhead.
            if let clip = selected { loop = clip.start...clip.end } else { loop = position...(position + 4) }
        } else {
            looping.toggle()
        }
    }

    // MARK: Keys

    /// ←/→ nudge the selected clip 50 ms (⇧ 10 ms) or move the playhead 1 s; Tab / ⇧Tab step
    /// between clips in time order; Home / End jump to the ends of the scene.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow, .rightArrow:
            let sign: Double = press.key == .leftArrow ? -1 : 1
            if let clip = selected {
                let landing = cast.landing(clip.id, proposed: clip.start + sign * (shift ? 0.01 : 0.05),
                                           snapping: false, playhead: nil, tolerance: 0)
                cast.editClip(clip.id) { $0.start = landing.start }
                cast.commitEdit(model)
            } else if let master = cast.masterURL {
                player.seek(master, to: max(0, position + sign))
            }
        case .tab:
            let ordered = cast.clips.sorted { ($0.start, $0.lane) < ($1.start, $1.lane) }
            guard !ordered.isEmpty else { return .ignored }
            let current = ordered.firstIndex { $0.id == selection }
            let next = current.map { (shift ? $0 - 1 + ordered.count : $0 + 1) % ordered.count } ?? (shift ? ordered.count - 1 : 0)
            selection = ordered[next].id
            if let master = cast.masterURL, !playing { player.seek(master, to: ordered[next].start) }
        case .home:
            if let master = cast.masterURL { player.seek(master, to: 0) }
        case .end:
            if let master = cast.masterURL { player.seek(master, to: max(0, player.duration(for: master) - 0.05)) }
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: Editing a line's words

    private func editSheet(_ clip: CastStore.Clip) -> some View {
        let passage = cast.lines[safe: clip.unit]?.parts != nil
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(clip.lane)'s line").font(.traceSection)
            TextEditor(text: $draft)
                .font(.system(size: 14, design: .serif))
                .frame(width: 460, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Trace.rule))
            Text(passage
                 ? "The script is updated and the whole Together passage is performed again; later clips shift to fit."
                 : "The script is updated and this line is rendered again in place; later clips shift to fit.")
                .font(.traceCaption).foregroundStyle(Trace.graphite).fixedSize(horizontal: false, vertical: true)
                .frame(width: 460, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editing = nil }.keyboardShortcut(.cancelAction)
                Button("Render") {
                    cast.editText(clip.id, to: draft, model: model)
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cast.canRetry(model))
            }
        }
        .padding(20)
    }

    // MARK: Toolbar

    /// The left of the toolbar scrolls sideways when the window is narrow; scene actions and Done
    /// stay pinned on the right. Nothing here may set a minimum width: a toolbar wider than the
    /// window made AppKit loop on layout and abort (crash on opening Cast, 2026-11-03).
    private var toolbar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) { transport }.padding(.vertical, 2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            sceneActions
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Trace.sheet)
    }

    @ViewBuilder private var transport: some View {
            transportButton("backward.end.fill", "Go to start") {
                if let master = cast.masterURL { player.seek(master, to: 0) }
            }
            Button {
                guard let master = cast.masterURL else { return }
                if looping, let loop, !playing, !loop.contains(position) { player.seek(master, to: loop.lowerBound) }
                player.toggle(master)
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
            Button { toggleLoop() } label: {
                Image(systemName: "repeat").font(.system(size: 13)).frame(width: 26, height: 26)
                    .foregroundStyle(looping ? Color.white : Trace.ink)
                    .background(looping ? Trace.cobaltFill : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Loop the region (L). Drag on the ruler to set it; with none, L loops the selected clip.")
            .contextMenu { Button("Clear Loop Region") { loop = nil } }
            transportButton("flag", "Add a marker at the playhead (M)") { cast.addMarker(at: position, model) }
            divider
            transportButton("arrow.uturn.backward", "Undo (⌘Z)") { cast.undo(model) }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!cast.canUndo || cast.busy)
            transportButton("arrow.uturn.forward", "Redo (⇧⌘Z)") { cast.redo(model) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!cast.canRedo || cast.busy)
            divider
            transportButton("minus.magnifyingglass", "Zoom out (⌘−)") { pps = max(10, pps / 1.4) }
                .keyboardShortcut("-", modifiers: .command)
            transportButton("plus.magnifyingglass", "Zoom in (⌘+)") { pps = min(400, pps * 1.4) }
                .keyboardShortcut("=", modifiers: .command)
            transportButton("arrow.left.and.right.square", "Fit the scene to the window") { fitToken += 1 }
            Button { openPace() } label: {
                Image(systemName: "metronome").font(.system(size: 13)).frame(width: 26, height: 26).foregroundStyle(Trace.ink)
            }
            .buttonStyle(.borderless)
            .help("Pace: tighten or loosen every gap at once")
            .disabled(cast.clips.count < 2 || cast.busy)
            .popover(isPresented: $paceOpen, arrowEdge: .bottom) { pacePopover }
            divider

            if cast.mixing { ProgressView().controlSize(.small) }
    }

    @ViewBuilder private var sceneActions: some View {
            Picker("Room", selection: $cast.room) {
                ForEach(CastStore.rooms, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu).fixedSize()
            .help("Room: the shared space every voice is placed in")
            .onChange(of: cast.room) { _, _ in cast.commitEdit(model) }
            Text(cast.sceneName.isEmpty ? cast.defaultSceneName : cast.sceneName)
                .font(.system(size: 13, design: .serif)).foregroundStyle(Trace.graphite).lineLimit(1)
                .frame(minWidth: 0, maxWidth: 220, alignment: .trailing)
                .layoutPriority(-1)
            if !cast.unchecked.isEmpty && cast.missing.isEmpty {
                Button("Check Lines") { cast.checkAll(model) }
                    .disabled(!cast.canRetry(model))
                    .help("Transcribe every line and mark words that came out wrong")
            }
            if !cast.missing.isEmpty && !cast.lines.isEmpty {
                Button(cast.failedCount > 0 ? "Retry Failed (\(cast.missing.count))" : "Render Remaining (\(cast.missing.count))") {
                    cast.retryMissing(model)
                }
                .disabled(!cast.canRetry(model))
            }
            Menu {
                Menu("Export Mix") {
                    Button("Original Level…") { if let master = cast.masterURL { model.exportOutput(master) } }
                    Divider()
                    ForEach(CastStore.loudnessTargets, id: \.lufs) { target in
                        Button("\(target.name) (\(Int(target.lufs)) LUFS)…") { exportLoud(target.name, target.lufs) }
                    }
                }
                .disabled(cast.masterURL == nil)
                Button("Export Stems…") { exportStems() }
                Divider()
                Button("Export Subtitles (SRT)…") { exportSubtitles(.srt) }
                Button("Export Subtitles (WebVTT)…") { exportSubtitles(.vtt) }
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { selectionDetails }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text("\(cast.clips.count) clips · \(cast.lanes.count) tracks").font(.traceCaption).foregroundStyle(Trace.pencil)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14).frame(height: 38)
        .background(Trace.sheet)
    }

    @ViewBuilder private var selectionDetails: some View {
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
                Stepper(value: Binding(get: { (clip.fadeIn ?? 0) * 1000 }, set: { v in edit(clip) { $0.fadeIn = max(0, min(v / 1000, clip.length / 2)) } }),
                        in: 0...2000, step: 50) {
                    Text(String(format: "In %.0f ms", (clip.fadeIn ?? 0) * 1000)).font(.traceValue.monospacedDigit())
                }
                .fixedSize().help("Fade in")
                Stepper(value: Binding(get: { (clip.fadeOut ?? 0) * 1000 }, set: { v in edit(clip) { $0.fadeOut = max(0, min(v / 1000, clip.length / 2)) } }),
                        in: 0...2000, step: 50) {
                    Text(String(format: "Out %.0f ms", (clip.fadeOut ?? 0) * 1000)).font(.traceValue.monospacedDigit())
                }
                .fixedSize().help("Fade out")
                Toggle("Cut off", isOn: Binding(get: { clip.cut }, set: { value in edit(clip) { $0.cut = value } }))
                    .toggleStyle(.checkbox)
                    .help("The next line comes in over the end of this one, which fades out under it")
                Toggle("Talks over", isOn: Binding(get: { clip.over }, set: { value in edit(clip) { $0.over = value } }))
                    .toggleStyle(.checkbox)
                    .help("The previous line keeps going underneath this one, a little quieter")
                let issues = cast.issues(for: clip)
                if !issues.isEmpty {
                    Label(issues.map { "“\($0.word)”" + ($0.heard.map { " → “\($0)”" } ?? " missing") }.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.traceCaption).foregroundStyle(Trace.record).lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                        .help("Words Whisper heard differently from the script")
                }
                Button("Edit Words…") { draft = clip.text; editing = clip }
                    .disabled(!cast.canRetry(model))
                Button("Render Again") { cast.retry(clip.unit, model: model) }
                    .disabled(!cast.canRetry(model))
                    .help(cast.lines[safe: clip.unit]?.parts == nil ? "Render this line again" : "Render this passage again")
            } else {
                Text("Click a clip to select it · drag to move, edges to trim (hold ⌘ to stop snapping) · double-click to edit its words · ←/→ nudge · Tab next clip · M marker · L loop")
                    .font(.traceCaption).foregroundStyle(Trace.pencil)
            }
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

    // MARK: Pace

    private func openPace() {
        paceBase = cast.clips
        pace = 1.0
        paceOpen = true
    }

    private var pacePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pace").font(.traceSection)
            HStack {
                Text("Tighter").font(.traceCaption).foregroundStyle(Trace.pencil)
                Slider(value: $pace, in: 0.7...1.4, step: 0.05)
                    .frame(width: 220)
                    .onChange(of: pace) { _, value in
                        if let base = paceBase { cast.previewClips(CastStore.paced(base, factor: value)) }
                    }
                Text("Looser").font(.traceCaption).foregroundStyle(Trace.pencil)
            }
            Text("Every gap between lines × \(Int((pace * 100).rounded()))%. Interruptions and talk-overs keep their overlap.")
                .font(.traceCaption).foregroundStyle(Trace.graphite).fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") {
                    if let base = paceBase { cast.previewClips(base) }
                    paceBase = nil
                    paceOpen = false
                }
                Button("Apply") { applyPace() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onDisappear { applyPace() }   // clicking away keeps the change, like other popovers
    }

    private func applyPace() {
        guard paceBase != nil else { return }
        paceBase = nil
        paceOpen = false
        if pace != 1.0 { cast.commitEdit(model) }
    }

    // MARK: Export

    private var exportName: String {
        (cast.sceneName.isEmpty ? cast.defaultSceneName : cast.sceneName).replacingOccurrences(of: "/", with: "-")
    }

    private func exportLoud(_ name: String, _ lufs: Double) {
        Task {
            do {
                let copy = try await cast.loudnessCopy(lufs)
                defer { try? FileManager.default.removeItem(at: copy) }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.wav]
                panel.nameFieldStringValue = "\(exportName) (\(name) \(Int(lufs)) LUFS).wav"
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let destination = panel.url { model.exportAudio(copy, to: destination) }
            } catch {
                model.errorMessage = "Could not match loudness: \(error.localizedDescription)"
            }
        }
    }

    private func exportSubtitles(_ format: CastStore.SubtitleFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = "\(exportName).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try cast.subtitleText(format).write(to: destination, atomically: true, encoding: .utf8) }
        catch { model.errorMessage = "Could not save subtitles: \(error.localizedDescription)" }
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
