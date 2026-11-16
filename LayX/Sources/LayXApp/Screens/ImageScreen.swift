import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LayXCore

/// Image generation: prompt + settings on the left, the canvas in the middle, history on the right.
/// Everything runs on this Mac; models are downloaded once in Models and then work offline.
struct ImageScreen: View {
    @EnvironmentObject var state: AppState
    @State private var pickerOpen = false
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let spec = ImagePreferences.spec
        VStack(spacing: 0) {
            ScreenHeader {
                ImageModelPicker(open: $pickerOpen, spec: spec)
            } trailing: {
                HStack(spacing: 6) {
                    if studio.isBusy { BusyIndicator(help: "Generating") }
                    if let folder = studio.imagesFolder {
                        IconButton(symbol: "folder", help: "Show the images folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                }
            }
            if let spec {
                HStack(spacing: 0) {
                    ImageComposer(spec: spec).frame(width: 330).id(spec.id)
                    Rectangle().fill(LX.C.divider).frame(width: 1)
                    ImageCanvas().frame(maxWidth: .infinity)
                    Rectangle().fill(LX.C.divider).frame(width: 1)
                    ImageHistoryGrid().frame(width: 236)
                }
            } else {
                NoImageModelCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topLeading) {
            if pickerOpen {
                Color.black.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { withAnimation(LX.M.mini) { pickerOpen = false } }
                ImageModelPanel(open: $pickerOpen, selected: spec)
                    .padding(.leading, 14).padding(.top, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = studio.notice {
                Toast(text: notice).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if studio.notice == notice { studio.clearMessages() }
                    }
            }
        }
        .animation(LX.M.panel, value: studio.notice)
        .onAppear { library.refresh(); studio.refreshLoRAs() }
    }
}

// MARK: - Model picker (same look as Chat's, with a palette)

struct ImageModelPicker: View {
    @Binding var open: Bool
    let spec: ImageModelSpec?
    @State private var hover = false
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        Button { withAnimation(LX.M.mini) { open.toggle() } } label: {
            HStack(spacing: 7) {
                Group {
                    if studio.phase == .loadingModel {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "paintpalette").font(.system(size: 12)).foregroundStyle(LX.C.primary)
                    }
                }
                .frame(width: 14, height: 14)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(spec?.name ?? "No image model").font(LX.F.ui(13, .semibold)).foregroundStyle(LX.C.primary)
                    Text(subtitle).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                }
                .lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 6).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous).fill(Color.white.opacity(open ? 0.06 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .padding(.leading, -6)
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help("Choose image model")
    }

    private var subtitle: String {
        guard let spec else { return "Download one in Models" }
        if studio.phase == .loadingModel { return "Loading…" }
        let p = ImagePreferences.params(for: spec)
        var parts = [spec.style, "\(p.width)×\(p.height)"]
        if studio.loadedModelID != spec.id.description { parts.append("not loaded") }
        return parts.joined(separator: " · ")
    }
}

/// Floating list of installed image models (window corner radius, like Chat's panel).
struct ImageModelPanel: View {
    @Binding var open: Bool
    let selected: ImageModelSpec?
    @EnvironmentObject var state: AppState
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("IMAGE MODELS").font(LX.F.ui(9.5, .semibold)).kerning(0.8).foregroundStyle(LX.C.tertiary)
                .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)
            ForEach(library.imageModels) { m in
                let spec = ImageModelSpec.spec(for: m.id)
                let active = spec.id == selected?.id
                PanelRow(selected: active) {
                    ImagePreferences.select(m.id)
                    withAnimation(LX.M.mini) { open = false }
                } content: {
                    HStack(spacing: 9) {
                        Image(systemName: active ? "checkmark" : "paintpalette")
                            .font(.system(size: active ? 11 : 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? LX.C.accentText : LX.C.tertiary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.name).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                            Text("\(spec.style) · \(ModelDisplay.bytes(m.diskBytes))").font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if studio.loadedModelID == spec.id.description {
                            Text("Loaded").font(LX.F.ui(10.5, .semibold)).foregroundStyle(LX.C.onGlass)
                                .padding(.horizontal, 7).frame(height: 19)
                                .accentGlass(radius: LX.R.xs, strength: 0.8)
                        }
                    }
                    .padding(.horizontal, 9).frame(height: 42)
                }
            }
            if library.imageModels.isEmpty {
                Text("No image models yet.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).padding(.horizontal, 10).frame(height: 32)
            }
            Rectangle().fill(LX.C.divider).frame(height: 1).padding(.vertical, 3)
            if studio.loadedModelID != nil {
                PanelRow {
                    Task { await studio.unloadModel() }
                    withAnimation(LX.M.mini) { open = false }
                } content: {
                    Label("Unload from Memory", systemImage: "eject").font(LX.F.ui(12)).foregroundStyle(LX.C.body)
                        .padding(.horizontal, 10).frame(height: 30)
                }
                .disabled(studio.isBusy)
            }
            PanelRow {
                state.modelsKind = .image
                state.modelsTab = library.imageModels.isEmpty ? .discover : .installed
                state.screen = .models
                withAnimation(LX.M.mini) { open = false }
            } content: {
                Label("Manage Models", systemImage: "shippingbox").font(LX.F.ui(12)).foregroundStyle(LX.C.body)
                    .padding(.horizontal, 10).frame(height: 30)
            }
        }
        .padding(5)
        .frame(width: 300)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blending: .withinWindow)
                LX.C.overlay.opacity(0.75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).strokeBorder(LX.C.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 18)
        .background { Button("") { withAnimation(LX.M.mini) { open = false } }.keyboardShortcut(.escape, modifiers: []).opacity(0) }
    }
}

/// Full-width hoverable row for floating panels.
struct PanelRow<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
                    .fill(selected ? LX.C.accent.opacity(hover ? 0.16 : 0.12) : Color.white.opacity(hover ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

/// Shown when no image model is installed: points to Models (downloads live there).
struct NoImageModelCard: View {
    @EnvironmentObject var state: AppState
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let pick = ImageModelSpec.dreamShaperTurbo
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IMAGE · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                Text("Paint on this Mac").font(LX.F.display).kerning(-0.4)
                Text("Download an image model once in Models. After that, images are generated entirely on this Mac — offline, no account, nothing uploaded.")
                    .font(LX.F.body).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if case .active(let p)? = library.downloads[pick.id] {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction).tint(LX.C.accent)
                    Text("Downloading \(pick.name) · \(ModelDisplay.bytes(p.receivedBytes)) of \(ModelDisplay.bytes(p.totalBytes))")
                        .font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    LXButton(title: "Download \(pick.name) (\(ModelDisplay.bytes(pick.downloadBytes)))", symbol: "arrow.down.circle", kind: .primary) {
                        library.download(pick.id)
                    }
                    LXButton(title: "Browse image models") {
                        state.modelsKind = .image
                        state.modelsTab = .discover
                        state.screen = .models
                    }
                }
            }
        }
        .frame(width: 540)
    }
}

