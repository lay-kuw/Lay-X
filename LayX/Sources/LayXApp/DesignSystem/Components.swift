import SwiftUI
import AppKit
import LayXCore

// MARK: - Glass transparency environment

private struct GlassTransparencyKey: EnvironmentKey { static let defaultValue: Double = LX.Glass.defaultValue }
private struct GlowPresetKey: EnvironmentKey { static let defaultValue: LX.Glow = .violet }
private struct FullGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Settings → Appearance → Full glass: the whole window (content panes, cards) becomes translucent.
    var fullGlass: Bool {
        get { self[FullGlassKey.self] }
        set { self[FullGlassKey.self] = newValue }
    }
    var glowPreset: LX.Glow {
        get { self[GlowPresetKey.self] }
        set { self[GlowPresetKey.self] = newValue }
    }
    var glassTransparency: Double {
        get { self[GlassTransparencyKey.self] }
        set { self[GlassTransparencyKey.self] = newValue }
    }
}

// MARK: - Materials

/// Wraps NSVisualEffectView so the window can show the wallpaper behind it.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Window backdrop: wallpaper blur + base + two glows (deep violet top-left, faint lavender bottom-right).
struct Backdrop: View {
    @Environment(\.glassTransparency) private var t
    @Environment(\.glowPreset) private var glow
    @Environment(\.fullGlass) private var fullGlass
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blending: .behindWindow)
                LX.C.base.opacity(LX.Glass.baseOpacity(t) * (fullGlass ? LX.Glass.fullGlassScale : 1))
                RadialGradient(colors: [glow.primary, .clear],
                               center: UnitPoint(x: 0.08, y: 0.10),
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.45)
                RadialGradient(colors: [glow.secondary, .clear],
                               center: UnitPoint(x: 0.96, y: 0.94),
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

/// Glass pane: material + dark tint + 1px edge + top highlight.
struct PaneBackground: ViewModifier {
    var radius: CGFloat = LX.R.xl
    var tint: Color = LX.C.pane
    var shadow: Bool = true
    @Environment(\.glassTransparency) private var t
    @Environment(\.fullGlass) private var fullGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    if !fullGlass { shape.fill(.ultraThinMaterial) }
                    shape.fill(tint.opacity(LX.Glass.tintScale(t) * (fullGlass ? LX.Glass.fullGlassPaneScale : 1)))
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LX.C.edge, lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [LX.C.highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(shadow ? 0.25 : 0), radius: 15, y: 10)
    }
}

/// Recessed well for cards, inputs and meters.
struct WellBackground: ViewModifier {
    var radius: CGFloat = LX.R.lg
    var fill: Color = LX.C.well
    @Environment(\.fullGlass) private var fullGlass
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(fill.opacity(fullGlass ? LX.Glass.fullGlassWellScale : 1)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Translucent accent glass — used instead of any solid accent fill.
struct AccentGlass: ViewModifier {
    var radius: CGFloat = LX.R.md
    var strength: Double = 1
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(
                        colors: [LX.C.accent.opacity(0.30 * strength), LX.C.accent.opacity(0.14 * strength)],
                        startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LX.C.accent.opacity(0.42 * strength), lineWidth: 1))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1))
            .shadow(color: LX.C.accent.opacity(0.16 * strength), radius: 9)
    }
}

extension View {
    func pane(radius: CGFloat = LX.R.xl, tint: Color = LX.C.pane, shadow: Bool = true) -> some View {
        modifier(PaneBackground(radius: radius, tint: tint, shadow: shadow))
    }
    func well(radius: CGFloat = LX.R.lg, fill: Color = LX.C.well) -> some View {
        modifier(WellBackground(radius: radius, fill: fill))
    }
    func accentGlass(radius: CGFloat = LX.R.md, strength: Double = 1) -> some View {
        modifier(AccentGlass(radius: radius, strength: strength))
    }
}

// MARK: - Window controls

