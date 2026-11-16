import AppKit
import SwiftUI
import LayXCore

/// Image generation: prompt + settings on the left, the canvas in the middle, history on the right.
/// Everything runs on this Mac; the model is downloaded once and then works offline.
struct ImageScreen: View {
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }
    private var spec: ImageModelSpec { ImagePreferences.spec }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Image").font(LX.F.title)
                ImageModelBadge(spec: spec)
            } trailing: {
                HStack(spacing: 6) {
                    if studio.isBusy {
                        BusyIndicator(help: "Generating")
                    }
                    if let folder = studio.imagesFolder {
                        IconButton(symbol: "folder", help: "Show the images folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    if library.imageModel(spec) != nil { ImageModelMenu(spec: spec) }
                }
            }
            if library.imageModel(spec) == nil {
                ImageModelDownloadCard(spec: spec)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ImageComposer(spec: spec).frame(width: 320)
                    Rectangle().fill(LX.C.divider).frame(width: 1)
                    ImageCanvas().frame(maxWidth: .infinity)
                    Rectangle().fill(LX.C.divider).frame(width: 1)
                    ImageHistoryGrid().frame(width: 236)
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
        .onAppear { library.refresh() }
    }
}

// MARK: - Header

struct ImageModelBadge: View {
    let spec: ImageModelSpec
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "paintpalette").font(.system(size: 11)).foregroundStyle(LX.C.primary)
            Text(spec.name).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.primary)
            Text(verbatim: "\(spec.resolution)×\(spec.resolution)\(studio.loadedModelID == spec.id.description ? " · loaded" : "")")
                .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
        }
        .padding(.leading, 6)
        .fixedSize()
    }
}

/// ⋯ menu: unload, show in Finder, delete.
struct ImageModelMenu: View {
    let spec: ImageModelSpec
    @State private var confirmDelete = false
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        Menu {
            Button("Unload from Memory") { Task { await studio.unloadModel() } }
                .disabled(studio.loadedModelID == nil || studio.isBusy)
            if let m = library.imageModel(spec) {
                Button("Show Model in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.directory]) }
            }
            Divider()
            Button("Delete Model…", role: .destructive) { confirmDelete = true }
                .disabled(studio.isBusy)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
        }
        .menuStyle(.button).buttonStyle(QuietButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("Image model")
        .confirmationDialog("Delete \(spec.name)?", isPresented: $confirmDelete) {
            Button("Delete \(ByteCountFormatter.string(fromByteCount: library.imageModel(spec)?.diskBytes ?? 0, countStyle: .file))",
                   role: .destructive) {
                Task {
                    await studio.unloadModel()
                    library.delete(spec.id, loadedID: nil)
                }
            }
        } message: {
            Text("The model files are removed from this Mac. Your generated images stay.")
        }
    }
}

// MARK: - Download

struct ImageModelDownloadCard: View {
    let spec: ImageModelSpec
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let state = library.downloads[spec.id]
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IMAGE · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                Text("Paint with \(spec.name)").font(LX.F.display).kerning(-0.4)
                Text("Download the model once (about \(ByteCountFormatter.string(fromByteCount: spec.downloadBytes, countStyle: .file))). After that, images are generated entirely on this Mac — offline, no account, nothing uploaded.")
                    .font(LX.F.body).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                fact("bolt", "\(spec.resolution)×\(spec.resolution) in 1–4 steps — usually a second or two")
                fact("memory", String(format: "Needs about %.0f GB of free memory while generating", Double(spec.runtimeBytes) / 1_073_741_824))
                fact("doc.text", "\(spec.publisher) · \(spec.license)")
            }
            switch state {
            case .active(let p)?:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p.fraction).tint(LX.C.accent)
                    HStack {
                        Text("\(p.phase.rawValue.capitalized) · \(ByteCountFormatter.string(fromByteCount: p.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))")
                            .font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                        Spacer()
                        LXButton(title: "Cancel", kind: .secondary) { library.cancelDownload(spec.id) }
                    }
                }
            default:
                HStack(spacing: 10) {
                    LXButton(title: "Download \(spec.name)", symbol: "arrow.down.circle", kind: .primary) { library.download(spec.id) }
                    Link("License", destination: spec.licenseURL).font(LX.F.ui(12)).foregroundStyle(LX.C.accentText)
                }
                if case .failed(let message)? = state {
                    Text(message).font(LX.F.caption).foregroundStyle(LX.C.error)
                }
            }
        }
        .frame(width: 520)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(LX.C.accentText).frame(width: 16)
            Text(text).font(LX.F.ui(12.5)).foregroundStyle(LX.C.body)
        }
    }
}

// MARK: - Composer

struct ImageComposer: View {
    let spec: ImageModelSpec
    @AppStorage(ImagePreferences.stepsKey) private var steps = 2
    @AppStorage(ImagePreferences.countKey) private var count = 1
    @FocusState private var focused: Bool
    private var studio: ImageStudio { AppServices.shared.images }

    var body: some View {
        @Bindable var studio = studio
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Prompt")
                VStack(spacing: 0) {
                    TextField("A cozy reading nook with a sleeping cat, warm light, watercolor", text: $studio.draftPrompt, axis: .vertical)
                        .textFieldStyle(.plain).font(LX.F.bodyLarge).lineLimit(5...10)
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

            setting("Steps", "More steps add detail; 1–2 is usually enough") {
                Segmented(options: spec.stepChoices.map { ($0, "\($0)") }, selection: $steps, mono: true)
            }
            setting("Images", "Each image uses the next seed") {
                Segmented(options: [(1, "1"), (2, "2"), (4, "4")], selection: $count, mono: true)
            }
            setting("Seed", "Same prompt + seed = same image") {
                HStack(spacing: 6) {
                    LXField(placeholder: "Random", text: $studio.draftSeed, mono: true).frame(width: 150)
                    IconButton(symbol: "dice", help: "Pick a seed") { studio.draftSeed = String(ImageRequest.randomSeed()) }
                }
            }

            Spacer(minLength: 0)

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
            Text("On this Mac · \(spec.name) · \(spec.license)")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private var statusText: String {
        switch studio.phase {
        case .idle: ""
        case .freeingMemory: "Making room in memory…"
        case .loadingModel: "Loading \(spec.name)…"
        case .waiting: "Waiting for the GPU…"
        case .generating(let i, let n, let step, let total):
            (n > 1 ? "Image \(i + 1) of \(n) · " : "") + (step == 0 ? "Reading the prompt…" : "Painting · step \(step) of \(total)")
        }
    }

    private func setting<C: View>(_ title: String, _ hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.secondary)
                Spacer()
                Text(hint).font(LX.F.caption).foregroundStyle(LX.C.tertiary).lineLimit(1)
            }
            content()
        }
    }

    private func generate() {
        let seed = UInt64(studio.draftSeed.trimmingCharacters(in: .whitespaces)) ?? ImageRequest.randomSeed()
        studio.generate(ImageRequest(prompt: studio.draftPrompt, steps: steps, seed: seed, count: count), spec: spec)
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

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.prompt).font(LX.F.body).foregroundStyle(LX.C.body).lineLimit(2).textSelection(.enabled)
                Text(verbatim: "seed \(record.seed) · \(record.steps) step\(record.steps == 1 ? "" : "s") · \(record.width)×\(record.height) · \(String(format: "%.1f s", record.duration))")
                    .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", help: "Reuse prompt and seed") {
                    studio.draftPrompt = record.prompt
                    studio.draftSeed = String(record.seed)
                    UserDefaults.standard.set(record.steps, forKey: ImagePreferences.stepsKey)
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
