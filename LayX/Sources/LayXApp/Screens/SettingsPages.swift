import AppKit
import ServiceManagement
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            screen.group("Startup") {
                screen.row("Open at login", "Start Lay X when you log in (Mini Chat and the API server become available)") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLogin($0) }))
                        .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
            }
            if let loginError { Text(loginError).font(LX.F.caption).foregroundStyle(LX.C.error) }
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

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn’t allow this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct PrivacySettings: View {
    let screen: SettingsScreen
    @State private var confirmDeleteAll = false
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
                screen.row("Database", "Pinned chats and benchmark results") {
                    HStack(spacing: 8) {
                        Text("~/Library/Application Support/Lay X").font(LX.F.mono(11.5)).foregroundStyle(LX.C.accentText)
                        LXButton(title: "Show") {
                            if let url = try? LayXSchema.defaultURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
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
