import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LayXCore

/// Models → Image: installed image models and the curated catalog (downloads use the shared downloader).
struct ImageModelsPane: View {
    let tab: ModelsScreen.Tab
    let filter: String
    @EnvironmentObject var state: AppState
    @State private var selection: String?
    @State private var confirmDelete: InstalledModel?
    @State private var hubResults: [HubModelSummary] = []
    @State private var hubSort: HubAPI.Sort = .downloads
    @State private var hubNext: URL?
    @State private var hubLoading = false
    @State private var hubError: String?
    /// Architecture browsed on Hugging Face (nil = every supported one).
    @State private var hubFamily: ImageFamily? = nil
    /// Family of each Hub result (known from the pipeline filter that found it).
    @State private var hubFamilies: [ModelRepoID: ImageFamily] = [:]
    /// Curated models shown in Discover (nil = all).
    @State private var purpose: ImagePurpose? = nil
    @State private var confirmDeleteLoRA: LoRALibrary.Info?
    private var library: ModelLibrary { AppServices.shared.models }
    private var studio: ImageStudio { AppServices.shared.images }

    private var catalog: [ImageModelSpec] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return ImageModelSpec.catalog.filter { spec in
            (purpose.map { spec.purposes.contains($0) } ?? true)
                && (q.isEmpty || spec.name.localizedCaseInsensitiveContains(q) || spec.style.localizedCaseInsensitiveContains(q)
                    || spec.id.description.localizedCaseInsensitiveContains(q) || spec.family.displayName.localizedCaseInsensitiveContains(q))
        }
    }

    /// Installed models use their recorded family; Hub results the family whose filter found them.
    private func spec(_ id: ModelRepoID) -> ImageModelSpec {
        if let m = library.imageModels.first(where: { $0.id == id }) { return ImageModelSpec.spec(for: m) }
        return ImageModelSpec.spec(for: id, family: hubFamilies[id] ?? hubFamily ?? .sdxl)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == .installed { installed; importRow; loraSection } else { discover }
                    ForEach(library.activeDownloads.filter { d in ImageModelSpec.spec(d.id.description) != nil || hubResults.contains { $0.id == d.id } }, id: \.id) { d in
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(LX.C.liveCyan)
                                .symbolEffect(.pulse, options: .repeating)
                            Text(spec(d.id).name).font(LX.F.ui(12.5, .medium))
                            ProgressView(value: d.progress.fraction).tint(LX.C.accent)
                            Text("\(Int(d.progress.fraction * 100))%").font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                            IconButton(symbol: "xmark", help: "Cancel") { library.cancelDownload(d.id) }
                        }
                        .padding(.horizontal, 12).frame(height: 44).well()
                    }
                }
                .padding(16)
            }
            Rectangle().fill(LX.C.divider).frame(width: 1)
            details.frame(width: 320)
        }
        .onAppear {
            if selection == nil {
                selection = tab == .installed ? (ImagePreferences.spec?.id.description ?? library.imageModels.first?.id.description)
                                              : ImageModelSpec.catalog.first?.id.description
            }
        }
        .confirmationDialog("Delete \(confirmDelete.map { ImageModelSpec.spec(for: $0).name } ?? "model")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { m in
            Button("Delete \(ModelDisplay.bytes(m.diskBytes))", role: .destructive) {
                Task {
                    if studio.loadedModelID == m.id.description { await studio.unloadModel() }
                    library.delete(m.id, loadedID: nil)
                }
            }
        } message: { _ in
            Text("The model files are removed from this Mac. Your generated images stay.")
        }
    }

    // MARK: Installed

    private var installed: some View {
        VStack(spacing: 0) {
            header(["Image model", "Style", "Size", "Default"])
            ForEach(library.imageModels) { m in
                let spec = ImageModelSpec.spec(for: m)
                let id = m.id.description
                let inUse = ImagePreferences.spec?.id == m.id
                row(selected: selection == id) {
                    HStack(spacing: 9) {
                        if studio.loadedModelID == id { LiveDot() } else { Color.clear.frame(width: 6, height: 6) }
                        Image(systemName: "paintpalette").font(.system(size: 11)).foregroundStyle(inUse ? LX.C.accentText : LX.C.tertiary)
                        Text(spec.name).font(LX.F.ui(12.5, .medium)).lineLimit(1)
                        if inUse { Tag(text: "IN IMAGE", color: LX.C.accentText) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(spec.style).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).frame(width: 140, alignment: .leading)
                    Text(ModelDisplay.bytes(m.diskBytes)).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                    Text("\(spec.defaultSteps) steps").font(LX.F.mono(12)).foregroundStyle(LX.C.tertiary).frame(width: 90, alignment: .trailing)
                }
                .onTapGesture { selection = id }
                .simultaneousGesture(TapGesture(count: 2).onEnded { use(m.id) })
            }
            if library.imageModels.isEmpty {
                Text("No image models yet — pick one in Discover.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: LX.S.tableRow)
            }
        }
        .well().clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
    }

    /// Single-file SDXL checkpoints (Civitai, ComfyUI, A1111…) become regular image models.
    private var importRow: some View {
        HStack(spacing: 10) {
            if let name = library.importingCheckpoint {
                ProgressView().controlSize(.small)
                Text("Importing \(name)…").font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
            } else {
                LXButton(title: "Import Model File…", symbol: "square.and.arrow.down") { chooseCheckpoint() }
                Text("A single .safetensors SDXL checkpoint (Pony, Illustrious, Civitai models…) — converted once, then it works like any other model.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func chooseCheckpoint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.message = "Choose an SDXL checkpoint (.safetensors). Lay X converts a copy; the file stays where it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let id = await library.importCheckpoint(url) { selection = id.description }
        }
    }

    // MARK: Discover

    private var discover: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Curated models by what they're good at; each card says which kind of model it is.
            HStack(spacing: 6) {
                PurposeChip(title: "All", symbol: "square.grid.2x2", on: purpose == nil) { purpose = nil }
                ForEach(ImagePurpose.allCases) { p in
                    PurposeChip(title: p.title, symbol: p.symbol, on: purpose == p) { purpose = purpose == p ? nil : p }
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(catalog) { spec in
                    ImageModelCard(spec: spec, selected: selection == spec.id.description) {
                        status(spec)
                    }
                    .onTapGesture { selection = spec.id.description }
                }
            }
            if catalog.isEmpty {
                Text("No picks match — try the Hugging Face list below.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
            }
            hubSection.padding(.top, 8)
        }
        .task(id: "\(filter)|\(hubSort.rawValue)|\(hubFamily?.rawValue ?? "all")") {
            try? await Task.sleep(for: .milliseconds(350))   // debounce typing
            guard !Task.isCancelled else { return }
            await searchHub(reset: true)
        }
    }

    // MARK: Hugging Face (every pipeline of a supported architecture in diffusers format)

    private var hubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel(text: "On Hugging Face", trailing: "diffusers").fixedSize()
                if hubLoading { ProgressView().controlSize(.small) }
                Spacer()
                Segmented(options: [(HubAPI.Sort.downloads, "Downloads"), (.trending, "Trending"), (.likes, "Likes"), (.updated, "Updated")],
                          selection: $hubSort)
            }
            HStack(spacing: 10) {
                Segmented(options: [(ImageFamily?.none, "All supported"), (.sdxl, "SDXL"), (.zImage, "Z-Image"), (.flux2Klein, "FLUX.2 klein"), (.qwenImage, "Qwen-Image")],
                          selection: $hubFamily)
                    .fixedSize()
                Spacer()
            }
            Text(hubFamily == nil
                 ? "Every diffusers pipeline Lay X can run. Single-file checkpoints (Civitai) go through Installed → Import Model File…"
                 : hubFamily == .qwenImage
                 ? "Qwen-Image models in bf16 (or Lay X’s 8-bit layout). Pre-quantized repos (bnb, SDNQ, Nunchaku) and Edit models aren’t supported."
                 : hubFamily == .sdxl ? "SDXL checkpoints in diffusers format — Pony, Illustrious, NoobAI and more."
                 : hubFamily == .zImage ? "Z-Image Turbo and base in bf16 (Alibaba Tongyi), and their fine-tunes. Pre-quantized repos aren’t supported."
                 : "FLUX.2 klein 4B in bf16 — distilled (4 steps) and base (with guidance). 9B models and pre-quantized repos aren’t supported.")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                header(["Model", "Type", "Downloads", "Status"])
                ForEach(hubResults.filter { r in !ImageModelSpec.catalog.contains { $0.id == r.id } }) { r in
                    let id = r.id.description
                    row(selected: selection == id) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.id.name).font(LX.F.ui(12.5, .medium)).lineLimit(1)
                            Text("\(r.id.owner) · \(r.likes.formatted(.number.notation(.compactName))) likes · \(ModelDisplay.age(r.lastModified))")
                                .font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        FamilyBadge(family: spec(r.id).family).frame(width: 140, alignment: .leading)
                        Text(r.downloads.formatted(.number.notation(.compactName))).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                        hubStatus(r.id).frame(width: 90, alignment: .trailing)
                    }
                    .onTapGesture { selection = id }
                }
                if let hubError {
                    Text(hubError).font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).padding(.horizontal, 12).frame(height: LX.S.tableRow)
                } else if hubResults.isEmpty && !hubLoading {
                    Text(filter.isEmpty ? "No results." : "No \(hubFamily?.displayName ?? "supported") models found for “\(filter)”.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: LX.S.tableRow)
                }
            }
            .well().clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
            HStack {
                Text("Some repositories are gated or missing parts — Lay X checks before downloading. Each model has its own license.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                Spacer()
                if hubNext != nil {
                    LXButton(title: "More", symbol: "chevron.down") { Task { await searchHub(reset: false) } }
                        .disabled(hubLoading)
                }
            }
        }
    }

    @ViewBuilder private func hubStatus(_ id: ModelRepoID) -> some View {
        if library.imageModels.contains(where: { $0.id == id }) {
            Text("Installed").font(LX.F.ui(11)).foregroundStyle(LX.C.ok)
        } else if case .active(let p)? = library.downloads[id] {
            Text("\(Int(p.fraction * 100))%").font(LX.F.mono(11)).foregroundStyle(LX.C.liveCyan)
        } else if case .failed? = library.downloads[id] {
            Text("Failed").font(LX.F.ui(11)).foregroundStyle(LX.C.warn)
        } else {
            Button("Download") { library.download(id, kind: .image) }
                .buttonStyle(.plain).font(LX.F.ui(11.5, .semibold)).foregroundStyle(LX.C.accentText)
        }
    }

    private func searchHub(reset: Bool) async {
        hubLoading = true
        defer { hubLoading = false }
        do {
            let hub = HubAPI()
            let q = filter.trimmingCharacters(in: .whitespaces)
            let query = ModelRepoID(q) != nil ? "" : q
            let author = ModelRepoID(q)?.owner
            if !reset, let next = hubNext, let family = hubFamily {
                let page = try await hub.page(at: next)
                for r in page.results { hubFamilies[r.id] = family }
                hubResults += page.results
                hubNext = page.next
            } else if let family = hubFamily {
                let page = try await hub.searchPage(query, author: author, sort: hubSort, limit: 40, filter: family.hubFilter)
                for r in page.results { hubFamilies[r.id] = family }
                hubResults = page.results
                hubNext = page.next
            } else {
                // Every supported architecture: one query each, merged in the chosen order.
                let families: [ImageFamily] = [.sdxl, .zImage, .flux2Klein, .qwenImage]
                var merged: [HubModelSummary] = []
                try await withThrowingTaskGroup(of: (ImageFamily, [HubModelSummary]).self) { group in
                    for family in families {
                        group.addTask { (family, try await hub.searchPage(query, author: author, sort: hubSort, limit: 20, filter: family.hubFilter).results) }
                    }
                    for try await (family, results) in group {
                        for r in results { hubFamilies[r.id] = family }
                        merged += results
                    }
                }
                hubResults = merged.sorted { a, b in
                    switch hubSort {
                    case .likes: a.likes > b.likes
                    case .updated: (a.lastModified ?? .distantPast) > (b.lastModified ?? .distantPast)
                    case .trending: a.trendingScore != b.trendingScore ? a.trendingScore > b.trendingScore : a.downloads > b.downloads
                    default: a.downloads > b.downloads
                    }
                }
                hubNext = nil
            }
            hubError = nil
        } catch {
            hubError = "Hugging Face couldn’t be reached (\((error as? LocalizedError)?.errorDescription ?? "offline")). Downloaded models keep working."
        }
    }

    @ViewBuilder private func status(_ spec: ImageModelSpec) -> some View {
        if library.imageModel(spec) != nil {
            Text("Installed").font(LX.F.ui(11)).foregroundStyle(LX.C.ok)
        } else if case .active(let p)? = library.downloads[spec.id] {
            Text("\(Int(p.fraction * 100))%").font(LX.F.mono(11)).foregroundStyle(LX.C.liveCyan)
        } else {
            Button("Download") { library.download(spec.id, kind: .image) }
                .buttonStyle(.plain).font(LX.F.ui(11.5, .semibold)).foregroundStyle(LX.C.accentText)
        }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        let id = selection.flatMap(ModelRepoID.init)
        if let file = selection.flatMap({ $0.hasPrefix("lora:") ? String($0.dropFirst(5)) : nil }),
           let info = studio.loraLibrary.first(where: { $0.file == file }) {
            loraDetails(info)
        } else if let id {
            let spec = spec(id)
            let installed = library.imageModels.first { $0.id == id }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spec.name).font(LX.F.ui(16, .semibold))
                        Text(id.description).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).textSelection(.enabled)
                    }
                    Text(spec.summary).font(LX.F.body).foregroundStyle(LX.C.body).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        kv("Type", spec.family.displayName)
                        kv("Good at", spec.purposes.map(\.title).joined(separator: " · "))
                        kv("Style", spec.style)
                        kv("Publisher", spec.publisher)
                        kv("Default", "\(spec.defaultSize.label) · \(spec.defaultSteps) steps · " + (spec.usesGuidance
                            ? "CFG \(spec.defaultCFG <= 1 ? "off" : String(format: "%.1f", spec.defaultCFG))" : "guidance built in"))
                        kv("Supports", Self.features(spec))
                        kv("On disk", installed.map { ModelDisplay.bytes($0.diskBytes) } ?? "≈ \(ModelDisplay.bytes(spec.downloadBytes)) download")
                        kv("Memory", String(format: "≈ %.0f GB at %@", Double(spec.runtimeBytes(for: spec.defaultSize)) / 1_073_741_824, spec.defaultSize.label))
                        HStack {
                            Text("License").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).frame(width: 80, alignment: .leading)
                            Link(spec.license, destination: spec.licenseURL).font(LX.F.ui(12)).foregroundStyle(LX.C.accentText)
                        }
                    }
                    if let installed {
                        HStack(spacing: 8) {
                            LXButton(title: "Use in Image", symbol: "paintpalette", kind: .primary) { use(installed.id) }
                            IconButton(symbol: "magnifyingglass", help: "Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([installed.directory])
                            }
                            IconButton(symbol: "trash", help: "Delete model") { confirmDelete = installed }
                                .disabled(studio.isBusy)
                        }
                    } else if case .active(let p)? = library.downloads[id] {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: p.fraction).tint(LX.C.accent)
                            HStack {
                                Text("\(ModelDisplay.bytes(p.receivedBytes)) of \(ModelDisplay.bytes(p.totalBytes))").font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                                Spacer()
                                LXButton(title: "Cancel") { library.cancelDownload(id) }
                            }
                        }
                    } else {
                        LXButton(title: "Download", symbol: "arrow.down.circle", kind: .primary) { library.download(id, kind: .image) }
                        if case .failed(let message)? = library.downloads[id] {
                            Text(message).font(LX.F.caption).foregroundStyle(LX.C.error)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("Select a model").font(LX.F.body).foregroundStyle(LX.C.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: LoRA

    private var loraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel(text: "LoRA", trailing: studio.loraLibrary.isEmpty ? nil : "\(studio.loraLibrary.count)").fixedSize()
                Spacer()
                if let folder = studio.loraFolder {
                    IconButton(symbol: "folder", help: "Show the LoRA folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                LXButton(title: "Add LoRA…", symbol: "plus") { addLoRAs() }
            }
            .padding(.top, 10)
            VStack(spacing: 0) {
                header(["LoRA", "Made for", "Size", "Status"])
                ForEach(studio.loraLibrary) { info in
                    let key = "lora:\(info.file)"
                    let on = studio.activeLoRAs.contains { $0.file == info.file && $0.scale != 0 }
                    row(selected: selection == key) {
                        HStack(spacing: 9) {
                            Image(systemName: "puzzlepiece.extension").font(.system(size: 11)).foregroundStyle(on ? LX.C.accentText : LX.C.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name).font(LX.F.ui(12.5, .medium)).lineLimit(1).truncationMode(.middle)
                                if !info.triggerWords.isEmpty {
                                    Text("Trigger: \(info.triggerWords.joined(separator: ", "))").font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.loraBase(info)).font(LX.F.ui(12)).foregroundStyle(Self.loraUsable(info) ? LX.C.secondary : LX.C.warn)
                            .lineLimit(1).frame(width: 140, alignment: .leading)
                        Text(ModelDisplay.bytes(info.bytes)).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                        Text(on ? "On" : "—").font(LX.F.ui(11)).foregroundStyle(on ? LX.C.ok : LX.C.tertiary).frame(width: 90, alignment: .trailing)
                    }
                    .onTapGesture { selection = key }
                }
                if studio.loraLibrary.isEmpty {
                    Text("No LoRAs yet. Add .safetensors files for SDXL, Z-Image, FLUX.2 klein 4B or Qwen-Image.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: LX.S.tableRow)
                }
            }
            .well().clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
        }
        .onAppear { studio.refreshLoRAs() }
    }

    static func loraBase(_ info: LoRALibrary.Info) -> String {
        switch info.fit {
        case .fits(let base): base.displayName
        case .otherBase(let base): base + " (not supported)"
        case .fullModel: "Full model — import it"
        case .unknown: "Unknown"
        }
    }

    static func loraUsable(_ info: LoRALibrary.Info) -> Bool {
        switch info.fit {
        case .fits, .unknown: true
        case .otherBase, .fullModel: false
        }
    }

    private func addLoRAs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose LoRA files (.safetensors) for SDXL, Z-Image, FLUX.2 klein 4B or Qwen-Image. They are copied into Lay X."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { studio.importLoRA(url) }
        if let last = panel.urls.last { selection = "lora:\(last.lastPathComponent)" }
    }

    @ViewBuilder private func loraDetails(_ info: LoRALibrary.Info) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(LX.F.ui(16, .semibold)).lineLimit(2)
                    Text(info.file).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    kv("Made for", Self.loraBase(info))
                    if let base = info.baseModel { kv("Trained on", base) }
                    kv("Size", ModelDisplay.bytes(info.bytes))
                    kv("Trigger", info.triggerWords.isEmpty ? "—" : info.triggerWords.joined(separator: ", "))
                }
                if info.fit == .fullModel {
                    Text("This file is a whole model, not a LoRA. Import it as an image model; the copy here can then be deleted.")
                        .font(LX.F.caption).foregroundStyle(LX.C.warn).fixedSize(horizontal: false, vertical: true)
                    if let folder = studio.loraFolder {
                        LXButton(title: "Import as Image Model", symbol: "square.and.arrow.down", kind: .primary) {
                            Task {
                                if let id = await library.importCheckpoint(folder.appendingPathComponent(info.file)) {
                                    studio.deleteLoRA(info.file)
                                    selection = id.description
                                }
                            }
                        }
                        .disabled(library.importingCheckpoint != nil)
                    }
                } else {
                    Text("Switch it on and set its strength in Image → LoRA. Models it wasn’t made for show it greyed out.")
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let folder = studio.loraFolder {
                        IconButton(symbol: "magnifyingglass", help: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(info.file)])
                        }
                    }
                    IconButton(symbol: "trash", help: "Delete LoRA") { confirmDeleteLoRA = info }
                }
            }
            .padding(16)
        }
        .confirmationDialog("Delete \(confirmDeleteLoRA?.name ?? "LoRA")?",
                            isPresented: Binding(get: { confirmDeleteLoRA != nil }, set: { if !$0 { confirmDeleteLoRA = nil } }),
                            presenting: confirmDeleteLoRA) { lora in
            Button("Delete \(ModelDisplay.bytes(lora.bytes))", role: .destructive) {
                studio.deleteLoRA(lora.file)
                selection = nil
            }
        } message: { _ in
            Text("Lay X’s copy of the LoRA is removed. The file you added it from stays where it was.")
        }
    }

    static func features(_ spec: ImageModelSpec) -> String {
        var out: [String] = []
        if spec.usesGuidance { out.append("negative prompt") }
        switch spec.family.sourceMode {
        case .strength: out.append("image to image")
        case .reference: out.append("reference image (edits)")
        case .none: break
        }
        out.append("\(spec.family.loraBase.displayName) LoRA")
        return out.joined(separator: " · ")
    }

    private func use(_ id: ModelRepoID) {
        ImagePreferences.select(id)
        state.screen = .image
    }

    // MARK: Table parts

    private func header(_ titles: [String]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                th(titles[0]).frame(maxWidth: .infinity, alignment: .leading)
                th(titles[1]).frame(width: 140, alignment: .leading)
                th(titles[2]).frame(width: 80, alignment: .trailing)
                th(titles[3]).frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
        }
    }

    private func th(_ t: String) -> some View {
        Text(t.uppercased()).font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
    }

    private func row<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) { content() }
            .foregroundStyle(LX.C.body)
            .padding(.horizontal, 12).frame(height: 48)
            .background(LX.C.accent.opacity(selected ? 0.08 : 0))
            .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            .contentShape(Rectangle())
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).frame(width: 80, alignment: .leading)
            Text(v).font(LX.F.ui(12)).foregroundStyle(LX.C.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Purpose filter chip (Discover).
struct PurposeChip: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(LX.F.ui(12, .medium))
            }
            .foregroundStyle(on ? LX.C.onGlass : LX.C.secondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background {
                if on { Capsule().fill(.clear).accentGlass(radius: 13, strength: 0.8) }
                else { Capsule().fill(Color.white.opacity(hover ? 0.07 : 0.035)) }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.07), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

/// "SDXL" / "FLUX.2" / "Qwen" badge in the architecture's colour.
struct FamilyBadge: View {
    let family: ImageFamily
    var body: some View {
        let color: Color = switch family {
        case .sdxl: LX.C.accentText
        case .flux2Klein, .flux2KleinBase: LX.C.liveCyan
        case .qwenImage: LX.C.ok
        case .zImage, .zImageBase: LX.C.warn
        }
        Text(family.displayName).font(LX.F.mono(10)).foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }
}

/// A curated model in Discover: name, kind, what it's for, size and the download control.
struct ImageModelCard<Status: View>: View {
    let spec: ImageModelSpec
    let selected: Bool
    @ViewBuilder let status: () -> Status
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(spec.name).font(LX.F.ui(13.5, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                Spacer(minLength: 4)
                FamilyBadge(family: spec.family)
            }
            Text(spec.summary).font(LX.F.ui(11.5)).foregroundStyle(LX.C.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            HStack(spacing: 6) {
                ForEach(spec.purposes.prefix(3), id: \.self) { p in
                    Image(systemName: p.symbol).font(.system(size: 9.5)).foregroundStyle(LX.C.tertiary).help(p.title)
                }
                Text("≈ \(ModelDisplay.bytes(spec.downloadBytes))").font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                Spacer(minLength: 4)
                status()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous).fill(Color.white.opacity(selected ? 0.07 : hover ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous)
            .strokeBorder(selected ? LX.C.accent.opacity(0.55) : Color.white.opacity(0.07), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}