/// Custom close / minimize / zoom buttons drawn inside the sidebar pane
/// (the system buttons are hidden by WindowConfigurator).
struct TrafficLights: View {
    @Environment(\.controlActiveState) private var activeState
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(hex: 0xFF5F57), symbol: "xmark", label: "Close") { window?.performClose(nil) }
            light(Color(hex: 0xFEBC2E), symbol: "minus", label: "Minimize") { window?.miniaturize(nil) }
            light(Color(hex: 0x28C840), symbol: "plus", label: "Full Screen") { window?.toggleFullScreen(nil) }
        }
        .onHover { h in hover = h }
    }

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }
    private var active: Bool { activeState == .key || activeState == .active || hover }

    private func light(_ color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(active ? color : Color.white.opacity(0.18))
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                if hover {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Small parts

struct Keycap: View {
    let text: String
    var onGlass = false
    var body: some View {
        Text(text)
            .font(LX.F.ui(10.5))
            .foregroundStyle(onGlass ? Color(hex: 0xD6DBFF) : LX.C.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: LX.R.xs).fill(Color.white.opacity(onGlass ? 0.10 : 0.07)))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(LX.F.label).kerning(0.8).foregroundStyle(LX.C.tertiary)
            if let trailing { Text(trailing).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary) }
            Spacer(minLength: 0)
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = LX.C.body
    var body: some View {
        Text(text)
            .font(LX.F.mono(10))
            .kerning(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: LX.R.xs).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

struct LiveDot: View {
    var color: Color = LX.C.ok
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color, radius: 4)
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.4))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// 1px flowing gradient shown while the model is generating.
struct GeneratingRibbon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: LX.C.liveCyan, location: 0.25),
                        .init(color: Color(hex: 0x9D8CFF), location: 0.5),
                        .init(color: LX.C.liveCyan, location: 0.75),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 2)
                .offset(x: -geo.size.width * CGFloat(t))
            }
        }
        .frame(height: 1)
        .clipped()
    }
}

/// Live outline for a container that is generating: a cyan→violet gradient that travels around the whole
/// border, with a soft outer glow. Static when Reduce Motion is on.
struct GlowingBorder: View {
    var radius: CGFloat = LX.R.xl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let angle = Angle.degrees((ctx.date.timeIntervalSinceReferenceDate * 110).truncatingRemainder(dividingBy: 360))
            let gradient = AngularGradient(
                colors: [LX.C.liveCyan, Color(hex: 0x9D8CFF), LX.C.liveViolet.opacity(0.25), LX.C.liveCyan.opacity(0.25), LX.C.liveCyan],
                center: .center, angle: angle)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 1.5)
                shape.strokeBorder(gradient, lineWidth: 4).blur(radius: 8).opacity(0.55)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LX.C.accent)
            .frame(width: 7, height: 15)
            .shadow(color: LX.C.accent.opacity(0.8), radius: 5)
            .opacity(on ? 1 : 0)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in on.toggle() }
    }
}

// MARK: - Buttons

enum LXButtonKind { case primary, secondary, danger, plain }

struct LXButtonStyle: ButtonStyle {
    var kind: LXButtonKind = .secondary
    var height: CGFloat = LX.S.control

    func makeBody(configuration: Configuration) -> some View {
        LXButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

/// Primary = accent glass; secondary / danger = soft borderless tint that deepens on hover and press.
private struct LXButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LXButtonKind
    let height: CGFloat
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let label = configuration.label
            .font(LX.F.ui(12, kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: height)
        let shape = RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
        let level = configuration.isPressed ? 2.0 : (hover && enabled ? 1.0 : 0.0)
        return Group {
            switch kind {
            case .primary:
                label.foregroundStyle(LX.C.onGlass).accentGlass(strength: 1 + 0.15 * level)
            case .secondary:
                label.foregroundStyle(hover && enabled ? LX.C.primary : LX.C.body)
                    .background(shape.fill(Color.white.opacity(0.055 + 0.03 * level)))
            case .danger:
                label.foregroundStyle(Color(hex: 0xFF9C9C))
                    .background(shape.fill(Color(hex: 0xFF5A5A, alpha: 0.08 + 0.05 * level)))
            case .plain:
                label.foregroundStyle(LX.C.body)
                    .background(shape.fill(Color.white.opacity(0.05 * level)))
            }
        }
        .contentShape(shape)
        .opacity(enabled ? 1 : 0.5)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(LX.M.hover, value: configuration.isPressed)
        .animation(LX.M.hover, value: hover)
        .onHover { hover = $0 }
    }
}

/// Button with a label and optional SF Symbol. `shortcut` is accepted for call-site documentation only:
/// shortcut hints are not shown in the UI (user decision 2026-11-16); bind keys with `.keyboardShortcut`.
struct LXButton: View {
    let title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var kind: LXButtonKind = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(LXButtonStyle(kind: kind))
    }
}

