import SwiftUI
import AppKit
import AVFoundation

// MARK: - "The Trace" design system
//
// A voice is a line drawn on paper (after Scott's 1857 phonautograph).
// Paper (light) and Soot (dark) follow the macOS appearance. One accent:
// cobalt means "you can act"; red means "capturing or playing now".
// No gradients, no glows, no decoration that does not carry information.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A colour that follows the system light/dark appearance.
    static func trace(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Trace {
    static let ground   = Color.trace(light: 0xF2EFE8, dark: 0x141412)
    static let sheet    = Color.trace(light: 0xFAF8F3, dark: 0x1C1C19)
    static let rule     = Color.trace(light: 0xD8D3C7, dark: 0x2F2E2A)
    static let ink      = Color.trace(light: 0x1B1A18, dark: 0xECE8DE)
    static let graphite = Color.trace(light: 0x66625A, dark: 0x9C978C)
    static let pencil   = Color.trace(light: 0xA29D92, dark: 0x5E5B54)
    static let cobalt   = Color.trace(light: 0x2337C6, dark: 0x8C9CFF)
    /// Fill for the one primary button: deep enough for white text in both modes.
    static let cobaltFill = Color.trace(light: 0x2337C6, dark: 0x3F55E6)
    static let record   = Color.trace(light: 0xD9301C, dark: 0xFF5B3F)
    static let ok       = Color.trace(light: 0x2F7D4F, dark: 0x5FBF85)

    static let controlRadius: CGFloat = 6
    static let sheetRadius: CGFloat = 10
    static let sidebarWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 288

    static let scriptNSFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 17)
        if let serif = base.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: serif, size: 17) ?? base }
        return base
    }()
}

extension Font {
    static let traceTitle = Font.system(size: 22, weight: .semibold)
    static let traceSection = Font.system(size: 14, weight: .semibold, design: .serif)
    static let traceBody = Font.system(size: 13)
    static let traceCaption = Font.system(size: 11)
    static let traceValue = Font.system(size: 11, design: .monospaced)
}

// MARK: - Surfaces

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Trace.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    /// The single document surface of a screen: flat paper with a hairline edge.
    func traceSheet() -> some View {
        background(Trace.sheet)
            .clipShape(RoundedRectangle(cornerRadius: Trace.sheetRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Trace.sheetRadius, style: .continuous).strokeBorder(Trace.rule))
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String? = nil
    init(_ title: String, trailing: String? = nil) { self.title = title; self.trailing = trailing }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.traceSection).foregroundStyle(Trace.ink)
            Spacer()
            if let trailing { Text(trailing).font(.traceValue).foregroundStyle(Trace.graphite) }
        }
    }
}

/// Label column + control, the building block of every inspector.
struct InspectorRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) { self.label = label; self.control = control() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.traceBody).foregroundStyle(Trace.graphite)
                .frame(width: 84, alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A slider drawn as a measuring rule: ticks, an ink run up to the value and
/// a cobalt needle. Drag or click anywhere on the rule; arrow keys via VoiceOver.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.2f"
    var help: String? = nil

    private var span: Double { range.upperBound - range.lowerBound }
    private var integral: Bool { format == "%.0f" }
    private var fraction: Double { span > 0 ? (value - range.lowerBound) / span : 0 }

    private func set(_ f: Double) {
        var v = range.lowerBound + max(0, min(1, f)) * span
        v = integral ? v.rounded() : (v * 1000).rounded() / 1000
        value = min(range.upperBound, max(range.lowerBound, v))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.traceBody).foregroundStyle(Trace.graphite)
                Spacer()
                Text(String(format: format, value)).font(.traceValue).foregroundStyle(Trace.ink)
            }
            GeometryReader { geo in
                Canvas { ctx, size in
                    let w = size.width, base = size.height - 2
                    ctx.fill(Path(CGRect(x: 0, y: base, width: w, height: 1)), with: .color(Trace.rule))
                    for i in 0...20 {
                        let x = CGFloat(i) / 20 * w
                        let tall = i % 5 == 0
                        ctx.fill(Path(CGRect(x: min(w - 1, x), y: base - (tall ? 6 : 3), width: 1, height: tall ? 6 : 3)),
                                 with: .color(Trace.pencil))
                    }
                    let x = CGFloat(fraction) * w
                    ctx.fill(Path(CGRect(x: 0, y: base - 0.5, width: x, height: 2)), with: .color(Trace.ink))
                    ctx.fill(Path(CGRect(x: x - 0.75, y: base - 13, width: 1.5, height: 13)), with: .color(Trace.cobalt))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: base - 17, width: 7, height: 7)), with: .color(Trace.cobalt))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { set($0.location.x / max(1, geo.size.width)) })
            }
            .frame(height: 20)
        }
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: format, value))
        .accessibilityAdjustableAction { direction in
            let step = integral ? 1 : span / 40
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// Text tabs with an ink underline, used in place of blue segmented controls.
struct InkTabs<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.1) { title, value in
                let on = selection == value
                Button { selection = value } label: {
                    VStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: size, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Trace.ink : Trace.graphite)
                        Rectangle().fill(on ? Trace.ink : Color.clear).frame(height: 1.5)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Inline event token, like a tag: outlined, quiet, never coloured.
struct TokenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenBody(configuration: configuration)
    }

    private struct TokenBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Trace.ink.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(configuration.isPressed ? Trace.rule.opacity(0.6) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Trace.rule))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

