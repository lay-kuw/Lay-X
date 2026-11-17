import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LayXCore

/// Image generation: prompt + settings on the left, the canvas in the middle, history on the right.
/// Everything runs on this Mac; models are downloaded once in Models and then work offline.
struct ImageScreen: View {
    @EnvironmentObject var state: AppState
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let spec = ImagePreferences.spec
        VStack(spacing: 0) {
            ScreenHeader {
                ImageModelPicker(open: $state.modelPanelOpen, spec: spec)
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
            } else if !studio.history.isEmpty {
                // No model chosen: a gallery of everything made so far.
                HStack(spacing: 0) {
                    ImageCanvas().frame(maxWidth: .infinity)
                    Rectangle().fill(LX.C.divider).frame(width: 1)
                    ImageHistoryGrid(columns: 3).frame(width: 420)
                }
            } else if !library.imageModels.isEmpty {
                ChooseImageModelCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoImageModelCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topLeading) {
            if state.modelPanelOpen {
                // Same placement as Chat's panel: under the header, aligned with the picker.
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).onTapGesture { withAnimation(LX.M.mini) { state.modelPanelOpen = false } }
                    ImageModelPanel(open: $state.modelPanelOpen, selected: spec)
                        .padding(.top, LX.S.header + 2).padding(.leading, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                }
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
                Text(spec?.name ?? (AppServices.shared.models.imageModels.isEmpty ? "No image model" : "No model selected")).font(LX.F.ui(13, .semibold)).foregroundStyle(LX.C.primary)
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
}

/// Floating list of image models — same look and placement as Chat's model panel.
struct ImageModelPanel: View {
    @Binding var open: Bool
    let selected: ImageModelSpec?
    @EnvironmentObject var state: AppState
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let loaded = library.imageModels.filter { $0.id.description == studio.loadedModelID }
        let available = library.imageModels.filter { $0.id.description != studio.loadedModelID }
        VStack(alignment: .leading, spacing: 0) {
            if studio.isBusy {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Generating — stop it to switch models").font(LX.F.ui(11.5)).foregroundStyle(LX.C.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 15).padding(.top, 9).padding(.bottom, 2)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !loaded.isEmpty {
                        header("Loaded")
                        ForEach(loaded) { row($0) }
                    }
                    if !available.isEmpty {
                        header("Available").padding(.top, loaded.isEmpty ? 0 : 8)
                        ForEach(available) { row($0) }
                    }
                    if library.imageModels.isEmpty {
                        Text("No image models installed yet.").font(LX.F.body).foregroundStyle(LX.C.tertiary).padding(12)
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            // No model switching while something is being generated.
            .disabled(studio.isBusy)
            .opacity(studio.isBusy ? 0.4 : 1)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            if selected != nil {
                PickerRowButton {
                    ImagePreferences.select(nil)
                    close()
                } content: {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(LX.C.secondary).frame(width: 18)
                        Text("Deselect Model").font(LX.F.ui(12.5, .medium)).foregroundStyle(LX.C.body)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                }
                .disabled(studio.isBusy)
                .padding(.horizontal, 4).padding(.top, 4)
            }
            if studio.loadedModelID != nil {
                PickerRowButton {
                    // Like Chat: after unloading, no model is shown as chosen.
                    ImagePreferences.select(nil)
                    Task { await studio.unloadModel() }
                    close()
                } content: {
                    HStack(spacing: 10) {
                        Image(systemName: "eject").font(.system(size: 12)).foregroundStyle(LX.C.secondary).frame(width: 18)
                        Text("Unload from Memory").font(LX.F.ui(12.5, .medium)).foregroundStyle(LX.C.body)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                }
                .disabled(studio.isBusy)
                .padding(.horizontal, 4).padding(.top, 4)
            }
            PickerRowButton {
                state.modelsKind = .image
                state.modelsTab = library.imageModels.isEmpty ? .discover : .installed
                state.screen = .models
                close()
            } content: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(LX.C.accentText).frame(width: 18)
                    Text("Manage Models").font(LX.F.ui(12.5, .medium)).foregroundStyle(LX.C.accentText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 32)
            }
            .padding(4)
        }
        .frame(width: 300)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).fill(LX.C.overlay.opacity(0.88))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).strokeBorder(LX.C.edge, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous)
            .strokeBorder(LinearGradient(colors: [LX.C.highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 18)
        .background { Button("") { close() }.keyboardShortcut(.escape, modifiers: []).opacity(0) }
    }

    private func close() { withAnimation(LX.M.mini) { open = false } }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).font(LX.F.ui(9.5, .semibold)).kerning(0.8).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)
    }

    private func row(_ m: InstalledModel) -> some View {
        let spec = ImageModelSpec.spec(for: m)
        let active = spec.id == selected?.id
        let loading = studio.phase == .loadingModel && active
        return PickerRowButton(selected: active) {
            ImagePreferences.select(m.id)
            close()
        } content: {
            HStack(spacing: 9) {
                Group {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: active ? "checkmark" : "paintpalette").font(.system(size: active ? 11 : 13, weight: active ? .semibold : .regular)) }
                }
                .foregroundStyle(active ? LX.C.accentText : LX.C.tertiary)
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.name).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                    Text("\(spec.style) · \(ModelDisplay.bytes(m.diskBytes))").font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if active {
                    Text("Active").font(LX.F.ui(10.5, .semibold)).foregroundStyle(LX.C.onGlass)
                        .padding(.horizontal, 7).frame(height: 19)
                        .accentGlass(radius: LX.R.xs, strength: 0.8)
                }
            }
            .padding(.horizontal, 9).frame(height: 42)
        }
    }
}