/// Borderless control style shared by icon buttons and chips: quiet at rest, a soft tint on hover, a deeper
/// tint and a slight press-in when clicked. No outlines — the design's "quiet" controls.
struct QuietButtonStyle: ButtonStyle {
    var radius: CGFloat = LX.R.md
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, radius: radius, active: active)
    }
}

/// View that owns the hover state (ButtonStyle itself can't hold @State).
private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    let active: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .foregroundStyle(!enabled ? LX.C.tertiary : (active ? LX.C.accentText : (hover ? LX.C.primary : LX.C.secondary)))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? LX.C.accent.opacity(configuration.isPressed ? 0.20 : (hover ? 0.16 : 0.11))
                                 : Color.white.opacity(configuration.isPressed ? 0.11 : (hover && enabled ? 0.06 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LX.M.hover, value: configuration.isPressed)
            .animation(LX.M.hover, value: hover)
            .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(QuietButtonStyle(active: active))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Composer send / stop: an icon on a small rounded square of accent glass (never a solid fill).
struct SendButton: View {
    enum Mode { case send, stop }
    let mode: Mode
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .send ? "arrow.up" : "stop.fill")
                .font(.system(size: mode == .send ? 13 : 10, weight: .bold))
                .foregroundStyle(enabled ? LX.C.onGlass : LX.C.tertiary)
                .frame(width: 28, height: 28)
                .modifier(SendBackground(enabled: enabled, hover: hover))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help(mode == .send ? "Send" : "Stop generating")
        .accessibilityLabel(mode == .send ? "Send" : "Stop")
    }
}

private struct SendBackground: ViewModifier {
    let enabled: Bool
    let hover: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.accentGlass(radius: 8, strength: hover ? 1.25 : 1)
        } else {
            content.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(LX.M.hover, value: configuration.isPressed)
    }
}

// MARK: - Controls

struct LXToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? LX.C.accent.opacity(0.38) : Color.white.opacity(0.12))
                    .overlay(Capsule().strokeBorder(configuration.isOn ? LX.C.accent.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1))
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(configuration.isOn ? Color.white : Color(hex: 0xC9CBD6))
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(LX.M.hover, value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

struct Checkbox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: LX.R.xs)
                    .fill(isOn ? LX.C.accent.opacity(0.30) : .clear)
                RoundedRectangle(cornerRadius: LX.R.xs)
                    .strokeBorder(isOn ? LX.C.accent.opacity(0.6) : Color.white.opacity(0.25), lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(LX.C.onGlass)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "checked" : "unchecked")
    }
}

struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var mono = false
    /// Optional live indicator (SF Symbol) shown after a segment's title, e.g. while downloading.
    var indicators: [T: String] = [:]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let (value, title) = option
                Button { withAnimation(LX.M.hover) { selection = value } } label: {
                    HStack(spacing: 5) {
                        Text(title)
                        if let symbol = indicators[value] {
                            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(LX.C.liveCyan)
                                .symbolEffect(.pulse, options: .repeating)
                        }
                    }
                        .font(mono ? LX.F.mono(12) : LX.F.ui(12))
                        .foregroundStyle(selection == value ? LX.C.primary : LX.C.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 5).fill(LX.C.accent.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LX.C.accent.opacity(0.25), lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .well(radius: LX.R.md, fill: Color.black.opacity(0.25))
    }
}

struct LXField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String? = nil
    var mono = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(LX.C.tertiary) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? LX.F.mono(12.5) : LX.F.ui(12.5))
                .foregroundStyle(LX.C.primary)
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .frame(height: LX.S.control)
        .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
        .overlay(RoundedRectangle(cornerRadius: LX.R.md).strokeBorder(LX.C.accent.opacity(focused ? 0.7 : 0), lineWidth: 2))
    }
}

struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let pct = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                    Capsule().fill(LX.C.liveGradient).frame(width: max(4, geo.size.width * pct), height: 4)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: geo.size.width * pct - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let p = min(max(0, g.location.x / geo.size.width), 1)
                    value = range.lowerBound + p * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 18)
            Text(format(value)).font(LX.F.mono(12)).foregroundStyle(LX.C.primary).frame(width: 62, alignment: .trailing)
        }
        .frame(width: 260)
        .accessibilityElement()
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
        }
    }
}

// MARK: - Metrics

struct MetricsStrip: View {
    let ttft: String
    let tps: String
    let memory: String
    var live = false
    var body: some View {
        HStack(spacing: 14) {
            if live { LiveDot(color: LX.C.liveCyan) }
            metric(ttft, "TTFT")
            metric(tps, "tok/s")
            metric(memory, "GB")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .well(radius: LX.R.md, fill: Color.black.opacity(0.25))
    }
    private func metric(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(LX.F.mono(12)).foregroundStyle(LX.C.primary).contentTransition(.numericText())
            Text(unit).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary)
        }
    }
}

