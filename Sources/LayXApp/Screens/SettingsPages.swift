import AppKit
import SwiftUI
import LayXCore
import LayXServer

// Settings pages added in Stage G. Same building blocks (group/row/menuLabel) as the designed pages.
extension SettingsScreen {
    // MARK: General

    var generalPage: some View {
        GeneralSettings(screen: self)
    }

    // MARK: Chats & Privacy

    var privacyPage: some View {
        PrivacySettings(screen: self)
    }

    // MARK: API Server

    var apiPage: some View {
        APISettings(screen: self)
    }

    // MARK: Shortcuts

    var shortcutsPage: some View {
        let hotKey = GlobalHotKey.shared
        return VStack(alignment: .leading, spacing: 22) {
            group("Global") {
                row("Mini Chat", "Opens Mini Chat from any app") {
                    Menu {
                        ForEach(HotKeySpec.choices) { spec in Button(spec.displayString) { hotKey.set(spec) } }
                        Divider()
                        Button("Off") { hotKey.set(nil) }
                    } label: { menuLabel(hotKey.current?.displayString ?? "Off", width: 160) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                row("Status", nil) {
                    Text(hotKey.status.message).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 360, alignment: .trailing)
                }
            }
            Text("In-app shortcuts are listed in the menu bar menus.")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
        }
    }

    // MARK: Advanced

    var advancedPage: some View {
        AdvancedSettings(screen: self)
    }
}

struct GeneralSettings: View {
    let screen: SettingsScreen
    @AppStorage(AppearancePreferences.quitOnCloseKey) private var quitOnClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Window") {
                screen.row("Quit when the main window closes", "Off: Lay X keeps running so Mini Chat and the API server stay available") {
                    Toggle("", isOn: $quitOnClose).toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
            }
            screen.group("About") {
                screen.row("Version", nil) {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · MLX Swift 0.32.3")
                        .font(LX.F.mono(12)).foregroundStyle(LX.C.secondary)
                }
                screen.row("This Mac", nil) {
                    Text(HardwareInfo.current.summary).font(LX.F.mono(12)).foregroundStyle(LX.C.secondary)
                }
            }
        }
    }

}

struct PrivacySettings: View {
    let screen: SettingsScreen
    @State private var confirmDeleteAll = false
    @State private var databaseMessage: String?

