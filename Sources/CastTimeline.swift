import SwiftUI
import AppKit

/// The Scene Editor's tracks, laid out like Audacity: a fixed track panel per character on the
/// left (name, mute, solo, volume), a shared ruler on top, and lanes that fill the window with
/// clips you can move and trim. Edits remix the master a moment later.
struct CastTimeline: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore
    @ObservedObject var player: AudioPlayerController
    @Binding var selection: UUID?
    @Binding var pps: CGFloat                     // points per second
    var fitToken: Int
    var onEdit: (CastStore.Clip) -> Void = { _ in }
    @State private var origin: CastStore.Clip?    // the clip as it was when the drag began
    @State private var fitted = false
    @State private var guide: Double?             // snap guide line while dragging

    static let rulerHeight: CGFloat = 26, panelWidth: CGFloat = 200, minLane: CGFloat = 96, maxLane: CGFloat = 220
    static let space = "castTimeline"

    var body: some View {
        GeometryReader { geo in
            let lanes = cast.lanes
            let laneHeight = min(Self.maxLane, max(Self.minLane, (geo.size.height - Self.rulerHeight - 1) / CGFloat(max(1, lanes.count))))
            let trackWidth = geo.size.width - Self.panelWidth
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Text("Tracks").font(.traceCaption).foregroundStyle(Trace.pencil)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                            .frame(height: Self.rulerHeight)
                        Rectangle().fill(Trace.rule).frame(height: 1)
                        ForEach(lanes, id: \.self) { lane in
                            TrackPanel(lane: lane, height: laneHeight)
                        }
                    }
                    .frame(width: Self.panelWidth)
                    .background(Trace.sheet)
                    Rectangle().fill(Trace.rule).frame(width: 1)
                    ScrollViewReader { reader in
                        ScrollView(.horizontal) {
                            canvas(lanes: lanes, laneHeight: laneHeight, minWidth: trackWidth - 1)
                        }
                        // Follow the playhead a page at a time, like Audacity.
                        .onChange(of: page(trackWidth)) { _, page in
                            guard let page else { return }
                            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("page\(page)", anchor: .leading) }
                        }
                    }
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .onAppear { if !fitted { fit(trackWidth); fitted = true } }
            .onChange(of: fitToken) { _, _ in fit(trackWidth) }
        }
    }

    private var playhead: Double? {
        guard let master = cast.masterURL, player.loadedURL == master else { return nil }
        return player.currentTime
    }

    /// Which page-width of the timeline the playhead is on.
    private func page(_ width: CGFloat) -> Int? {
        guard let playhead, width > 40 else { return nil }
        return Int(CGFloat(playhead) * pps / (width - 40))
    }

    private var snapping: Bool { !NSEvent.modifierFlags.contains(.command) }

    private func fit(_ width: CGFloat) {
        let duration = max(1, cast.timelineDuration)
        pps = min(400, max(10, (width - 40) / CGFloat(duration)))
    }

    /// Seconds from a drag distance, snapped to 10 ms.
    private func seconds(_ points: CGFloat) -> Double { (Double(points / pps) * 100).rounded() / 100 }

    // MARK: Canvas

    private func canvas(lanes: [String], laneHeight: CGFloat, minWidth: CGFloat) -> some View {
        let width = max(minWidth, CGFloat(cast.timelineDuration + 2) * pps)
        let height = Self.rulerHeight + 1 + CGFloat(lanes.count) * laneHeight
        let pageWidth = max(40, minWidth - 40)
        return ZStack(alignment: .topLeading) {
            // Scroll targets, one per page, for following the playhead.
            HStack(spacing: 0) {
                ForEach(0..<max(1, Int(width / pageWidth) + 1), id: \.self) { i in
                    Color.clear.frame(width: pageWidth, height: 1).id("page\(i)")
                }
            }
            .allowsHitTesting(false)
            grid(width: width, height: height, lanes: lanes.count, laneHeight: laneHeight)
                .onTapGesture { selection = nil }
            ruler(width: width)
            ForEach(cast.clips) { clip in
                if let row = lanes.firstIndex(of: clip.lane) {
                    clipView(clip, height: laneHeight - 10)
                        .offset(x: CGFloat(clip.start) * pps,
                                y: Self.rulerHeight + 1 + CGFloat(row) * laneHeight + 5)
                }
            }
            if let guide {
                Rectangle().fill(Trace.ok).frame(width: 1, height: height).offset(x: CGFloat(guide) * pps)
                    .allowsHitTesting(false)
            }
            if let master = cast.masterURL, player.loadedURL == master {
                let x = CGFloat(player.currentTime) * pps
                Rectangle().fill(Trace.record).frame(width: 1.5, height: height).offset(x: x)
                    .allowsHitTesting(false)
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 10, y: 0)); p.addLine(to: CGPoint(x: 5, y: 8)); p.closeSubpath() }
                    .fill(Trace.record).frame(width: 10, height: 8).offset(x: x - 4.25, y: Self.rulerHeight - 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Drags measure against the canvas, which stays still; measured in a clip's own space the
        // clip moving under the pointer fed back into the drag and made it jitter.
        .coordinateSpace(name: Self.space)
    }

    private var tickStep: Double { pps >= 160 ? 0.25 : pps >= 60 ? 1 : pps >= 20 ? 2 : 5 }

    /// Track backgrounds, separators and time lines running down every track.
    private func grid(width: CGFloat, height: CGFloat, lanes: Int, laneHeight: CGFloat) -> some View {
        Canvas { ctx, size in
            for row in 0..<lanes {
                let y = Self.rulerHeight + 1 + CGFloat(row) * laneHeight
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: laneHeight)),
                         with: .color(row.isMultiple(of: 2) ? Trace.ground : Trace.sheet.opacity(0.55)))
                ctx.fill(Path(CGRect(x: 0, y: y + laneHeight - 0.5, width: size.width, height: 0.5)), with: .color(Trace.rule))
            }
            let step = tickStep * 4
            var t = 0.0
            while CGFloat(t) * pps < size.width {
                ctx.fill(Path(CGRect(x: CGFloat(t) * pps, y: Self.rulerHeight, width: 0.5, height: size.height)),
                         with: .color(Trace.rule.opacity(0.6)))
                t += step
            }
        }
        .frame(width: width, height: height)
    }

    private func ruler(width: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Trace.sheet))
            ctx.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)), with: .color(Trace.rule))
            var t = 0.0, i = 0
            while CGFloat(t) * pps < size.width {
                let x = CGFloat(t) * pps
                let major = i % 4 == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (major ? 10 : 5), width: 0.5, height: major ? 10 : 5)),
                         with: .color(Trace.graphite))
                if major {
                    ctx.draw(Text(timecode(t, tenths: tickStep < 1)).font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Trace.graphite),
                             at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
                t += tickStep; i += 1
            }
        }
        .frame(width: width, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            guard let master = cast.masterURL else { return }
            player.seek(master, to: max(0, Double(tap.location.x / pps)))
            if !player.isPlaying(master) { player.toggle(master) }
        })
        .help("Click to play from here")
    }

    // MARK: Clips

    private func clipView(_ clip: CastStore.Clip, height: CGFloat) -> some View {
        let width = max(8, CGFloat(clip.length) * pps)
        let isSelected = selection == clip.id
        let audible = cast.isAudible(clip.lane)
        let issues = cast.issues(for: clip)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                if !issues.isEmpty {
                    Label("\(issues.count)", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon).foregroundStyle(isSelected ? Color.white : Trace.record)
                        .help("Whisper heard: " + issues.map { "“\($0.word)”" + ($0.heard.map { " as “\($0)”" } ?? " missing") }.joined(separator: ", "))
                }
                if clip.over { Image(systemName: "arrow.uturn.left").help("Talks over the previous line") }
                Text(clip.text).lineLimit(1)
                Spacer(minLength: 0)
                if clip.cut { Image(systemName: "scissors").help("Cut off by the next line") }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : Trace.ink)
            .padding(.horizontal, 6)
            .frame(width: width, height: 18, alignment: .leading)
            .background(isSelected ? Trace.cobaltFill : Trace.cobalt.opacity(0.28))
            .clipped()
            if let url = cast.lines[safe: clip.unit]?.output {
                ClipWave(url: url, srcIn: clip.srcIn, srcOut: clip.srcOut,
                         duration: cast.unitDuration(clip.unit) ?? clip.srcOut)
                    .padding(.horizontal, 1).padding(.vertical, 3)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .topLeading) {
            // Where Whisper heard a word wrongly or not at all.
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Rectangle().fill(Trace.record.opacity(0.8)).frame(width: 2, height: height - 18)
                    .offset(x: CGFloat(issue.t) * pps, y: 18)
                    .allowsHitTesting(false)
            }
        }
        .background(Trace.cobalt.opacity(isSelected ? 0.16 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isSelected ? Trace.cobalt : Trace.rule, lineWidth: isSelected ? 1.5 : 0.5))
        .opacity(audible ? 1 : 0.4)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space)).onChanged { value in
            let base = origin ?? clip
            if origin == nil { origin = clip; selection = clip.id }
            let landing = cast.landing(clip.id, proposed: base.start + seconds(value.translation.width),
                                       snapping: snapping, playhead: playhead, tolerance: Double(8 / pps))
            guide = landing.guide
            cast.editClip(clip.id) { $0.start = landing.start }
        }.onEnded { _ in origin = nil; guide = nil; cast.commitEdit(model) })
        .onTapGesture(count: 2) { selection = clip.id; onEdit(clip) }
        .onTapGesture { selection = clip.id }
        .overlay(alignment: .leading) { edge(clip, leading: true) }
        .overlay(alignment: .trailing) { edge(clip, leading: false) }
        .help(clip.text)
    }

    /// Trim handles: the left edge moves the clip's start with its in-point.
    private func edge(_ clip: CastStore.Clip, leading: Bool) -> some View {
        Rectangle().fill(Color.clear).frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space)).onChanged { value in
                let base = origin ?? clip
                if origin == nil { origin = clip; selection = clip.id }
                let limits = cast.trimLimits(clip.id)
                let edges = snapping ? cast.snapEdges(excluding: clip.id, playhead: playhead) : []
                let tolerance = Double(8 / pps)
                if leading {
                    var edge = base.start + seconds(value.translation.width)
                    let snapped = CastStore.snap(edge, to: edges, within: tolerance)
                    edge = max(limits.earliest, snapped ?? edge)
                    guide = snapped == edge ? snapped : nil
                    cast.editClip(clip.id) { c in
                        let newIn = min(max(0, base.srcIn + (edge - base.start)), base.srcOut - 0.05)
                        c.srcIn = newIn
                        c.start = base.start + (newIn - base.srcIn)
                    }
                } else {
                    var edge = base.end + seconds(value.translation.width)
                    let snapped = CastStore.snap(edge, to: edges, within: tolerance)
                    edge = min(limits.latest, snapped ?? edge)
                    guide = snapped == edge ? snapped : nil
                    cast.editClip(clip.id) { c in c.srcOut = max(base.srcIn + 0.05, base.srcOut + (edge - base.end)) }
                }
            }.onEnded { _ in origin = nil; guide = nil; cast.commitEdit(model) })
    }
}