/// Sidebar memory meter: MLX active (gradient), MLX cache (violet), rest of the system (grey) of total RAM.
struct MemoryMeter: View {
    @Environment(InferenceStatusModel.self) private var inference
    private let total = Double(HardwareInfo.current.memoryBytes)

    var body: some View {
        let gb = 1_073_741_824.0
        let active = Double(inference.engineMemory?.activeBytes ?? 0)
        let cache = Double(inference.engineMemory?.cacheBytes ?? 0)
        let system = Double(inference.systemMemoryUsed ?? 0)
        let other = max(system - active - cache, 0)
        let chip = HardwareInfo.current.chip.replacingOccurrences(of: "Apple ", with: "")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(chip) · Unified").font(LX.F.caption).foregroundStyle(LX.C.secondary).lineLimit(1)
                Spacer()
                Text("\(Text(String(format: "%.1f", system / gb)).foregroundStyle(LX.C.primary))\(Text(" / \(Int(total / gb)) GB").foregroundStyle(LX.C.tertiary))")
                    .font(LX.F.mono(11.5))
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(LX.C.liveGradient).frame(width: geo.size.width * active / total)
                    Rectangle().fill(Color(hex: 0x5D63B8)).frame(width: geo.size.width * cache / total)
                    Rectangle().fill(Color(hex: 0x3A3D4E)).frame(width: geo.size.width * other / total)
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .padding(10)
        .well(radius: 8)
        .help(String(format: "Model (MLX active) %.1f GB · MLX cache %.1f GB · other apps & system %.1f GB", active / gb, cache / gb, other / gb))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: "Memory: %.1f of %.0f gigabytes used", system / gb, total / gb))
    }
}

// MARK: - Code

enum Syntax {
    static let keywords: Set<String> = ["let", "var", "func", "final", "class", "struct", "private", "set", "some",
                                        "guard", "else", "return", "try", "await", "in", "nil", "_", "@MainActor",
                                        "@Published", "import", "if", "for", "self"]

    /// Tiny tokenizer for mock code: keywords, Types, "strings", numbers.
    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        var i = code.startIndex
        func append(_ s: Substring, _ color: Color) {
            var a = AttributedString(String(s)); a.foregroundColor = color; out += a
        }
        while i < code.endIndex {
            let c = code[i]
            if c == "\"" {
                var j = code.index(after: i)
                while j < code.endIndex && code[j] != "\"" { j = code.index(after: j) }
                if j < code.endIndex { j = code.index(after: j) }
                append(code[i..<j], LX.C.synString); i = j
            } else if c.isLetter || c == "@" || c == "_" {
                var j = code.index(after: i)
                while j < code.endIndex && (code[j].isLetter || code[j].isNumber || code[j] == "_") { j = code.index(after: j) }
                let word = code[i..<j]
                if keywords.contains(String(word)) { append(word, LX.C.synKeyword) }
                else if word.first?.isUppercase == true { append(word, LX.C.synType) }
                else { append(word, LX.C.body) }
                i = j
            } else if c.isNumber {
                var j = code.index(after: i)
                while j < code.endIndex && (code[j].isNumber || code[j] == ".") { j = code.index(after: j) }
                append(code[i..<j], LX.C.synNumber); i = j
            } else {
                append(code[i...i], LX.C.body); i = code.index(after: i)
            }
        }
        return out
    }
}

struct CodeBlock: View {
    let language: String
    let filename: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language).foregroundStyle(LX.C.tertiary)
                if !filename.isEmpty {
                    Text("·").foregroundStyle(Color(hex: 0x4A4D5C))
                    Text(filename).foregroundStyle(LX.C.secondary)
                }
                Spacer()
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
            }
            .font(LX.F.mono(11))
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: 30)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text(Syntax.highlight(code))
                .font(LX.F.code)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .well(radius: 8, fill: LX.C.code)
    }
}

// MARK: - Toast

struct Toast: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(LX.C.ok)
            Text(text).font(LX.F.ui(12.5)).foregroundStyle(LX.C.primary)
        }
        .padding(.horizontal, 14).frame(height: 36)
        .pane(radius: LX.R.xl, tint: LX.C.overlay.opacity(0.6))
    }
}
