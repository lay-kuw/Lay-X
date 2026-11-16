import AppKit
import SwiftUI
import LayXCore

struct RootView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(LX.Glass.storageKey) private var transparency = LX.Glass.defaultValue
    @AppStorage(AppearancePreferences.followReduceTransparencyKey) private var followReduce = true
    @AppStorage(LX.Glass.fullGlassKey) private var fullGlass = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LX.Glow.storageKey) private var glowRaw = LX.Glow.violet.rawValue

    var body: some View {
        ZStack {
            Backdrop()
            HStack(spacing: LX.S.s2) {
                Sidebar()
                    .frame(width: LX.S.sidebar)
                    .overlay { panelDismissCatcher }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pane(radius: LX.R.xl, tint: LX.C.content)
                if state.inspector && state.screen == .chat {
                    InspectorPanel()
                        .frame(width: 288)
                        .pane(radius: LX.R.xl)
                        .overlay { panelDismissCatcher }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(LX.S.s2)
        }
        .foregroundStyle(LX.C.primary)
        .environment(\.glassTransparency, followReduce && reduceTransparency ? 0 : transparency)
        .environment(\.fullGlass, fullGlass && !(followReduce && reduceTransparency))
        .environment(\.glowPreset, LX.Glow(rawValue: glowRaw) ?? .violet)
        .animation(.easeInOut(duration: 0.35), value: glowRaw)
        .onChange(of: state.screen) { _, _ in state.modelPanelOpen = false }
        .ignoresSafeArea()
    }

    /// While a model panel is open, a click on the sidebar (or inspector) only closes it, like a click on the
    /// screen's empty area does.
    @ViewBuilder private var panelDismissCatcher: some View {
        if state.modelPanelOpen {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(LX.M.mini) { state.modelPanelOpen = false } }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.screen {
        case .chat: ChatScreen()
        case .work: WorkScreen()
        case .image: ImageScreen()
        case .models: ModelsScreen()
        case .performance: PerformanceScreen()
        case .api: APIServerScreen()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window controls: 12pt from the pane's left edge (8 pane padding + 4), 10pt from its top
            // (optically matches the left gap because the circles sit against the rounded corner).
            TrafficLights()
                .padding(.leading, 4)
                .padding(.top, 10)

            VStack(spacing: 1) {
                ForEach([Screen.chat, .work, .image, .models, .performance, .api]) { screen in
                    NavRow(screen: screen, selected: state.screen == screen) {
                        // Clicking Chat while already in Chat starts a new chat.
                        if screen == .chat && state.screen == .chat { state.newChat() } else { state.screen = screen }
                    }
                }
            }
            .padding(.top, 20)

            contextual
                .padding(.top, 4)

            Spacer(minLength: 8)
            MemoryMeter()
            NavRow(screen: .settings, selected: state.screen == .settings) { state.screen = .settings }
                .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .pane()
    }

    @ViewBuilder private var contextual: some View {
        switch state.screen {
        case .chat:
            let chats = AppServices.shared.chats
            sectionHeader("Session", note: "· not saved")
            ForEach(chats.temporarySessions.filter { !$0.messages.isEmpty }) { chatRow($0, symbol: "clock", quickDelete: true) }
            sectionHeader("Pinned")
            ForEach(chats.pinnedSessions) { chatRow($0, symbol: "star") }
        case .work:
            let work = AppServices.shared.work
            sectionHeader("Projects")
            ForEach(work.projects) { project in
                let proposed = work.sessions[project.id]?.changeSet?.changes.count ?? 0
                let busy = work.sessions[project.id].map { $0.phase == .reading || $0.phase == .generating || $0.phase == .applying } ?? false
                ListRow(symbol: busy ? "ellipsis" : "folder", title: project.name, meta: proposed > 0 ? "\(proposed)" : "",
                        selected: project.id == work.currentID)
                    .contentShape(Rectangle())
                    .onTapGesture { work.currentID = project.id }
                    .help(project.path)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                        Divider()
                        Button("Remove from Lay X") { work.remove(project.id) }
                    }
            }
            ListRow(symbol: "plus", title: "Open folder…", meta: "")
                .contentShape(Rectangle())
                .onTapGesture { work.openFolder() }
        case .image:
            let images = AppServices.shared.images
            sectionHeader("Recent")
            ForEach(images.history.prefix(14)) { r in
                ListRow(symbol: "photo", title: r.prompt, meta: "", selected: r.id == images.selected?.id)
                    .contentShape(Rectangle())
                    .onTapGesture { images.selectedID = r.id }
            }
            if images.history.isEmpty {
                Text("No images yet").font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(.horizontal, 8)
            }
        case .models:
            sectionHeader("Library")
            let library = AppServices.shared.models
            libraryRow("shippingbox", "Installed", library.installed.isEmpty ? "" : "\(library.installed.count)", .installed)
            libraryRow("magnifyingglass", "Discover", "", .discover)
            libraryRow(library.activeDownloads.isEmpty ? "arrow.down.to.line" : "arrow.down.circle.fill", "Downloads", "", .downloads)
        case .performance:
            let perf = AppServices.shared.performance
            sectionHeader("Runs")
            ForEach(perf.results.prefix(30)) { r in
                ListRow(symbol: nil, title: r.title, meta: ModelDisplay.age(r.date), selected: r.id == perf.selected?.id)
                    .contentShape(Rectangle())
                    .onTapGesture { perf.selectedID = r.id }
                    .contextMenu {
                        Button("Export CSV…") { perf.exportCSV(r) }
                        Divider()
                        Button("Delete Run", role: .destructive) { perf.delete(r.id) }
                    }
            }
            if perf.results.isEmpty {
                Text("No runs yet").font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(.horizontal, 8)
            }
        case .api:
            let api = AppServices.shared.api!
            sectionHeader("Endpoints")
            ForEach(["/v1/chat/completions", "/v1/models"], id: \.self) { path in
                let n = api.count(path: path)
                ListRow(symbol: nil, title: path, meta: n == 0 ? "" : (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"), mono: true)
            }
        case .settings:
            sectionHeader("Settings")
            ForEach(SettingsScreen.Category.matching(state.settingsSearch)) { c in
                ListRow(symbol: nil, title: c.rawValue, meta: "", selected: c == state.settingsCategory)
                    .contentShape(Rectangle())
                    .onTapGesture { state.settingsCategory = c }
            }
        }
    }

    private func chatRow(_ session: ChatSession, symbol: String, quickDelete: Bool = false) -> some View {
        let chats = AppServices.shared.chats
        return ChatListRow(symbol: chats.isGenerating(session.id) ? "ellipsis" : symbol, title: session.title,
                           selected: session.id == state.currentChatID,
                           onDelete: quickDelete ? { withAnimation(LX.M.hover) { state.deleteChat(session.id) } } : nil)
            .contentShape(Rectangle())
            .onTapGesture { state.currentChatID = session.id }
            .contextMenu {
                Button("Rename…") {
                    state.currentChatID = session.id
                    state.renamingChat = true
                }
                .disabled(session.messages.isEmpty)
                Button(session.isPinned ? "Unpin" : "Pin") { chats.togglePin(session.id) }
                    .disabled(session.messages.isEmpty)
                Divider()
                Button("Delete", role: .destructive) { state.deleteChat(session.id) }
            }
    }

    private func libraryRow(_ symbol: String, _ title: String, _ meta: String, _ tab: ModelsScreen.Tab) -> some View {
        ListRow(symbol: symbol, title: title, meta: meta, selected: state.modelsTab == tab)
            .contentShape(Rectangle())
            .onTapGesture { state.modelsTab = tab }
    }


    private func sectionHeader(_ title: String, note: String? = nil) -> some View {
        SectionLabel(text: title, trailing: note)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 6)
    }
}

struct NavRow: View {
    let screen: Screen
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? LX.C.accentText : LX.C.secondary)
                Text(screen.title).font(LX.F.body)
                Spacer()
                if screen == .api, let api = AppServices.shared.api, api.isRunning {
                    HStack(spacing: 6) { LiveDot(); Text(verbatim: ":\(api.port)").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan) }
                }
                if screen == .work { WorkActivityIndicator() }
                if screen == .image, AppServices.shared.images.isBusy { BusyIndicator(help: "Generating an image") }
                if screen == .chat, !AppServices.shared.chats.generating.isEmpty { BusyIndicator(help: "A reply is being generated") }
            }
            .foregroundStyle(selected ? Color.white : Color(hex: 0xC9CBD6))
            .padding(.horizontal, 8)
            .frame(height: LX.S.row)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: LX.R.md)
                    .fill(selected ? LX.C.accentTint : Color.white.opacity(hover ? 0.05 : 0))
                    .overlay(RoundedRectangle(cornerRadius: LX.R.md).strokeBorder(LX.C.accent.opacity(selected ? 0.18 : 0), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

struct ListRow: View {
    let symbol: String?
    let title: String
    let meta: String
    var selected = false
    var mono = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 13)
                    .foregroundStyle(selected ? LX.C.accent : LX.C.tertiary)
            }
            Text(title).font(mono ? LX.F.mono(12) : LX.F.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(meta).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
        }
        .foregroundStyle(selected ? Color.white : Color(hex: 0xC9CBD6))
        .padding(.horizontal, 8)
        .frame(height: LX.S.row)
        .background(RoundedRectangle(cornerRadius: LX.R.md).fill(Color.white.opacity(selected ? 0.07 : (hover ? 0.05 : 0))))
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

/// Work status in the sidebar: animated while a proposal is being read/written, a warm dot while changes
/// wait for approval, nothing when idle.
struct WorkActivityIndicator: View {
    var body: some View {
        let sessions = AppServices.shared.work.sessions.values
        if sessions.contains(where: { $0.phase == .reading || $0.phase == .generating || $0.phase == .applying }) {
            BusyIndicator(help: "Work is preparing a proposal")
        } else if sessions.contains(where: { $0.changeSet != nil }) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(LX.C.warn)
                .help("Changes are waiting for your approval")
        }
    }
}

/// Sidebar chat row. Temporary chats show a trash button on hover for one-click deletion.
struct ChatListRow: View {
    let symbol: String
    let title: String
    var selected = false
    var onDelete: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 13)
                .foregroundStyle(selected ? LX.C.accent : LX.C.tertiary)
            Text(title).font(LX.F.body).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if hover, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .buttonStyle(QuietButtonStyle(radius: LX.R.sm))
                .help("Delete chat")
                .transition(.opacity)
            }
        }
        .foregroundStyle(selected ? Color.white : Color(hex: 0xC9CBD6))
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: LX.S.row)
        .background(RoundedRectangle(cornerRadius: LX.R.md).fill(Color.white.opacity(selected ? 0.07 : (hover ? 0.05 : 0))))
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

// MARK: - Shared header

struct ScreenHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .frame(height: LX.S.header)
            Rectangle().fill(LX.C.divider).frame(height: 1)
        }
    }
}
