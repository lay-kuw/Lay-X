import AppKit
import SwiftUI
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
    /// Architecture browsed on Hugging Face (one pipeline filter at a time).
    @State private var hubFamily: ImageFamily = .sdxl
    private var library: ModelLibrary { AppServices.shared.models }
    private var studio: ImageStudio { AppServices.shared.images }

    private var catalog: [ImageModelSpec] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? ImageModelSpec.catalog : ImageModelSpec.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.style.localizedCaseInsensitiveContains(q) || $0.id.description.localizedCaseInsensitiveContains(q)
        }
    }

    /// Installed models use their recorded family; Hub results the family being browsed.
    private func spec(_ id: ModelRepoID) -> ImageModelSpec {
        if let m = library.imageModels.first(where: { $0.id == id }) { return ImageModelSpec.spec(for: m) }
        return ImageModelSpec.spec(for: id, family: hubFamily)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == .installed { installed } else { discover }
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

    // MARK: Discover

    private var discover: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                header(["Image model", "Style", "Download", "Status"])
                ForEach(catalog) { spec in
                    let id = spec.id.description
                    row(selected: selection == id) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.name).font(LX.F.ui(12.5, .medium)).lineLimit(1)
                            Text(spec.summary).font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(spec.style).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).frame(width: 140, alignment: .leading)
                        Text(ModelDisplay.bytes(spec.downloadBytes)).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                        status(spec).frame(width: 90, alignment: .trailing)
                    }
                    .onTapGesture { selection = id }
                }
            }
            .well().clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
            hubSection
        }
        .task(id: "\(filter)|\(hubSort.rawValue)|\(hubFamily.rawValue)") {
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
                Segmented(options: [(ImageFamily.sdxl, "SDXL"), (.flux2Klein, "FLUX.2 klein"), (.qwenImage, "Qwen-Image")],
                          selection: $hubFamily)
                    .fixedSize()
                Spacer()
            }
            if hubFamily != .sdxl {
                Text(hubFamily == .qwenImage
                     ? "Qwen-Image models in bf16 (or Lay X’s 8-bit layout). Pre-quantized repos (bnb, SDNQ, Nunchaku) and Edit models aren’t supported."
                     : "FLUX.2 klein 4B in bf16 — distilled (4 steps) and base (with guidance). 9B models and pre-quantized repos aren’t supported.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                header(["Model", "Author", "Downloads", "Status"])
                ForEach(hubResults.filter { r in !ImageModelSpec.catalog.contains { $0.id == r.id } }) { r in
                    let id = r.id.description
                    row(selected: selection == id) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.id.name).font(LX.F.ui(12.5, .medium)).lineLimit(1)
                            Text("\(r.likes.formatted(.number.notation(.compactName))) likes · \(ModelDisplay.age(r.lastModified))")
                                .font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(r.id.owner).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).lineLimit(1).frame(width: 140, alignment: .leading)
                        Text(r.downloads.formatted(.number.notation(.compactName))).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                        hubStatus(r.id).frame(width: 90, alignment: .trailing)
                    }
                    .onTapGesture { selection = id }
                }
                if let hubError {
                    Text(hubError).font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).padding(.horizontal, 12).frame(height: LX.S.tableRow)
                } else if hubResults.isEmpty && !hubLoading {
                    Text(filter.isEmpty ? "No results." : "No \(hubFamily.displayName) models found for “\(filter)”.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
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
            let page: HubAPI.Page
            if !reset, let next = hubNext {
                page = try await hub.page(at: next)
            } else {
                let q = filter.trimmingCharacters(in: .whitespaces)
                page = try await hub.searchPage(ModelRepoID(q) != nil ? "" : q, author: ModelRepoID(q)?.owner, sort: hubSort,
                                                limit: 40, filter: hubFamily.hubFilter)
            }
            hubResults = reset ? page.results : hubResults + page.results
            hubNext = page.next
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
        if let id {
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