/// Audacity-style track control panel: name, mute, solo and volume for one character's lane.
struct TrackPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cast: CastStore
    let lane: String
    let height: CGFloat

    var body: some View {
        let muted = cast.tracks.muted.contains(lane), soloed = cast.tracks.soloed.contains(lane)
        VStack(alignment: .leading, spacing: 8) {
            Text(lane).font(.traceValue.weight(.semibold)).foregroundStyle(Trace.ink).lineLimit(1)
            HStack(spacing: 6) {
                toggle("Mute", on: muted, tint: Trace.record) { toggleSet(\.muted) }
                toggle("Solo", on: soloed, tint: Trace.cobaltFill) { toggleSet(\.soloed) }
                Spacer()
                let count = cast.clips.filter { $0.lane == lane }.count
                Text("\(count) \(count == 1 ? "line" : "lines")").font(.traceCaption).foregroundStyle(Trace.pencil)
            }
            if height >= 110 {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(Trace.pencil)
                    Slider(value: Binding(get: { cast.tracks.gain[lane] ?? 0 }, set: { value in
                        cast.tracks.gain[lane] = (value * 2).rounded() / 2
                        cast.commitEdit(model)
                    }), in: -24...6)
                    .controlSize(.mini)
                    Text(String(format: "%+.1f", cast.tracks.gain[lane] ?? 0)).font(.traceValue.monospacedDigit())
                        .foregroundStyle(Trace.graphite).frame(width: 34, alignment: .trailing)
                }
                .help("Track volume in dB")
            }
        }
        .padding(.horizontal, 12).padding(.top, 12)
        .frame(width: CastTimeline.panelWidth, height: height, alignment: .top)
        .overlay(alignment: .bottom) { Rectangle().fill(Trace.rule).frame(height: 0.5) }
    }

    private func toggle(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? Color.white : Trace.graphite)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(on ? tint : Trace.ground, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Trace.rule, lineWidth: on ? 0 : 0.5))
        }
        .buttonStyle(.plain)
        .help(title == "Mute" ? "Leave this character out of the mix" : "Hear only soloed characters")
    }

    private func toggleSet(_ key: WritableKeyPath<CastStore.Tracks, [String]>) {
        if let i = cast.tracks[keyPath: key].firstIndex(of: lane) {
            cast.tracks[keyPath: key].remove(at: i)
        } else {
            cast.tracks[keyPath: key].append(lane)
        }
        cast.commitEdit(model)
    }
}

