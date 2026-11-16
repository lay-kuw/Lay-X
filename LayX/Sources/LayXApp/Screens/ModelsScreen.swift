import AppKit
import SwiftUI
import LayXCore

struct ModelsScreen: View {
    enum Tab: Hashable { case installed, discover, downloads }
    @EnvironmentObject var state: AppState
    @Environment(InferenceStatusModel.self) private var inference
    private var library: ModelLibrary { AppServices.shared.models }

    @State private var filter = ""
    @State private var selection: String?
    @State private var confirmDelete: ModelRepoID?

    private var tab: Tab { state.modelsTab }

    private var filteredInstalled: [InstalledModel] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? library.installed : library.installed.filter {
            $0.id.description.localizedCaseInsensitiveContains(q) || ModelDisplay.name($0.id).localizedCaseInsensitiveContains(q)
        }
    }

    /// A pasted `owner/name` that isn't installed yet.
    private var pastedRepo: ModelRepoID? {
        let raw = filter.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://huggingface.co/", with: "")
        guard let id = ModelRepoID(raw), library.model(id.description) == nil,
              !library.imageModels.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Models").font(LX.F.title)
                Segmented(options: [(ModelKind.language, "Text"), (.image, "Image")], selection: $state.modelsKind)
                    .padding(.leading, 10)
                    .help("Text models are used by Chat, Work and the API; image models by Image")
                Segmented(options: [(Tab.installed, "Installed"), (.discover, "Discover"), (.downloads, "Downloads")],
                          selection: $state.modelsTab,
                          indicators: library.activeDownloads.isEmpty ? [:] : [.downloads: "arrow.down.circle.fill"])
                    .padding(.leading, 10)
            } trailing: {
                LXField(placeholder: state.modelsKind == .image ? "Search or paste SDXL repo" : "Filter or paste HF repo", text: $filter, symbol: "magnifyingglass").frame(width: 220)
                    .onSubmit { addModel() }
                LXButton(title: "Add model", symbol: "plus", shortcut: "⌘⇧N", kind: .primary) { addModel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            if state.modelsKind == .image && tab != .downloads {
                ImageModelsPane(tab: tab, filter: filter)
            } else {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        switch tab {
                        case .installed:
                            storage
                            installedTable
                            ForEach(library.activeDownloads, id: \.id) { downloadRow($0.id, $0.progress) }
                        case .discover:
                            discoverTable
                        case .downloads:
                            downloadsList
                        }
                    }
                    .padding(16)
                }
                Rectangle().fill(LX.C.divider).frame(width: 1)
                details.frame(width: 320)
            }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = library.notice {
                Toast(text: notice).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if library.notice == notice { library.notice = nil }
                    }
            }
        }
        .animation(LX.M.panel, value: library.notice)
        .onAppear {
            library.refresh()
            if selection == nil { selection = inference.loadedModel?.id ?? library.installed.first?.id.description }
        }
        .onChange(of: tab) { _, new in
            if new == .discover && state.modelsKind == .language && library.searchResults.isEmpty { library.search(filter, debounce: false) }
        }
        .onChange(of: filter) { _, new in
            if tab == .discover && state.modelsKind == .language { library.search(new) }
        }
        .confirmationDialog("Delete \(confirmDelete.map(ModelDisplay.name) ?? "model")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { id in
            Button("Delete", role: .destructive) { library.delete(id, loadedID: inference.loadedModel?.id) }
        } message: { id in
            Text("Removes \(id.description) from \(library.store.root.path). Other files are not touched.")
        }
    }

    private func addModel() {
        if let id = pastedRepo {
            library.download(id, kind: state.modelsKind)
            state.modelsTab = .downloads
            filter = ""
        } else {
            state.modelsTab = .discover
        }
    }

    // MARK: Storage

    private var storage: some View {
        let sorted = library.installed.sorted { $0.diskBytes > $1.diskBytes }
        let top = Array(sorted.prefix(3))
        let other = sorted.dropFirst(3).reduce(Int64(0)) { $0 + $1.diskBytes }
        let capacity = max(Double(library.storageUsed + library.storageFree), 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionLabel(text: "Storage").fixedSize()
                Text("\(Text(ModelDisplay.bytes(library.storageUsed)).foregroundStyle(LX.C.primary))\(Text(" used by models · \(ModelDisplay.bytes(library.storageFree)) free").foregroundStyle(LX.C.tertiary))")
                    .font(LX.F.mono(12))
                Spacer()
                Text(abbreviatedPath(library.store.root)).font(LX.F.mono(11)).foregroundStyle(LX.C.accentText)
                    .lineLimit(1).truncationMode(.middle)
                    .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([library.store.root]) }
                    .help("Show in Finder")
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, m in
                        Rectangle().fill(LX.C.series[i]).frame(width: geo.size.width * Double(m.diskBytes) / capacity)
                    }
                    if other > 0 {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(width: geo.size.width * Double(other) / capacity)
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 8)
            HStack(spacing: 16) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, m in
                    legend(LX.C.series[i], "\(ModelDisplay.name(m.id)) · \(String(format: "%.1f", Double(m.diskBytes) / 1e9))")
                }
                if other > 0 {
                    legend(Color.white.opacity(0.22), "Other \(sorted.count - 3) · \(String(format: "%.1f", Double(other) / 1e9))")
                }
                if sorted.isEmpty {
                    Text("No models yet — find one in Discover or paste a Hugging Face repo above.")
                        .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8); Text(t) }
            .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
    }

    // MARK: Installed

    private var installedTable: some View {
        VStack(spacing: 0) {
            tableHeader(["Model", "Params", "Quant", "Size", "Context", "tok/s", "Used"])
            ForEach(filteredInstalled) { m in
                let id = m.id.description
                let on = id == selection
                let loaded = inference.loadedModel?.id == id
                HStack(spacing: 0) {
                    HStack(spacing: 9) {
                        if loaded { LiveDot() } else if loading(id) { ProgressView().controlSize(.mini).frame(width: 6, height: 6) }
                        else { Color.clear.frame(width: 6, height: 6) }
                        Text(ModelDisplay.name(m.id)).font(LX.F.ui(12.5, on ? .semibold : .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ModelDisplay.parameters(m.id) ?? "—").font(LX.F.mono(12)).frame(width: 90, alignment: .leading)
                    Tag(text: ModelDisplay.quant(bits: m.manifest.quantizationBits), color: Color(hex: 0xC9CBD6)).frame(width: 80, alignment: .leading)
                    Text(ModelDisplay.bytes(m.diskBytes)).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                    Text(ModelDisplay.context(m.manifest.contextLength)).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                    Text(inference.metricsByModel[id]?.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                        .font(LX.F.mono(12)).frame(width: 70, alignment: .trailing)
                    Text(loaded ? "now" : ModelDisplay.age(library.lastUsed(m.id))).font(LX.F.mono(12)).foregroundStyle(LX.C.tertiary)
                        .frame(width: 60, alignment: .trailing)
                }
                .foregroundStyle(LX.C.body)
                .padding(.horizontal, 12).frame(height: LX.S.tableRow)
                .background(LX.C.accent.opacity(on ? 0.08 : 0))
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                .contentShape(Rectangle())
                // A count:2 tap gesture would delay every single click by the double-click interval;
                // handle both simultaneously so selection is immediate.
                .simultaneousGesture(TapGesture().onEnded { selection = id })
                .simultaneousGesture(TapGesture(count: 2).onEnded { library.load(m) })
            }
            if filteredInstalled.isEmpty {
                emptyRow(library.installed.isEmpty ? "No models installed." : "No installed model matches “\(filter)”.")
            }
        }
        .well()
        .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
    }

    private func loading(_ id: String) -> Bool {
        if case .loading(let l, _) = inference.snapshot.model { return l == id }
        return false
    }

    private func tableHeader(_ titles: [String]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                th(titles[0]).frame(maxWidth: .infinity, alignment: .leading)
                th(titles[1]).frame(width: 90, alignment: .leading)
                th(titles[2]).frame(width: 80, alignment: .leading)
                th(titles[3]).frame(width: 80, alignment: .trailing)
                th(titles[4]).frame(width: 80, alignment: .trailing)
                th(titles[5]).frame(width: 70, alignment: .trailing)
                th(titles[6]).frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
        }
    }

    private func th(_ t: String) -> some View {
        Text(t.uppercased()).font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).frame(height: LX.S.tableRow)
    }

    // MARK: Discover

    private var discoverTable: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Segmented(options: HubAPI.Sort.allCases.map { ($0, $0.title) },
                          selection: Binding(get: { library.sort }, set: { library.sort = $0; library.search(filter, debounce: false) }))
                Spacer()
                Segmented(options: [(true, "mlx-community"), (false, "All MLX")],
                          selection: Binding(get: { library.curatedOnly }, set: { library.curatedOnly = $0; library.search(filter, debounce: false) }))
                    .help("mlx-community hosts curated MLX conversions; All MLX includes every repo tagged mlx")
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    th("Model").frame(maxWidth: .infinity, alignment: .leading)
                    th("Params").frame(width: 80, alignment: .leading)
                    th("Quant").frame(width: 66, alignment: .leading)
                    th("Arch").frame(width: 104, alignment: .leading)
                    th("Status").frame(width: 92, alignment: .leading)
                    th("Downloads").frame(width: 86, alignment: .trailing)
                    th("Likes").frame(width: 56, alignment: .trailing)
                    th("Updated").frame(width: 66, alignment: .trailing)
                }
                .padding(.horizontal, 12).frame(height: 30)
                Rectangle().fill(LX.C.divider).frame(height: 1)
                ForEach(library.searchResults) { r in
                    let id = r.id.description
                    let on = id == selection
                    let compat = library.compatibility[r.id] ?? .unknown
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ModelDisplay.name(r.id)).font(LX.F.ui(12.5, on ? .semibold : .medium)).lineLimit(1)
                            Text(id).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(ModelDisplay.parameters(r.id) ?? "—").font(LX.F.mono(12)).lineLimit(1).frame(width: 80, alignment: .leading)
                        Tag(text: ModelDisplay.quant(bits: r.quantizationBits), color: Color(hex: 0xC9CBD6)).frame(width: 66, alignment: .leading)
                        Text(r.modelType ?? "—").font(LX.F.mono(11)).lineLimit(1).truncationMode(.tail).frame(width: 104, alignment: .leading)
                        statusText(r.id, compat).frame(width: 92, alignment: .leading)
                        Text(r.downloads.formatted(.number.notation(.compactName))).font(LX.F.mono(12)).frame(width: 86, alignment: .trailing)
                        Text(r.likes.formatted(.number.notation(.compactName))).font(LX.F.mono(12)).frame(width: 56, alignment: .trailing)
                        Text(ModelDisplay.age(r.lastModified)).font(LX.F.mono(12)).foregroundStyle(LX.C.tertiary).frame(width: 66, alignment: .trailing)
                    }
                    .foregroundStyle(compat.isCompatible ? LX.C.body : LX.C.tertiary)
                    .padding(.horizontal, 12).frame(height: 46)
                    .background(LX.C.accent.opacity(on ? 0.08 : 0))
                    .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = id }
                }
                if library.isSearching && library.searchResults.isEmpty {
                    emptyRow("Searching Hugging Face…")
                } else if let err = library.searchError {
                    emptyRow(err)
                } else if library.searchResults.isEmpty {
                    emptyRow(filter.isEmpty ? "No MLX language models on this page." : "No MLX models found for “\(filter)”.")
                }
            }
            .well()
            .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
            .opacity(library.isSearching && !library.searchResults.isEmpty ? 0.6 : 1)

            HStack(spacing: 8) {
                Text("Page \(library.pageNumber) · \(library.searchResults.count) language models · sorted by \(library.sort.title.lowercased())")
                    .font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                if library.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                LXButton(title: "Previous", symbol: "chevron.left") { library.previousPage() }
                    .disabled(library.pageNumber <= 1 || library.isSearching)
                LXButton(title: "Next", symbol: "chevron.right") { library.nextPage() }
                    .disabled(!library.hasNextPage || library.isSearching)
            }
        }
    }

    @ViewBuilder private func statusText(_ id: ModelRepoID, _ compat: ModelCompatibility) -> some View {
        if library.model(id.description) != nil {
            Text("Installed").font(LX.F.ui(11)).foregroundStyle(LX.C.ok)
        } else if case .active? = library.downloads[id] {
            Text("Downloading").font(LX.F.ui(11)).foregroundStyle(LX.C.liveCyan)
        } else {
            switch compat {
            case .compatible: Text("Compatible").font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
            case .unsupportedArchitecture: Text("Unsupported").font(LX.F.ui(11)).foregroundStyle(LX.C.warn)
            default: Text("Unknown").font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary)
            }
        }
    }

    // MARK: Downloads

    private var downloadsList: some View {
        VStack(spacing: 14) {
            ForEach(library.activeDownloads, id: \.id) { downloadRow($0.id, $0.progress) }
            ForEach(library.incomplete.filter { p in !library.activeDownloads.contains { $0.id == p.id } }, id: \.id) { p in
                pausedRow(p.id, bytes: p.bytes)
            }
            ForEach(library.downloads.compactMap { id, s -> (ModelRepoID, String)? in
                if case .failed(let msg) = s, !library.incomplete.contains(where: { $0.id == id }) { (id, msg) } else { nil }
            }, id: \.0) { id, msg in
                failedRow(id, msg)
            }
            if library.activeDownloads.isEmpty && library.incomplete.isEmpty
                && !library.downloads.values.contains(where: { if case .failed = $0 { true } else { false } }) {
                Text("No downloads. Paste a Hugging Face repo (owner/name) above or pick one in Discover.")
                    .font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .well()
            }
        }
    }

    private func downloadRow(_ id: ModelRepoID, _ p: DownloadProgress) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").foregroundStyle(LX.C.liveCyan)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ModelDisplay.name(id)).font(LX.F.ui(12.5, .medium))
                    Text(id.description).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                    Spacer()
                    Text(p.totalBytes > 0 ? String(format: "%.1f / %.1f GB", Double(p.receivedBytes) / 1e9, Double(p.totalBytes) / 1e9) : "…")
                        .font(LX.F.mono(11.5)).contentTransition(.numericText())
                    Text(rateText(p)).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule().fill(LX.C.liveGradient).frame(width: geo.size.width * p.fraction)
                    }
                }
                .frame(height: 4)
            }
            LXButton(title: "Pause") { library.cancelDownload(id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .well()
    }

    private func rateText(_ p: DownloadProgress) -> String {
        switch p.phase {
        case .preparing: return "preparing"
        case .verifying: return "verifying"
        case .finalizing: return "finishing"
        case .downloading:
            guard p.bytesPerSecond > 0 else { return "" }
            let left = Double(p.totalBytes - p.receivedBytes) / p.bytesPerSecond
            return String(format: "%.0f MB/s · %@ left", p.bytesPerSecond / 1e6,
                          left < 60 ? "\(Int(left)) s" : "\(Int(left / 60)) min")
        }
    }

    private func pausedRow(_ id: ModelRepoID, bytes: Int64) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").foregroundStyle(LX.C.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(ModelDisplay.name(id)).font(LX.F.ui(12.5, .medium))
                    Text(id.description).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                Text("Paused · \(ModelDisplay.bytes(bytes)) downloaded").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
            }
            Spacer()
            LXButton(title: "Discard", kind: .danger) { library.discardPartial(id) }
            LXButton(title: "Resume") { library.download(id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .well()
    }

    private func failedRow(_ id: ModelRepoID, _ message: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(LX.C.error)
            VStack(alignment: .leading, spacing: 3) {
                Text(ModelDisplay.name(id)).font(LX.F.ui(12.5, .medium))
                Text(message).font(LX.F.ui(11.5)).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            LXButton(title: "Retry") { library.download(id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .well()
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        if let id = selection, let m = library.model(id) {
            installedDetails(m)
        } else if let id = selection, let r = library.searchResults.first(where: { $0.id.description == id }) {
            discoverDetails(r)
        } else {
            Text("Select a model").font(LX.F.body).foregroundStyle(LX.C.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func installedDetails(_ m: InstalledModel) -> some View {
        let id = m.id.description
        let loaded = inference.loadedModel?.id == id
        let metrics = inference.metricsByModel[id]
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelDisplay.name(m.id)).font(LX.F.ui(15, .semibold))
                Text(id).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if loaded { Tag(text: "LOADED", color: LX.C.ok) }
                if loading(id) { Tag(text: "LOADING", color: LX.C.liveCyan) }
                Tag(text: "MLX", color: Color(hex: 0xC9CBD6))
            }
            Text(loadStatusText(id))
                .font(LX.F.bodySmall).foregroundStyle(LX.C.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                kv("Architecture", m.manifest.modelType ?? "—")
                kv("Quantization", ModelDisplay.quant(bits: m.manifest.quantizationBits))
                kv("On disk", ModelDisplay.bytes(m.diskBytes))
                kv("Max context", m.manifest.contextLength.map { $0.formatted() } ?? "—")
                kv("Downloaded", m.manifest.downloadedAt.formatted(date: .abbreviated, time: .omitted))
            }
            HStack(spacing: 8) {
                stat(metrics.map { String(format: "%.0fms", $0.timeToFirstToken.milliseconds) } ?? "—", "TTFT")
                stat(metrics?.prefillTokensPerSecond.map { Int($0).formatted() } ?? "—", "Prefill")
                stat(metrics?.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—", "Decode")
            }
            .padding(12).well()
            Spacer()
            HStack(spacing: 8) {
                LXButton(title: "Open in Chat", kind: .primary) {
                    if !loaded { library.load(m) }
                    state.screen = .chat
                }
                LXButton(title: loaded ? "Unload" : "Load") { loaded ? library.unload() : library.load(m) }
                    .disabled(loading(id))
                LXButton(title: "Delete", kind: .danger) { confirmDelete = m.id }
                    .disabled(loaded || loading(id))
                    .help(loaded ? "Unload the model before deleting it" : "Delete from disk")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
    }

    private func loadStatusText(_ id: String) -> String {
        switch inference.snapshot.model {
        case .failed(let failed, let message) where failed == id: return message
        case .loading(let l, _) where l == id: return "Loading weights into unified memory…"
        default:
            return "Runs fully on-device with MLX. Numbers below are from the last generation with this model in this session."
        }
    }

    private func discoverDetails(_ r: HubModelSummary) -> some View {
        let compat = library.compatibility[r.id] ?? .unknown
        let installed = library.model(r.id.description) != nil
        let downloading = { if case .active? = library.downloads[r.id] { true } else { false } }()
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelDisplay.name(r.id)).font(LX.F.ui(15, .semibold))
                Text(r.id.description).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Tag(text: compat.isCompatible ? "COMPATIBLE" : "UNSUPPORTED", color: compat.isCompatible ? LX.C.ok : LX.C.warn)
                if installed { Tag(text: "INSTALLED", color: Color(hex: 0xC9CBD6)) }
            }
            Text(compat.isCompatible
                 ? "MLX weights for an architecture Lay X can run. Downloads from Hugging Face; inference stays on this Mac."
                 : "\(compat.label). Lay X only runs MLX language models whose architecture is implemented by MLX Swift LM.")
                .font(LX.F.bodySmall).foregroundStyle(LX.C.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                kv("Architecture", r.modelType ?? "—")
                kv("Quantization", ModelDisplay.quant(bits: r.quantizationBits))
                kv("Downloads", r.downloads.formatted())
                kv("Updated", r.lastModified?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
            Spacer()
            HStack(spacing: 8) {
                LXButton(title: installed ? "Installed" : (downloading ? "Downloading…" : "Download"), symbol: "arrow.down.to.line", kind: .primary) {
                    library.download(r.id)
                    state.modelsTab = .downloads
                }
                .disabled(!compat.isCompatible || installed || downloading)
                LXButton(title: "Model card") {
                    if let url = URL(string: "https://huggingface.co/\(r.id.description)") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(LX.C.secondary); Spacer(); Text(v).font(LX.F.mono(12)).lineLimit(1) }
            .font(LX.F.ui(12)).frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(LX.F.mono(15))
            Text(k).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