struct EmptyNote: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.traceBody).foregroundStyle(Trace.graphite)
            if let detail { Text(detail).font(.traceCaption).foregroundStyle(Trace.pencil).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func timecode(_ seconds: Double, tenths: Bool = false) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let m = Int(seconds) / 60, s = Int(seconds) % 60
    if tenths { return String(format: "%d:%02d.%d", m, s, Int(seconds * 10) % 10) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - The trace (waveform)

/// Min/max envelope of an audio file, computed once per file.
struct TraceEnvelope {
    var mins: [Float]
    var maxs: [Float]
    var duration: Double
}

@MainActor
final class TraceCache {
    static let shared = TraceCache()
    private var store: [URL: TraceEnvelope] = [:]
    private var order: [URL] = []
    func get(_ url: URL) -> TraceEnvelope? { store[url] }
    func put(_ url: URL, _ value: TraceEnvelope) {
        store[url] = value; order.append(url)
        if order.count > 120 { store[order.removeFirst()] = nil }
    }
}

enum TraceLoader {
    static func envelope(url: URL, buckets: Int = 600, maxSeconds: Double? = nil) async -> TraceEnvelope? {
        let key = maxSeconds.map { url.appendingPathExtension("head\(Int($0))") }
            ?? (buckets == 600 ? url : url.appendingPathExtension("b\(buckets)"))
        if let cached = await TraceCache.shared.get(key) { return cached }
        let result: TraceEnvelope? = await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let format = file.processingFormat
            let limit = maxSeconds.map { AVAudioFramePosition($0 * format.sampleRate) } ?? file.length
            let frames = AVAudioFrameCount(min(file.length, limit))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  (try? file.read(into: buffer)) != nil,
                  let channel = buffer.floatChannelData?[0] else { return nil }
            let total = Int(buffer.frameLength)
            let n = min(buckets, max(1, total))
            let bucket = max(1, total / n)
            var mins = [Float](repeating: 0, count: n), maxs = [Float](repeating: 0, count: n)
            var peak: Float = 1e-6
            for i in 0..<n {
                let start = i * bucket, end = min(total, start + bucket)
                guard start < end else { continue }
                var lo: Float = 0, hi: Float = 0
                for j in start..<end { let v = channel[j]; lo = min(lo, v); hi = max(hi, v) }
                mins[i] = lo; maxs[i] = hi; peak = max(peak, max(-lo, hi))
            }
            return TraceEnvelope(mins: mins.map { $0 / peak }, maxs: maxs.map { $0 / peak },
                                 duration: Double(frames) / format.sampleRate)
        }.value
        if let result { await TraceCache.shared.put(key, result) }
        return result
    }
}

/// The hero element: a single ink line on a zero baseline, with a seconds
/// ruler beneath, like seismograph paper. Played portion is ink, the rest pencil.
struct TraceView: View {
    let url: URL?
    var progress: Double? = nil
    var showRuler = true
    /// Draw only the opening seconds (used for small voice signatures).
    var excerptSeconds: Double? = nil
    /// A span in seconds to mark on the trace (the Cleaner's chosen stretch).
    var highlight: ClosedRange<Double>? = nil
    var onSeek: ((Double) -> Void)? = nil
    @State private var envelope: TraceEnvelope?

    var body: some View {
        Canvas { ctx, size in
            let rulerHeight: CGFloat = showRuler ? 15 : 0
            let h = size.height - rulerHeight
            let mid = h / 2
            let w = size.width
            ctx.fill(Path(CGRect(x: 0, y: mid, width: w, height: 0.5)), with: .color(Trace.rule))

            if let full = envelope, !full.maxs.isEmpty {
                let env = Self.pooled(full, to: Int(max(8, w / 1.6)))
                if let span = highlight, full.duration > 0 {
                    let x0 = w * CGFloat(span.lowerBound / full.duration), x1 = w * CGFloat(min(1, span.upperBound / full.duration))
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: h)), with: .color(Trace.cobalt.opacity(0.12)))
                    for x in [x0, x1] { ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(Trace.cobalt)) }
                }
                let path = Self.envelopePath(env, width: w, mid: mid, amplitude: mid * 0.9)
                if let progress, progress > 0 {
                    ctx.fill(path, with: .color(Trace.pencil.opacity(0.18)))
                    ctx.stroke(path, with: .color(Trace.pencil), lineWidth: 1)
                    var played = ctx
                    played.clip(to: Path(CGRect(x: 0, y: 0, width: w * min(1, progress), height: h)))
                    played.fill(path, with: .color(Trace.ink.opacity(0.10)))
                    played.stroke(path, with: .color(Trace.ink), lineWidth: 1.25)
                    let x = w * min(1, progress)
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(Trace.record))
                } else {
                    ctx.fill(path, with: .color(Trace.ink.opacity(0.08)))
                    ctx.stroke(path, with: .color(Trace.ink.opacity(progress == nil ? 1 : 0.55)), lineWidth: 1.25)
                }
                if showRuler { Self.drawRuler(ctx, width: w, top: h + 2, duration: full.duration) }
            }
        }
        .overlay {
            if onSeek != nil {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            onSeek?(max(0, min(1, value.location.x / max(1, geo.size.width))))
                        })
                }
            }
        }
        .task(id: url) {
            envelope = nil
            if let url {
                envelope = await TraceLoader.envelope(url: url, buckets: excerptSeconds == nil ? 600 : 90, maxSeconds: excerptSeconds)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue(envelope.map { timecode($0.duration) } ?? "")
    }

    /// Max/min pooling down to roughly one point per 1.6 px.
    static func pooled(_ env: TraceEnvelope, to target: Int) -> TraceEnvelope {
        let n = env.maxs.count
        guard n > target, target > 1 else { return env }
        var mins = [Float](repeating: 0, count: target), maxs = [Float](repeating: 0, count: target)
        for i in 0..<target {
            let a = i * n / target, b = max(a + 1, (i + 1) * n / target)
            mins[i] = env.mins[a..<b].min() ?? 0
            maxs[i] = env.maxs[a..<b].max() ?? 0
        }
        return TraceEnvelope(mins: mins, maxs: maxs, duration: env.duration)
    }

    static func envelopePath(_ env: TraceEnvelope, width: CGFloat, mid: CGFloat, amplitude: CGFloat) -> Path {
        let n = env.maxs.count
        var path = Path()
        func x(_ i: Int) -> CGFloat { n == 1 ? 0 : CGFloat(i) / CGFloat(n - 1) * width }
        path.move(to: CGPoint(x: 0, y: mid - CGFloat(env.maxs[0]) * amplitude))
        for i in 1..<n { path.addLine(to: CGPoint(x: x(i), y: mid - CGFloat(env.maxs[i]) * amplitude)) }
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: x(i), y: mid - CGFloat(env.mins[i]) * amplitude)) }
        path.closeSubpath()
        return path
    }

    static func drawRuler(_ ctx: GraphicsContext, width: CGFloat, top: CGFloat, duration: Double) {
        guard duration > 0 else { return }
        // (minor, major) pairs; labels always land on round times.
        let scales: [(Double, Int)] = [(0.5, 2), (1, 5), (2, 5), (5, 6), (10, 6), (30, 4), (60, 5), (120, 5), (300, 6)]
        let pxPerSecond = Double(width) / duration
        let scale = scales.first { $0.0 * pxPerSecond >= 7 && $0.0 * Double($0.1) * pxPerSecond >= 44 } ?? (600, 6)
        let (minor, every) = scale
        var i = 0
        while Double(i) * minor <= duration + 0.0001 {
            let t = Double(i) * minor
            defer { i += 1 }
            let x = CGFloat(t / duration) * width
            let isMajor = i % every == 0
            ctx.fill(Path(CGRect(x: x, y: top, width: 0.75, height: isMajor ? 5 : 2.5)), with: .color(Trace.pencil))
            if isMajor && x < width - 24 {
                ctx.draw(Text(timecode(t)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Trace.graphite),
                         at: CGPoint(x: x + 2, y: top + 9), anchor: .leading)
            }
        }
    }
}