/// One clip's slice of its rendered audio, drawn as a filled waveform like Audacity.
struct ClipWave: View {
    let url: URL
    let srcIn: Double, srcOut: Double, duration: Double
    @State private var envelope: TraceEnvelope?

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(Trace.cobalt.opacity(0.5)))
            guard let env = envelope, !env.maxs.isEmpty, duration > 0, size.width > 1 else { return }
            let n = env.maxs.count
            let a = max(0, min(n - 1, Int(srcIn / duration * Double(n))))
            let b = max(a + 1, min(n, Int(srcOut / duration * Double(n))))
            let columns = max(1, Int(size.width))
            var shape = Path(), bottom: [CGPoint] = []
            for c in 0..<columns {
                let lo = a + (b - a) * c / columns, hi = max(lo + 1, a + (b - a) * (c + 1) / columns)
                var mx: Float = 0, mn: Float = 0
                for i in lo..<min(hi, b) { mx = max(mx, env.maxs[i]); mn = min(mn, env.mins[i]) }
                let x = CGFloat(c)
                let pt = CGPoint(x: x, y: mid - CGFloat(mx) * mid * 0.95)
                if c == 0 { shape.move(to: pt) } else { shape.addLine(to: pt) }
                bottom.append(CGPoint(x: x, y: mid - CGFloat(mn) * mid * 0.95))
            }
            for pt in bottom.reversed() { shape.addLine(to: pt) }
            shape.closeSubpath()
            ctx.fill(shape, with: .color(Trace.cobalt.opacity(0.85)))
        }
        .task(id: url) { envelope = await TraceLoader.envelope(url: url, buckets: 4000) }
        .allowsHitTesting(false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