// MARK: - Composer

struct ImageComposer: View {
    let spec: ImageModelSpec
    @AppStorage(ImagePreferences.countKey) private var count = 1
    @State private var params: ImagePreferences.Params
    @State private var showNegative = false
    @State private var showLoRAs = false
    @FocusState private var focused: Bool
    private var studio: ImageStudio { AppServices.shared.images }

    init(spec: ImageModelSpec) {
        self.spec = spec
        _params = State(initialValue: ImagePreferences.params(for: spec))
    }

    var body: some View {
        @Bindable var studio = studio
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                promptBox
                negativeSection
                setting("Size", params.size.aspect) {
                    Menu {
                        ForEach(spec.sizes) { size in
                            Button {
                                params.width = size.width; params.height = size.height
                            } label: {
                                Text("\(size.label) · \(size.aspect)\(size == spec.defaultSize ? " (recommended)" : "")")
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            AspectGlyph(size: params.size)
                            Text(params.size.label).font(LX.F.mono(12)).foregroundStyle(LX.C.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                        }
                        .padding(.horizontal, 10).frame(height: LX.S.control)
                        .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                }
                setting("Steps", "\(params.steps)") {
                    CompactSlider(value: Binding(get: { Double(params.steps) }, set: { params.steps = Int($0.rounded()) }),
                                  range: Double(spec.stepRange.lowerBound)...Double(spec.stepRange.upperBound),
                                  marker: Double(spec.defaultSteps))
                }
                setting("Guidance (CFG)", params.cfg <= 1 ? "Off" : String(format: "%.1f", params.cfg)) {
                    CompactSlider(value: Binding(get: { params.cfg }, set: { params.cfg = ($0 * 2).rounded() / 2 }),
                                  range: spec.cfgRange, marker: spec.defaultCFG)
                }
                setting("Images", count > 1 ? "seed, seed+1, …" : "") {
                    Segmented(options: [(1, "1"), (2, "2"), (4, "4")], selection: $count, mono: true)
                }
                setting("Seed", "same seed = same image") {
                    HStack(spacing: 6) {
                        LXField(placeholder: "Random", text: $studio.draftSeed, mono: true)
                        IconButton(symbol: "dice", help: "Pick a seed") { studio.draftSeed = String(ImageRequest.randomSeed()) }
                    }
                }
                loraSection
                if params != .defaults(spec) {
                    Button("Reset to \(spec.name) defaults") { params = .defaults(spec) }
                        .buttonStyle(.plain).font(LX.F.caption).foregroundStyle(LX.C.accentText)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { generateBar }
        .onAppear { focused = true }
        .onChange(of: params) { _, p in ImagePreferences.setParams(p, for: spec) }
        .onChange(of: studio.activeLoRAs) { _, l in ImagePreferences.activeLoRAs = l }
    }

    private var promptBox: some View {
        @Bindable var studio = studio
        return VStack(spacing: 0) {
            TextField("A cozy reading nook with a sleeping cat, warm light, watercolor", text: $studio.draftPrompt, axis: .vertical)
                .textFieldStyle(.plain).font(LX.F.bodyLarge).lineLimit(4...10)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    studio.draftPrompt += "\n"
                    return .handled
                }
                .onSubmit { generate() }
                .padding(12)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: LX.R.xl).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: LX.R.xl).fill(Color(hex: 0x080910, alpha: 0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.xl))
        .overlay(RoundedRectangle(cornerRadius: LX.R.xl).strokeBorder(Color.white.opacity(focused ? 0.16 : 0.09), lineWidth: 1))
        .overlay { if studio.isBusy { GlowingBorder(radius: LX.R.xl).transition(.opacity) } }
        .animation(.easeInOut(duration: 0.3), value: studio.isBusy)
    }

    private var negativeSection: some View {
        @Bindable var studio = studio
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(title: "Negative prompt", open: $showNegative,
                             badge: studio.draftNegative.isEmpty ? nil : (params.cfg > 1 ? "on" : "needs CFG > 1"))
            if showNegative {
                TextField("blurry, low quality, extra fingers, watermark", text: $studio.draftNegative, axis: .vertical)
                    .textFieldStyle(.plain).font(LX.F.body).lineLimit(2...5)
                    .padding(10)
                    .well(radius: LX.R.lg, fill: Color.black.opacity(0.28))
                if params.cfg <= 1 {
                    Text("Used only when Guidance (CFG) is above 1.").font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                }
            }
        }
    }

    private var loraSection: some View {
        @Bindable var studio = studio
        let active = studio.activeLoRAs.filter { $0.scale != 0 }.count
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(title: "LoRA", open: $showLoRAs, badge: active > 0 ? "\(active) on" : nil)
            if showLoRAs {
                ForEach(studio.loraLibrary) { info in
                    LoRARow(info: info)
                }
                if studio.loraLibrary.isEmpty {
                    Text("Add SDXL LoRA files (.safetensors) to change the style or teach a subject.")
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    LXButton(title: "Add LoRA…", symbol: "plus") { addLoRA() }
                    if let folder = studio.loraFolder {
                        IconButton(symbol: "folder", help: "Show the LoRA folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
        }
    }

    private var generateBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if studio.isBusy {
                LiveStatusText(text: statusText, font: LX.F.mono(11))
            }
            if let error = studio.error {
                Text(error).font(LX.F.caption).foregroundStyle(LX.C.error).fixedSize(horizontal: false, vertical: true)
            }
            if studio.isBusy {
                LXButton(title: "Stop", symbol: "stop.fill", kind: .danger) { studio.stop() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(maxWidth: .infinity)
            } else {
                Button(action: generate) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                        Text(count > 1 ? "Generate \(count) images" : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LXButtonStyle(kind: .primary, height: 34))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(studio.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(LX.C.divider).frame(height: 1) }
    }

    private var statusText: String {
        switch studio.phase {
        case .idle: ""
        case .freeingMemory: "Making room in memory…"
        case .loadingModel: studio.activeLoRAs.contains(where: { $0.scale != 0 }) ? "Loading \(spec.name) + LoRA…" : "Loading \(spec.name)…"
        case .waiting: "Waiting for the GPU…"
        case .generating(let i, let n, let step, let total):
            (n > 1 ? "Image \(i + 1) of \(n) · " : "") + (step == 0 ? "Reading the prompt…" : "Painting · step \(step) of \(total)")
        }
    }

    private func setting<C: View>(_ title: String, _ value: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.secondary)
                Spacer()
                Text(value).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
            }
            content()
        }
    }

    private func addLoRA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose SDXL LoRA files (.safetensors). They are copied into Lay X."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { studio.importLoRA(url) }
        showLoRAs = true
    }

    private func generate() {
        let seed = UInt64(studio.draftSeed.trimmingCharacters(in: .whitespaces)) ?? ImageRequest.randomSeed()
        studio.generate(ImageRequest(prompt: studio.draftPrompt, negativePrompt: studio.draftNegative, steps: params.steps,
                                     cfg: params.cfg, seed: seed, count: count, size: params.size,
                                     loras: studio.activeLoRAs.filter { $0.scale != 0 }), spec: spec)
    }
}

/// Small rectangle showing the aspect ratio.
struct AspectGlyph: View {
    let size: ImageSize
    var body: some View {
        let w = size.width >= size.height ? 16.0 : 16.0 * Double(size.width) / Double(size.height)
        let h = size.height >= size.width ? 16.0 : 16.0 * Double(size.height) / Double(size.width)
        RoundedRectangle(cornerRadius: 2).strokeBorder(LX.C.accentText, lineWidth: 1.2)
            .frame(width: w, height: h).frame(width: 18, height: 18)
    }
}

/// "▸ Title  badge" toggle for collapsible sections.
struct DisclosureHeader: View {
    let title: String
    @Binding var open: Bool
    var badge: String?