/// Trace bound to a player: shows progress, click to seek, and a transport.
struct PlayerTrace: View {
    let url: URL
    @ObservedObject var controller: AudioPlayerController
    var showRuler = true
    var showTransport = true
    /// Narrow columns: trace on top at full width, transport beneath.
    var stacked = false
    var highlight: ClosedRange<Double>? = nil

    private var progress: Double? {
        guard controller.loadedURL == url else { return nil }
        let d = controller.duration(for: url)
        guard d > 0 else { return nil }
        let p = controller.currentTime(for: url) / d
        return controller.isPlaying(url) || p > 0 ? p : nil
    }

    private var timeText: String {
        controller.loadedURL == url
            ? "\(timecode(controller.currentTime(for: url))) / \(timecode(controller.duration(for: url)))"
            : timecode(controller.duration(for: url))
    }

    private var playButton: some View {
        Button { controller.toggle(url) } label: {
            Image(systemName: controller.isPlaying(url) ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(controller.isPlaying(url) ? Trace.record : Trace.ink)
                .overlay(Circle().strokeBorder(Trace.rule))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(controller.isPlaying(url) ? "Pause" : "Play")
        .accessibilityLabel(controller.isPlaying(url) ? "Pause" : "Play")
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                TraceView(url: url, progress: progress, showRuler: showRuler, highlight: highlight) { fraction in
                    controller.seek(url, to: fraction * controller.duration(for: url))
                }
                HStack {
                    playButton
                    Spacer()
                    Text(timeText).font(.traceValue).foregroundStyle(Trace.graphite)
                }
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            if showTransport {
                Button { controller.toggle(url) } label: {
                    Image(systemName: controller.isPlaying(url) ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(controller.isPlaying(url) ? Trace.record : Trace.ink)
                        .overlay(Circle().strokeBorder(Trace.rule))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying(url) ? "Pause" : "Play")
                .accessibilityLabel(controller.isPlaying(url) ? "Pause" : "Play")
            }
            TraceView(url: url, progress: progress, showRuler: showRuler, highlight: highlight) { fraction in
                controller.seek(url, to: fraction * controller.duration(for: url))
            }
            if showTransport {
                Text(controller.loadedURL == url
                     ? "\(timecode(controller.currentTime(for: url))) / \(timecode(controller.duration(for: url)))"
                     : timecode(controller.duration(for: url)))
                    .font(.traceValue).foregroundStyle(Trace.graphite)
                    .frame(width: 78, alignment: .trailing)
            }
        }
    }
}

/// While recording or generating, a small red stylus leads a line as it is drawn.
struct Stylus: View {
    var progress: Double? = nil
    var label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let mid = size.height / 2
                let w = size.width
                ctx.fill(Path(CGRect(x: 0, y: mid, width: w, height: 0.5)), with: .color(Trace.rule))
                let head: CGFloat
                if let progress { head = w * CGFloat(max(0.02, min(1, progress))) }
                else { head = reduceMotion ? w * 0.5 : w * CGFloat((t * 0.12).truncatingRemainder(dividingBy: 1)) }
                var line = Path()
                let start = progress == nil ? max(0, head - w * 0.35) : 0
                var x = start
                line.move(to: CGPoint(x: x, y: mid))
                while x < head {
                    let env = sin(x * 0.045 + 1.3) * 0.5 + 0.5
                    let y = mid - CGFloat(sin(x * 0.9 + t * 3) * cos(x * 0.21)) * mid * 0.7 * env
                    line.addLine(to: CGPoint(x: x, y: y)); x += 1.5
                }
                ctx.stroke(line, with: .color(Trace.ink), lineWidth: 1.1)
                ctx.fill(Path(ellipseIn: CGRect(x: head - 3, y: mid - 3, width: 6, height: 6)), with: .color(Trace.record))
            }
        }
        .overlay(alignment: .topLeading) {
            Text(label).font(.traceValue).foregroundStyle(Trace.graphite).padding(.top, 2)
        }
        .accessibilityElement().accessibilityLabel(label)
    }
}