    private func chooseDatabaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Database"
        panel.message = "Lay X keeps LayX.sqlite (pinned chats, benchmark results) directly in this folder."
        if let url = try? AppServices.databaseURL() { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { databaseMessage = await AppServices.shared.changeDatabaseLocation(to: folder) }
    }
    private var chats: ChatSessionStore { AppServices.shared.chats }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("How chats are kept") {
                screen.row("Temporary chats", "Kept in memory only. Never written to disk or logs; gone when Lay X quits") {
                    Text("\(chats.temporarySessions.filter { !$0.messages.isEmpty }.count) open").font(LX.F.mono(12)).foregroundStyle(LX.C.secondary)
                }
                screen.row("Pinned chats", "Saved on this Mac in a local database. Unpinning deletes the saved copy") {
                    Text("\(chats.pinnedSessions.count) saved").font(LX.F.mono(12)).foregroundStyle(LX.C.secondary)
                }
            }
            screen.group("Pinned chats") {
                ForEach(chats.pinnedSessions) { s in
                    screen.row(s.title, "\(s.messages.count) messages · pinned \(s.pinnedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")") {
                        HStack(spacing: 8) {
                            LXButton(title: "Open") {
                                AppState.shared.currentChatID = s.id
                                AppState.shared.screen = .chat
                            }
                            LXButton(title: "Unpin") { chats.setPinned(s.id, false) }
                            LXButton(title: "Delete", kind: .danger) { AppState.shared.deleteChat(s.id) }
                        }
                    }
                }
                if chats.pinnedSessions.isEmpty {
                    screen.row("No pinned chats", "Pin a chat with the ☆ button to keep it") { EmptyView() }
                }
            }
            if !chats.pinnedSessions.isEmpty {
                LXButton(title: "Delete all pinned chats…", kind: .danger) { confirmDeleteAll = true }
            }
            if let error = chats.persistenceError ?? AppServices.shared.databaseError {
                Text(error).font(LX.F.caption).foregroundStyle(LX.C.error)
            }
            screen.group("Storage") {
                screen.row("Database", "Pinned chats and benchmark results. Choosing a folder moves the database there (or uses one already there)") {
                    HStack(spacing: 8) {
                        let url = try? AppServices.databaseURL()
                        Text(((url?.deletingLastPathComponent().path ?? "—") as NSString).abbreviatingWithTildeInPath)
                            .font(LX.F.mono(11.5)).foregroundStyle(LX.C.accentText)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                            .help(url?.path ?? "")
                            .onTapGesture { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                        LXButton(title: "Choose…") { chooseDatabaseFolder() }
                        if !AppServices.shared.isDefaultDatabaseLocation {
                            LXButton(title: "Default") { Task { databaseMessage = await AppServices.shared.changeDatabaseLocation(to: nil) } }
                        }
                    }
                    .id(databaseMessage)
                }
            }
            if let databaseMessage {
                Text(databaseMessage).font(LX.F.caption).foregroundStyle(LX.C.secondary)
            }
        }
        .confirmationDialog("Delete all pinned chats?", isPresented: $confirmDeleteAll) {
            Button("Delete \(chats.pinnedSessions.count) chats", role: .destructive) {
                for s in chats.pinnedSessions { AppState.shared.deleteChat(s.id) }
            }
        } message: {
            Text("They are removed from this Mac. This can’t be undone.")
        }
    }
}