/// Shown until an image model is chosen this session: the installed models, one click each.
struct ChooseImageModelCard: View {
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IMAGE · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                Text("Choose a model").font(LX.F.display).kerning(-0.4)
                Text("It loads when you generate the first image.")
                    .font(LX.F.body).foregroundStyle(LX.C.secondary)
            }
            VStack(spacing: 2) {
                ForEach(library.imageModels) { m in
                    let spec = ImageModelSpec.spec(for: m)
                    PickerRowButton {
                        ImagePreferences.select(m.id)
                    } content: {
                        HStack(spacing: 10) {
                            Image(systemName: "paintpalette").font(.system(size: 13)).foregroundStyle(LX.C.tertiary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(spec.name).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                                Text("\(spec.style) · \(ModelDisplay.bytes(m.diskBytes))").font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                        }
                        .padding(.horizontal, 10).frame(height: 44)
                    }
                }
            }
            .padding(5)
            .well(radius: LX.R.lg, fill: Color.black.opacity(0.2))
        }
        .frame(width: 420)
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
    /// "sequential" (seed, seed+1, …) or "random" (a new seed per image).
    @AppStorage(ImagePreferences.seedModeKey) private var seedMode = "sequential"
    @State private var params: ImagePreferences.Params
    @State private var showNegative = false
    @State private var showLoRAs = false
    @State private var showSource = false
    @State private var dropTargeted = false
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
                if spec.usesGuidance { negativeSection }
                if spec.family.sourceMode != .none { sourceSection }
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
                if spec.usesGuidance {
                    setting("Guidance (CFG)", params.cfg <= 1 ? "Off" : String(format: "%.1f", params.cfg)) {
                        CompactSlider(value: Binding(get: { params.cfg }, set: { params.cfg = ($0 * 2).rounded() / 2 }),
                                      range: spec.cfgRange, marker: spec.defaultCFG)
                    }
                }
                setting("Images", "") {
                    HStack(spacing: 6) {
                        Segmented(options: [1, 2, 4, 8, 16, 32].map { ($0, "\($0)") }, selection: $count, mono: true, compact: true)
                        LXField(placeholder: "#", text: Binding(
                            get: { [1, 2, 4, 8, 16, 32].contains(count) ? "" : String(count) },
                            set: { text in
                                let digits = text.filter(\.isNumber)
                                if let n = Int(digits.prefix(3)), n > 0 { count = min(n, ImageStudio.maxCount) }
                            }), mono: true)
                            .frame(width: 52)
                            .help("Any number up to \(ImageStudio.maxCount)")
                    }
                }

                // One place for seeds: the first image's seed, and (for several images) how the others follow.
                setting("Seed", count > 1 ? (seedMode == "random" ? "first image · others random" : "first image · then +1 each")
                                          : "same seed = same image") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            LXField(placeholder: "Random", text: $studio.draftSeed, mono: true)
                            IconButton(symbol: "dice", help: "Pick a seed") { studio.draftSeed = String(ImageRequest.randomSeed()) }
                        }
                        if count > 1 {
                            Segmented(options: [("sequential", "Sequential"), ("random", "Random")], selection: $seedMode, compact: true)
                        }
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

    /// Image to image: a source picture (drop, choose, or "Use as source" from the history) + strength (SDXL), or a
    /// reference picture the model edits / varies (FLUX.2 klein).
    private var sourceSection: some View {
        @Bindable var studio = studio
        let reference = spec.family.sourceMode == .reference
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(title: "Image to image", open: $showSource,
                             badge: studio.sourceImage == nil ? nil : reference ? "reference" : String(format: "on · %.0f%%", studio.strength * 100))
            if showSource || studio.sourceImage != nil {
                if let data = studio.sourceImage, let image = NSImage(data: data) {
                    HStack(spacing: 10) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: LX.R.md, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(studio.sourceLabel).font(LX.F.ui(12, .medium)).foregroundStyle(LX.C.primary).lineLimit(1)
                            Text("\(Int(image.size.width)) × \(Int(image.size.height))\(reference ? " · reference" : " → cropped to \(params.size.label)")")
                                .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        IconButton(symbol: "xmark", help: "Remove the source image") {
                            withAnimation(LX.M.hover) { studio.sourceImage = nil }
                        }
                    }
                    if reference {
                        Text("\(spec.name) redraws this picture as the prompt says — e.g. “make it night”, “as a watercolor”, “the cat wearing a hat”.")
                            .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        setting("Strength", String(format: "%.0f%% repainted", studio.strength * 100)) {
                            CompactSlider(value: Binding(get: { studio.strength }, set: { studio.strength = ($0 * 20).rounded() / 20 }),
                                          range: 0.1...1, marker: 0.6)
                        }
                        Text("Low keeps the picture, high follows the prompt. \(max(1, Int(Double(params.steps) * studio.strength))) of \(params.steps) steps run.")
                            .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button(action: chooseSource) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 18, weight: .light))
                            Text("Drop an image or click to choose").font(LX.F.ui(12))
                        }
                        .foregroundStyle(dropTargeted ? LX.C.accentText : LX.C.tertiary)
                        .frame(maxWidth: .infinity).frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(dropTargeted ? LX.C.accent : Color.white.opacity(0.16)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        setSource(data, label: url.lastPathComponent)
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let bytes = try? Data(contentsOf: url) else { return }
                let name = url.lastPathComponent
                Task { @MainActor in setSource(bytes, label: name) }
            }
        } else {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else { return }
                Task { @MainActor in setSource(data, label: "Dropped image") }
            }
        }
    }

    /// Sets the source and picks the model size closest to its aspect ratio.
    private func setSource(_ data: Data, label: String) {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            studio.clearMessages()
            return
        }
        studio.sourceImage = data
        studio.sourceLabel = label
        showSource = true
        let aspect = image.size.width / image.size.height
        if let best = spec.sizes.filter({ $0.megapixels >= spec.defaultSize.megapixels * 0.8 })
            .min(by: { abs(Double($0.width) / Double($0.height) - aspect) < abs(Double($1.width) / Double($1.height) - aspect) }) {
            params.width = best.width; params.height = best.height
        }
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
        let family = spec.family
        let usable = Set(studio.loraLibrary.filter { ImageStudio.lora($0, fits: family) }.map(\.file))
        let active = studio.activeLoRAs.filter { $0.scale != 0 && usable.contains($0.file) }.count
        // Matching LoRAs first; the others stay listed (greyed) so switching models doesn't hide them.
        let ordered = studio.loraLibrary.filter { usable.contains($0.file) } + studio.loraLibrary.filter { !usable.contains($0.file) }
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(title: "LoRA", open: $showLoRAs, badge: active > 0 ? "\(active) on" : nil)
            if showLoRAs {
                ForEach(ordered) { info in
                    LoRARow(info: info, family: family, usable: usable.contains(info.file),
                            full: active >= family.maxLoRAs)
                }
                if studio.loraLibrary.isEmpty {
                    Text("Add \(family.loraBase.displayName) LoRA files (.safetensors) to change the style or teach a subject.")
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                } else if usable.isEmpty {
                    Text("None of these LoRAs are for \(family.loraBase.displayName).")
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                } else if family.maxLoRAs < 8 {
                    Text("Up to \(family.maxLoRAs) at once · switching them doesn’t reload the model.")
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
                Button { studio.stop() } label: { PaintButtonLabel(stop: true, title: "Stop", detail: nil) }
                    .buttonStyle(PaintButtonStyle(stop: true))
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button(action: generate) {
                    PaintButtonLabel(stop: false, title: "Generate", detail: count > 1 ? "\(count) images" : nil)
                }
                .buttonStyle(PaintButtonStyle(stop: false))
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
        panel.message = "Choose LoRA files (.safetensors) for SDXL, FLUX.2 klein 4B or Qwen-Image. They are copied into Lay X."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { studio.importLoRA(url) }
        showLoRAs = true
    }

    private func generate() {
        let seed = UInt64(studio.draftSeed.trimmingCharacters(in: .whitespaces)) ?? ImageRequest.randomSeed()
        var request = ImageRequest(prompt: studio.draftPrompt, negativePrompt: studio.draftNegative, steps: params.steps,
                                   cfg: params.cfg, seed: seed, count: count, size: params.size,
                                   loras: studio.activeLoRAs.filter { $0.scale != 0 },
                                   source: studio.sourceImage, strength: studio.strength)
        if count > 1, seedMode == "random" { request.seeds = ImageRequest.randomSeeds(first: seed, count: count) }
        studio.generate(request, spec: spec)
    }
}