/// Engine status dot used in the toolbar.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// A designed voice has no recording, so it gets a drawn signature instead:
/// a deterministic line whose register, energy and grain come from its descriptors.
struct DesignedSignature: View {
    let seedText: String
    let pitch: String
    let whisper: Bool

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2, w = size.width
            ctx.fill(Path(CGRect(x: 0, y: mid, width: w, height: 0.5)), with: .color(Trace.rule))
            var hash: UInt64 = 1469598103934665603
            for b in seedText.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
            let phase = Double(hash % 1000) / 1000 * .pi * 2
            let freq: Double = pitch.contains("very low") ? 0.035 : pitch.contains("low") ? 0.05
                : pitch.contains("very high") ? 0.13 : pitch.contains("high") ? 0.1 : 0.07
            let grain = Double((hash >> 12) % 100) / 100 * 0.6 + 0.4
            var line = Path()
            var x = 0.0
            line.move(to: CGPoint(x: 0, y: mid))
            while x <= Double(w) {
                // Phrases swell and settle like speech, but never fall silent for long.
                let phrase = (0.25 + 0.75 * abs(sin(x * 0.011 + phase))) * (0.6 + 0.4 * sin(x * 0.0037 + phase * 2))
                let y = sin(x * freq + phase) * (0.65 + 0.35 * cos(x * freq * 0.31 * grain + phase)) * phrase
                line.addLine(to: CGPoint(x: x, y: mid - y * mid * (whisper ? 0.35 : 0.85)))
                x += 1
            }
            ctx.stroke(line, with: .color(Trace.ink), style: StrokeStyle(lineWidth: 1.1, dash: whisper ? [2, 2] : []))
        }
        .accessibilityHidden(true)
    }
}