struct APISettings: View {
    let screen: SettingsScreen
    @State private var portText = ""
    private var api: APIServerModel { AppServices.shared.api }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Server") {
                screen.row("OpenAI-compatible server", api.isRunning ? "Running at \(api.baseURL)" : statusText) {
                    Toggle("", isOn: Binding(get: { api.isRunning || api.status == .starting }, set: { $0 ? api.start() : api.stop() }))
                        .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
                screen.row("Port", "1024–65535. Applied on Return") {
                    LXField(placeholder: "1234", text: $portText, mono: true).frame(width: 90)
                        .onAppear { portText = String(api.port) }
                        .onSubmit { if let p = Int(portText), (1024...65535).contains(p) { api.setPort(p) } else { portText = String(api.port) } }
                }
                screen.row("Require API key on localhost", "Always required when exposed on the local network") {
                    Toggle("", isOn: Binding(get: { api.requireKeyOnLocalhost }, set: { api.requireKeyOnLocalhost = $0 }))
                        .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
                screen.row("Allow model switching via the model field", nil) {
                    Toggle("", isOn: Binding(get: { api.allowModelSwitching }, set: { api.allowModelSwitching = $0 }))
                        .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
            }
            screen.group("Local network & keys") {
                screen.row("Local network", api.exposeLAN ? "Exposed on 0.0.0.0 (plain HTTP) — turn off in API Server" : "Off — localhost only. Enable from the API Server screen (asks every launch)") {
                    Text(api.exposeLAN ? "On" : "Off").font(LX.F.mono(12)).foregroundStyle(api.exposeLAN ? LX.C.warn : LX.C.secondary)
                }
                screen.row("API keys", "Stored as hashes in the macOS Keychain") {
                    HStack(spacing: 8) {
                        Text("\(api.keys.count)").font(LX.F.mono(12)).foregroundStyle(LX.C.secondary)
                        LXButton(title: "Manage…") { AppState.shared.screen = .api }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch api.status {
        case .failed(let m): m
        case .starting: "Starting…"
        default: "Stopped. Starts automatically at launch when on"
        }
    }
}

struct AdvancedSettings: View {
    let screen: SettingsScreen
    @State private var confirmReset = false
    @State private var kvBytes: Int64 = 0
    @State private var message: String?
    @Environment(InferenceStatusModel.self) private var inference

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Memory") {
                screen.row("Unload model", inference.loadedModel.map { "Frees \(ModelRepoID($0.id).map(ModelDisplay.name) ?? $0.id) from memory" } ?? "No model is loaded") {
                    LXButton(title: "Unload") { AppServices.shared.models.unload() }.disabled(inference.loadedModel == nil)
                }
                screen.row("Clear MLX buffer cache", inference.engineMemory.map { String(format: "%.2f GB cached", Double($0.cacheBytes) / 1_073_741_824) } ?? "—") {
                    LXButton(title: "Clear") { Task { await AppServices.shared.coordinator.clearCache() } }
                }
                screen.row("Conversation caches", String(format: "%.0f MB of reusable KV caches (memory only)", Double(kvBytes) / 1_048_576)) {
                    LXButton(title: "Discard") {
                        Task {
                            await AppServices.shared.coordinator.discardCaches(key: nil)
                            kvBytes = await AppServices.shared.coordinator.cacheBytes()
                        }
                    }
                }
                .task { kvBytes = await AppServices.shared.coordinator.cacheBytes() }
            }
            screen.group("Downloads") {
                let partial = AppServices.shared.models.incomplete
                screen.row("Incomplete downloads", partial.isEmpty ? "None" : "\(partial.count) · \(ModelDisplay.bytes(partial.reduce(0) { $0 + $1.bytes }))") {
                    LXButton(title: "Delete", kind: .danger) {
                        for p in partial { AppServices.shared.models.discardPartial(p.id) }
                        message = "Incomplete downloads removed."
                    }
                    .disabled(partial.isEmpty)
                }
            }
            screen.group("Reset") {
                screen.row("Reset settings", "Restores defaults for appearance, models, sampling, Soul, shortcut and API server. Chats, models and keys are kept") {
                    LXButton(title: "Reset…", kind: .danger) { confirmReset = true }
                }
            }
            if let message { Text(message).font(LX.F.caption).foregroundStyle(LX.C.secondary) }
            Text("Lay X writes no chat content to logs. Diagnostic logs (subsystem app.layx) contain only ids, counts and timings.")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { resetSettings() }
        }
    }

    private func resetSettings() {
        let d = UserDefaults.standard
        let keep: Set<String> = [WorkProjects.storageKey, ModelLibrary.lastUsedKey, AppServices.modelStorePathKey]
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("lx.") && !keep.contains(key) {
            d.removeObject(forKey: key)
        }
        GlobalHotKey.shared.set(.default)
        AppServices.shared.applyEngineSettings()
        message = "Settings were reset."
    }
}

struct WebSearchSettings: View {
    let screen: SettingsScreen
    @AppStorage(WebPreferences.modeKey) private var mode = WebSearchMode.off.rawValue
    @AppStorage(WebPreferences.providerKey) private var provider = WebSearchProvider.duckDuckGo.rawValue
    @AppStorage(WebPreferences.searxngURLKey) private var searxng = ""
    @AppStorage(WebPreferences.maxResultsKey) private var maxResults = 5
    @AppStorage(WebPreferences.pagesKey) private var pages = 3
    @State private var braveKey = ""
    @State private var hasBraveKey = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Chat") {
                screen.row("Web search", "Also switchable with the globe in the composer") {
                    Segmented(options: [(WebSearchMode.off.rawValue, "Off"), (WebSearchMode.auto.rawValue, "Auto"), (WebSearchMode.on.rawValue, "On")],
                              selection: $mode)
                }
            }
            screen.group("Search service") {
                screen.row("Provider", providerHelp) {
                    Segmented(options: WebSearchProvider.allCases.map { ($0.rawValue, $0.title) }, selection: $provider)
                }
                if provider == WebSearchProvider.brave.rawValue {
                    screen.row("Brave Search API key", hasBraveKey ? "Saved in the macOS Keychain" : "Get a key at api.search.brave.com — stored in the Keychain") {
                        HStack(spacing: 8) {
                            SecureField(hasBraveKey ? "••••••••" : "API key", text: $braveKey)
                                .textFieldStyle(.plain).font(LX.F.mono(12))
                                .padding(.horizontal, 10).frame(width: 220, height: LX.S.control)
                                .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
                            LXButton(title: "Save") {
                                hasBraveKey = WebPreferences.BraveKey.save(braveKey.trimmingCharacters(in: .whitespaces))
                                braveKey = ""
                            }
                            .disabled(braveKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            if hasBraveKey {
                                LXButton(title: "Remove", kind: .danger) { WebPreferences.BraveKey.remove(); hasBraveKey = false }
                            }
                        }
                    }
                }
                if provider == WebSearchProvider.searxng.rawValue {
                    screen.row("SearXNG URL", "Your instance, e.g. http://localhost:8888 (JSON format must be enabled)") {
                        LXField(placeholder: "https://searx.example", text: $searxng, mono: true).frame(width: 260)
                    }
                }
                screen.row("Results", "How many search results the model sees") {
                    Segmented(options: [(3, "3"), (5, "5"), (8, "8")], selection: $maxResults, mono: true)
                }
                screen.row("Pages to read", "Top results whose pages are opened and read (0 = snippets only)") {
                    Segmented(options: [(0, "0"), (2, "2"), (3, "3"), (5, "5")], selection: $pages, mono: true)
                }
                screen.row("Test", testResult ?? "Runs a sample search with the current settings") {
                    EmptyView().onAppear { if provider == WebSearchProvider.brave.rawValue { hasBraveKey = WebPreferences.BraveKey.cachedRead() != nil } }
                    LXButton(title: testing ? "Testing…" : "Run test") { runTest() }.disabled(testing)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(LX.C.accentText)
                Text("Web search only reads from the internet. Lay X sends the search query (written by the model from your latest message) to the selected service and downloads result pages with plain GET requests — no cookies, no uploads. Local files, project contents and chat history are never sent. Page content is treated as untrusted reference text.")
                    .font(LX.F.ui(12)).foregroundStyle(Color(hex: 0xC9CBD6)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LX.R.lg).fill(LX.C.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: LX.R.lg).strokeBorder(LX.C.accent.opacity(0.16), lineWidth: 1))
        }
    }