    var body: some View {
        Button { withAnimation(LX.M.hover) { open.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(LX.F.ui(12.5, .semibold))
                if let badge {
                    Text(badge).font(LX.F.mono(10)).foregroundStyle(LX.C.accentText)
                        .padding(.horizontal, 6).frame(height: 17)
                        .background(Capsule().fill(LX.C.accent.opacity(0.14)))
                }
                Spacer()
            }
            .foregroundStyle(LX.C.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Slider sized for the composer: gradient track, knob, faint marker at the model's recommended value.
struct CompactSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var marker: Double?

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let pct = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                Capsule().fill(LX.C.liveGradient).frame(width: max(4, geo.size.width * pct), height: 4)
                if let marker {
                    Circle().fill(Color.white.opacity(0.35)).frame(width: 4, height: 4)
                        .offset(x: geo.size.width * (marker - range.lowerBound) / span - 2)
                }
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: geo.size.width * pct - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = min(max(0, g.location.x / geo.size.width), 1)
                value = range.lowerBound + p * span
            })
        }
        .frame(height: 18)
        .padding(.horizontal, 7)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
        }
    }
}

/// One LoRA: on/off, strength, fit warning, trigger words.
struct LoRARow: View {
    let info: LoRALibrary.Info
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        let index = studio.activeLoRAs.firstIndex { $0.file == info.file }
        let on = index != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Checkbox(isOn: Binding(get: { on }, set: { new in
                    if new { studio.activeLoRAs.append(LoRAChoice(file: info.file, scale: 1)) }
                    else { studio.activeLoRAs.removeAll { $0.file == info.file } }
                }))
                Text(info.name).font(LX.F.ui(12.5, .medium)).foregroundStyle(LX.C.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if case .otherBase(let base) = info.fit {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(LX.C.warn)
                        .help("Made for \(base) — it won’t apply to SDXL models")
                }
                Menu {
                    Button("Delete LoRA", role: .destructive) { studio.deleteLoRA(info.file) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if let index {
                HStack(spacing: 8) {
                    CompactSlider(value: Binding(get: { studio.activeLoRAs[index].scale },
                                                 set: { studio.activeLoRAs[index].scale = ($0 * 20).rounded() / 20 }),
                                  range: 0...1.5, marker: 1)
                    Text(String(format: "%.2f", studio.activeLoRAs[index].scale)).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                if !info.triggerWords.isEmpty {
                    Text("Trigger: \(info.triggerWords.joined(separator: ", "))").font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .padding(10)
        .well(radius: LX.R.lg, fill: Color.black.opacity(0.2))
    }
}

// MARK: - Canvas

struct ImageCanvas: View {
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let record = studio.selected, let url = studio.url(for: record) {
                    FileImage(url: url, cornerRadius: LX.R.xl)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                        .opacity(studio.isBusy ? 0.35 : 1)
                        .blur(radius: studio.isBusy ? 6 : 0)
                        .padding(28)
                        .id(record.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if !studio.isBusy {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(LX.C.accentText)
                        Text("Describe an image and press Generate").font(LX.F.body).foregroundStyle(LX.C.tertiary)
                    }
                }
                if studio.isBusy { PaintingProgress(phase: studio.phase) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.35), value: studio.selected?.id)
            .animation(.easeInOut(duration: 0.3), value: studio.isBusy)

            if let record = studio.selected {
                Rectangle().fill(LX.C.divider).frame(height: 1)
                ImageDetailBar(record: record)
            }
        }
    }
}

/// Glowing ring with the step count while painting.
struct PaintingProgress: View {
    let phase: ImageStudio.Phase

    var body: some View {
        let fraction: Double = {
            if case .generating(let i, let n, let step, let total) = phase, total > 0 {
                return (Double(i) + Double(step) / Double(total)) / Double(max(n, 1))
            }
            return 0
        }()
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(AngularGradient(colors: [LX.C.liveCyan, Color(hex: 0x9D8CFF), LX.C.liveCyan], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: LX.C.liveCyan.opacity(0.5), radius: 8)
                .animation(.easeOut(duration: 0.4), value: fraction)
            Image(systemName: "paintbrush.pointed").font(.system(size: 22, weight: .light)).foregroundStyle(LX.C.primary)
                .symbolEffect(.pulse, options: .repeating)
        }
        .frame(width: 84, height: 84)
    }
}

/// Prompt, numbers and actions for the selected image.
struct ImageDetailBar: View {
    let record: ImageRecord
    @State private var copied = false
    private var studio: ImageStudio { AppServices.shared.images }

    private var detailLine: String {
        var parts = [ImageModelSpec.spec(for: ModelRepoID(record.modelID) ?? ImageModelSpec.sdxlTurbo.id).name,
                     "\(record.width)×\(record.height)", "\(record.steps) step\(record.steps == 1 ? "" : "s")"]
        if record.cfg > 1 { parts.append(String(format: "CFG %.1f", record.cfg)) }
        parts.append("seed \(record.seed)")
        if !record.loras.isEmpty { parts.append(record.loras) }
        parts.append(String(format: "%.1f s", record.duration))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.prompt).font(LX.F.body).foregroundStyle(LX.C.body).lineLimit(2).textSelection(.enabled)
                Text(verbatim: detailLine)
                    .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", help: "Reuse prompt, negative prompt and seed") {
                    studio.draftPrompt = record.prompt
                    studio.draftNegative = record.negativePrompt
                    studio.draftSeed = String(record.seed)
                }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy image") {
                    ImageActions.copy(record)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                IconButton(symbol: "square.and.arrow.down", help: "Save as…") { ImageActions.saveAs(record) }
                IconButton(symbol: "magnifyingglass", help: "Show in Finder") { ImageActions.reveal(record) }
                IconButton(symbol: "trash", help: "Delete image") { studio.delete(record) }
            }
        }
        .padding(.horizontal, 16).frame(height: 64)
    }
}