/// A play / pause button for one file. It observes the player itself: the players live inside
/// AppModel, and a view that only observes the model never hears them change, so a button that
/// read `model.outputPlayer.isPlaying(url)` stayed on "play" while the file played.
struct PlayToggle: View {
    @ObservedObject var player: AudioPlayerController
    let url: URL
    var help = "Play"

    var body: some View {
        let on = player.isPlaying(url)
        Button { player.toggle(url) } label: {
            Image(systemName: on ? "pause.fill" : "play.fill")
                .foregroundStyle(on ? Trace.record : Trace.ink)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(on ? "Pause" : help)
    }
}

/// "Play" / "Pause" for a context menu, current when the menu opens.
struct PlayMenuItem: View {
    @ObservedObject var player: AudioPlayerController
    let url: URL

    var body: some View {
        Button(player.isPlaying(url) ? "Pause" : "Play") { player.toggle(url) }
    }
}

/// Record / Stop Recording for menus. Observes the recorder: menus that read
/// `model.recorder.isRecording` through the model kept saying "Record Reference" while recording.
struct RecordMenuItem: View {
    @ObservedObject var recorder: RecorderController
    let action: () -> Void

    var body: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Record Reference", action: action)
    }
}

/// The same, as a text button ("Listen" / "Stop").
struct ListenToggle: View {
    @ObservedObject var player: AudioPlayerController
    let url: URL

    var body: some View {
        Button(player.isPlaying(url) ? "Stop" : "Listen") { player.toggle(url) }
    }
}