/// Generate / Stop: accent glass (no solid fill) with the app's cyan→violet light on the icon and rim.
struct PaintButtonLabel: View {
    let stop: Bool
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: stop ? "stop.fill" : "sparkles")
                .font(.system(size: stop ? 10 : 13, weight: .semibold))
                .foregroundStyle(stop ? AnyShapeStyle(LX.C.error) : AnyShapeStyle(LX.C.liveGradient))
            Text(title).font(LX.F.ui(13, .semibold)).foregroundStyle(LX.C.onGlass)
            if let detail {
                Text(detail).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PaintButtonStyle: ButtonStyle {
    let stop: Bool

    func makeBody(configuration: Configuration) -> some View {
        PaintButtonBody(configuration: configuration, stop: stop)
    }

    private struct PaintButtonBody: View {
        let configuration: Configuration
        let stop: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous)
            let lit = enabled && (hover || configuration.isPressed)
            configuration.label
                .frame(height: 38)
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if stop {
                            shape.fill(LX.C.error.opacity(lit ? 0.14 : 0.09))
                        } else {
                            shape.fill(LinearGradient(colors: [LX.C.liveCyan.opacity(lit ? 0.22 : 0.14),
                                                               LX.C.liveViolet.opacity(lit ? 0.30 : 0.20)],
                                                      startPoint: .leading, endPoint: .trailing))
                        }
                    }
                }
                .clipShape(shape)
                .overlay {
                    if stop {
                        shape.strokeBorder(LX.C.error.opacity(lit ? 0.5 : 0.3), lineWidth: 1)
                    } else {
                        shape.strokeBorder(LX.C.liveGradient, lineWidth: 1).opacity(enabled ? (lit ? 0.9 : 0.55) : 0.25)
                    }
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [LX.C.highlight, .clear], startPoint: .top,
                                                           endPoint: UnitPoint(x: 0.5, y: 0.5)), lineWidth: 1))
                .shadow(color: (stop ? LX.C.error : LX.C.liveViolet).opacity(lit ? 0.28 : 0), radius: 14, y: 4)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .contentShape(shape)
                .onHover { h in withAnimation(LX.M.hover) { hover = h } }
                .animation(LX.M.hover, value: configuration.isPressed)
        }
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
    let family: ImageFamily
    /// Made for the current model's base.
    let usable: Bool
    /// The model's LoRA limit is reached (unchecked rows can't be switched on).
    let full: Bool
    private var studio: ImageStudio { AppServices.shared.images }

    private var baseLabel: String? {
        switch info.fit {
        case .fits(let base): base.displayName
        case .otherBase(let base): base
        case .fullModel: "full model"
        case .unknown: nil
        }
    }

    var body: some View {
        let index = usable ? studio.activeLoRAs.firstIndex { $0.file == info.file } : nil
        let on = index != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let file = info.file
                Checkbox(isOn: Binding(get: { studio.activeLoRAs.contains { $0.file == file } }, set: { new in
                    if new { if !studio.activeLoRAs.contains(where: { $0.file == file }) { studio.activeLoRAs.append(LoRAChoice(file: file, scale: 1)) } }
                    else { studio.activeLoRAs.removeAll { $0.file == file } }
                }))
                .disabled(!usable || (!on && full))
                Text(info.name).font(LX.F.ui(12.5, .medium)).foregroundStyle(usable ? LX.C.primary : LX.C.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let baseLabel {
                    Text(baseLabel).font(LX.F.mono(9.5)).foregroundStyle(usable ? LX.C.tertiary : LX.C.warn).lineLimit(1)
                        .help(info.fit == .fullModel ? "This is a whole model, not a LoRA — use “Import as Image Model” in the ⋯ menu"
                              : usable ? "Made for \(baseLabel)" : "Made for \(baseLabel) — it can’t be used with \(family.displayName) models")
                }
                Menu {
                    if info.fit == .fullModel, let url = studio.loraFolder?.appendingPathComponent(info.file) {
                        Button("Import as Image Model") {
                            Task {
                                // The converted model lives in Models; the misplaced file leaves the LoRA list.
                                if let id = await AppServices.shared.models.importCheckpoint(url) {
                                    studio.deleteLoRA(info.file)
                                    ImagePreferences.select(id)
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Delete LoRA", role: .destructive) { studio.deleteLoRA(info.file) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if let index {
                // Bindings look the LoRA up by file: an index captured here goes stale (and traps) when the
                // checkbox removes the entry while the slider is still on screen.
                let file = info.file
                HStack(spacing: 8) {
                    CompactSlider(value: Binding(get: { studio.activeLoRAs.first { $0.file == file }?.scale ?? 0 },
                                                 set: { v in
                                                     guard let i = studio.activeLoRAs.firstIndex(where: { $0.file == file }) else { return }
                                                     studio.activeLoRAs[i].scale = (v * 20).rounded() / 20
                                                 }),
                                  range: family.loraScaleRange, marker: 1)
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
        .opacity(usable ? 1 : 0.6)
    }
}

// MARK: - Canvas

struct ImageCanvas: View {
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                let painting = studio.isBusy && studio.watchingProgress
                if let record = studio.selected, let url = studio.url(for: record) {
                    FileImage(url: url, cornerRadius: LX.R.xl)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                        .opacity(painting ? 0.35 : 1)
                        .blur(radius: painting ? 6 : 0)
                        .padding(28)
                        .id(record.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if !studio.isBusy {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(LX.C.accentText)
                        Text("Describe an image and press Generate").font(LX.F.body).foregroundStyle(LX.C.tertiary)
                    }
                }
                if painting { PaintingProgress(phase: studio.phase) }
            }
            .overlay(alignment: .bottom) {
                // Generating in the background while a history image is shown.
                if studio.isBusy && !studio.watchingProgress {
                    Button { withAnimation(LX.M.hover) { studio.watchProgress() } } label: {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(ImageRunText.status(studio)).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .help("Show the image being generated")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.35), value: studio.selected?.id)
            .animation(.easeInOut(duration: 0.3), value: studio.isBusy)
            .animation(.easeInOut(duration: 0.3), value: studio.watchingProgress)

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
        let modelID = ModelRepoID(record.modelID) ?? ImageModelSpec.sdxlTurbo.id
        let spec = AppServices.shared.models.imageModels.first { $0.id == modelID }.map(ImageModelSpec.spec(for:))
            ?? ImageModelSpec.spec(for: modelID)
        var parts = [spec.name,
                     "\(record.width)×\(record.height)", "\(record.steps) step\(record.steps == 1 ? "" : "s")"]
        if record.cfg > 1 { parts.append(String(format: "CFG %.1f", record.cfg)) }
        parts.append("seed \(record.seed)")
        if !record.loras.isEmpty { parts.append(record.loras) }
        if record.strength > 0 {
            parts.append(spec.family.sourceMode == .reference ? "from a reference" : String(format: "img2img %.0f%%", record.strength * 100))
        }
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
                IconButton(symbol: "photo.on.rectangle", help: "Use as the source for image to image") {
                    studio.useAsSource(record)
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
    var columns = 2
    @FocusState private var focused: Bool
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "History", trailing: studio.history.isEmpty ? nil : "\(studio.history.count)")
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if studio.history.isEmpty && !studio.isBusy {
                Text("Your images appear here. They’re saved on this Mac.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                            if studio.isBusy {
                                ForEach(0..<max(1, studio.runCount - studio.runDone), id: \.self) { slot in
                                    PendingThumb(first: slot == 0)
                                }
                            }
                            ForEach(studio.history) { record in
                                HistoryThumb(record: record, selected: record.id == studio.selected?.id && !(studio.isBusy && studio.watchingProgress)) { focused = true }
                                    .id(record.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    // Arrow keys move the selection (← → by one, ↑ ↓ by a row) once the grid has focus.
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                        let step: Int = switch press.key {
                        case .leftArrow: -1
                        case .rightArrow: 1
                        case .upArrow: -columns
                        default: columns
                        }
                        move(by: step, proxy: proxy)
                        return .handled
                    }
                }
            }
        }
    }

    private func move(by step: Int, proxy: ScrollViewProxy) {
        let items = studio.history
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == studio.selected?.id } ?? 0
        let next = min(max(current + step, 0), items.count - 1)
        guard next != current || studio.selectedID == nil else { return }
        studio.select(items[next].id)
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[next].id) }
    }
}

/// Status line of the running batch.
enum ImageRunText {
    @MainActor static func status(_ studio: ImageStudio) -> String {
        let batch = studio.runCount > 1 ? "Image \(min(studio.runDone + 1, studio.runCount)) of \(studio.runCount) · " : ""
        switch studio.phase {
        case .generating(_, _, let step, let total): return batch + (step == 0 ? "reading the prompt" : "step \(step) of \(total)")
        case .loadingModel: return "Loading the model…"
        case .freeingMemory: return "Making room in memory…"
        case .waiting: return "Waiting for the GPU…"
        case .idle: return ""
        }
    }
}

/// A slot in the history for an image still being made: the first shows live progress, the rest are queued.
struct PendingThumb: View {
    let first: Bool
    @State private var shimmer = false
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        let watching = studio.watchingProgress
        let fraction: Double = {
            if first, case .generating(_, _, let step, let total) = studio.phase, total > 0 { return Double(step) / Double(total) }
            return 0
        }()
        Color.black.opacity(0.25)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LinearGradient(colors: [LX.C.liveCyan.opacity(0.0), LX.C.liveViolet.opacity(first ? 0.22 : 0.08), LX.C.liveCyan.opacity(0.0)],
                               startPoint: shimmer ? .bottomTrailing : .topLeading, endPoint: shimmer ? .topLeading : .bottomTrailing)
            }
            .overlay {
                VStack(spacing: 6) {
                    if first {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.5)
                            Circle().trim(from: 0, to: max(0.02, fraction))
                                .stroke(LX.C.liveGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 26, height: 26)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                        Text(fraction > 0 ? "\(Int(fraction * 100))%" : "Starting")
                            .font(LX.F.mono(10)).foregroundStyle(LX.C.secondary)
                    } else {
                        Image(systemName: "hourglass").font(.system(size: 12)).foregroundStyle(LX.C.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous)
                .strokeBorder(first && watching ? AnyShapeStyle(LX.C.liveGradient) : AnyShapeStyle(Color.white.opacity(0.08)),
                              lineWidth: first && watching ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(LX.M.hover) { studio.watchProgress() } }
            .help(first ? "Generating — click to watch" : "Queued")
            .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { shimmer = true } }
    }
}

struct HistoryThumb: View {
    let record: ImageRecord
    let selected: Bool
    /// Called on click (the grid takes keyboard focus).
    var onSelect: () -> Void = {}
    @State private var hover = false
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Square cell; the picture fills it (cropped) whatever its size or aspect.
            Color.black.opacity(0.25)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url = studio.url(for: record) {
                        FileImage(url: url, cornerRadius: 0, thumbnail: true, fill: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous))
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
        .onTapGesture { studio.select(record.id); onSelect() }
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help(record.prompt)
        .contextMenu {
            Button("Reuse Prompt and Seed") {
                studio.draftPrompt = record.prompt
                studio.draftSeed = String(record.seed)
            }
            Button("Use as Source Image") { studio.useAsSource(record) }
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
    /// Fill the frame (cropping) instead of fitting inside it.
    var fill = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if fill {
                    // A flexible frame the picture covers, so it never dictates the cell's size.
                    Color.clear.overlay {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            } else {
                Rectangle().fill(Color.white.opacity(0.04)).aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            let url = self.url
            let thumbnail = self.thumbnail
            let cg = await Task.detached(priority: thumbnail ? .utility : .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                guard thumbnail else { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
                // Decoded at thumbnail size (sharp at 2×, light on memory).
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 512,
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            }.value
            image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}