enum ImageActions {
    static var studio: ImageStudio { AppServices.shared.images }

    static func copy(_ record: ImageRecord) {
        guard let url = studio.url(for: record), let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func saveAs(_ record: ImageRecord) {
        guard let url = studio.url(for: record) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName(record)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    static func reveal(_ record: ImageRecord) {
        guard let url = studio.url(for: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// First words of the prompt as a file name.
    static func suggestedName(_ record: ImageRecord) -> String {
        let words = record.prompt.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6)
        return (words.isEmpty ? "image" : words.joined(separator: "-").lowercased()) + "-\(record.seed).png"
    }
}

// MARK: - History

struct ImageHistoryGrid: View {
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "History", trailing: studio.history.isEmpty ? nil : "\(studio.history.count)")
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if studio.history.isEmpty {
                Text("Your images appear here. They’re saved on this Mac.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(studio.history) { record in
                            HistoryThumb(record: record, selected: record.id == studio.selected?.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct HistoryThumb: View {
    let record: ImageRecord
    let selected: Bool
    @State private var hover = false
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let url = studio.url(for: record) {
                FileImage(url: url, cornerRadius: LX.R.lg, thumbnail: true)
                    .aspectRatio(1, contentMode: .fit)
            }
            if hover {
                Button { withAnimation(LX.M.hover) { studio.delete(record) } } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain).padding(5)
                .help("Delete image")
                .transition(.opacity)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous)
            .strokeBorder(selected ? LX.C.accent.opacity(0.85) : Color.white.opacity(hover ? 0.2 : 0.06), lineWidth: selected ? 2 : 1))
        .scaleEffect(hover ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedID = record.id }
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help(record.prompt)
        .contextMenu {
            Button("Reuse Prompt and Seed") {
                studio.draftPrompt = record.prompt
                studio.draftSeed = String(record.seed)
            }
            Button("Copy Image") { ImageActions.copy(record) }
            Button("Save As…") { ImageActions.saveAs(record) }
            Button("Show in Finder") { ImageActions.reveal(record) }
            Divider()
            Button("Delete", role: .destructive) { studio.delete(record) }
        }
    }
}

/// Loads a PNG off the main thread (data only crosses threads) and shows it.
struct FileImage: View {
    let url: URL
    var cornerRadius: CGFloat = 8
    var thumbnail = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.white.opacity(0.04)).aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            let url = self.url
            let data = await Task.detached(priority: thumbnail ? .utility : .userInitiated) { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