    private var providerHelp: String {
        switch WebSearchProvider(rawValue: provider) ?? .duckDuckGo {
        case .duckDuckGo: "No key needed. Uses DuckDuckGo’s HTML results page (unofficial; may change)"
        case .brave: "Official API with a free tier. Requires an API key"
        case .searxng: "Self-hosted metasearch. Most private option"
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                let current = WebPreferences.config
                let researcher = try WebResearcher(config: WebSearchConfig(
                    provider: current.provider, braveKey: current.braveKey,
                    searxngURL: current.searxngURL, maxResults: 3, pagesToRead: 1))
                let ctx = try await researcher.research("Apple Silicon MLX framework")
                testResult = "OK — \(ctx.sources.count) results, read \(ctx.pageText.count) page(s): \(ctx.sources.first?.host ?? "")"
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? "Test failed."
            }
        }
    }
}

// MARK: - Image Generation

struct ImageSettings: View {
    let screen: SettingsScreen
    @State private var storageMessage: String?
    @AppStorage(ImagePreferences.keepLoadedKey) private var keepLoaded = 5
    @AppStorage(ImagePreferences.makeRoomKey) private var makeRoom = true
    private var studio: ImageStudio { AppServices.shared.images }
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Memory") {
                screen.row("Keep the image model loaded", "Unloading frees about \(Int(Double(ImagePreferences.spec?.runtimeBytes(for: .init(1024, 1024)) ?? 0) / 1_073_741_824)) GB; loading again takes a few seconds") {
                    Picker("", selection: $keepLoaded) {
                        Text("Unload after each run").tag(0)
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("1 hour").tag(60)
                        Text("Until quit").tag(-1)
                    }
                    .labelsHidden().fixedSize()
                }
                screen.row("Make room automatically", "When memory is short, unload an idle chat model before loading the image model (and the other way round). Text and image generation never run at the same time") {
                    Toggle("", isOn: $makeRoom).toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
            }
            screen.group("Models") {
                screen.row("Image models", library.imageModels.isEmpty ? "None downloaded yet" : "\(library.imageModels.count) downloaded · they work offline") {
                    LXButton(title: "Manage in Models") {
                        AppState.shared.modelsKind = .image
                        AppState.shared.modelsTab = library.imageModels.isEmpty ? .discover : .installed
                        AppState.shared.screen = .models
                    }
                }
                screen.row("LoRAs", "\(studio.loraLibrary.count) added · .safetensors files for SDXL, Z-Image, FLUX.2 klein and Qwen-Image") {
                    if let folder = studio.loraFolder {
                        LXButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
                screen.row("Wildcards", "Text files for __name__ in prompts (name.txt, one option per line)") {
                    if let folder = studio.wildcardsFolder {
                        LXButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
            screen.group("Images") {
                screen.row("Saved images", "\(studio.history.count) image\(studio.history.count == 1 ? "" : "s") · PNG files on this Mac") {
                    if let folder = studio.imagesFolder {
                        LXButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
            screen.group("Storage") {
                screen.row("Image models", library.hasSeparateImageStorage
                           ? "Their own folder. Models already downloaded elsewhere stay there (switch back to use them)"
                           : "Same folder as the chat models (Settings → Models & Inference)") {
                    folderControl(library.imageStore.root, isDefault: !library.hasSeparateImageStorage,
                                  choose: { url in storageMessage = library.changeImageStorage(to: url) ?? "Image models will be saved there." },
                                  reset: { storageMessage = library.changeImageStorage(to: nil) ?? "Image models use the model folder again." })
                }
                screen.row("LoRAs", "Choosing a folder moves the LoRA files there") {
                    folderControl(studio.loraFolder, isDefault: UserDefaults.standard.string(forKey: AppServices.loraFolderKey) == nil,
                                  choose: { url in Task { storageMessage = await AppServices.shared.changeLoRAFolder(to: url) } },
                                  reset: { Task { storageMessage = await AppServices.shared.changeLoRAFolder(to: nil) } })
                }
                screen.row("Generated images", "Choosing a folder moves the saved PNGs there; the history follows") {
                    folderControl(studio.imagesFolder, isDefault: UserDefaults.standard.string(forKey: AppServices.imagesFolderKey) == nil,
                                  choose: { url in Task { storageMessage = await AppServices.shared.changeImagesFolder(to: url) } },
                                  reset: { Task { storageMessage = await AppServices.shared.changeImagesFolder(to: nil) } })
                }
            }
            if let storageMessage {
                Text(storageMessage).font(LX.F.caption).foregroundStyle(LX.C.secondary)
            }
        }
    }
}

extension ImageSettings {
    /// Path (click = show in Finder) + Choose… + Default.
    @ViewBuilder func folderControl(_ url: URL?, isDefault: Bool, choose: @escaping (URL) -> Void, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(((url?.path ?? "—") as NSString).abbreviatingWithTildeInPath)
                .font(LX.F.mono(11.5)).foregroundStyle(LX.C.accentText)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                .help(url?.path ?? "")
                .onTapGesture { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            LXButton(title: "Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = url
                panel.prompt = "Use Folder"
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                choose(chosen)
            }
            if !isDefault { LXButton(title: "Default") { reset() } }
        }
    }
}
