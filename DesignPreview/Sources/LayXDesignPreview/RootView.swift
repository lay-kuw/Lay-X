import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(LX.Glass.storageKey) private var transparency = LX.Glass.defaultValue
    @AppStorage(LX.Glow.storageKey) private var glowRaw = LX.Glow.violet.rawValue

    var body: some View {
        ZStack {
            Backdrop()
            HStack(spacing: LX.S.s2) {
                Sidebar()
                    .frame(width: LX.S.sidebar)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pane(radius: LX.R.xl, tint: LX.C.content)
                if state.inspector && state.screen == .chat {
                    InspectorPanel()
                        .frame(width: 288)
                        .pane(radius: LX.R.xl)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(LX.S.s2)
        }
        .foregroundStyle(LX.C.primary)
        .environment(\.glassTransparency, transparency)
        .environment(\.glowPreset, LX.Glow(rawValue: glowRaw) ?? .violet)
        .animation(.easeInOut(duration: 0.35), value: glowRaw)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch state.screen {
        case .chat: ChatScreen()
        case .work: WorkScreen()
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
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window controls: 12pt from the pane's left edge (8 pane padding + 4), 10pt from its top
            // (optically matches the left gap because the circles sit against the rounded corner).
            TrafficLights()
                .padding(.leading, 4)
                .padding(.top, 10)

            LXField(placeholder: "Search or command", text: $search, symbol: "magnifyingglass")
                .overlay(alignment: .trailing) { Keycap(text: "⌘K").padding(.trailing, 6) }
                .padding(.top, 20).padding(.bottom, 8)

            VStack(spacing: 1) {
                ForEach([Screen.chat, .work, .models, .performance, .api]) { screen in
                    NavRow(screen: screen, selected: state.screen == screen) { state.screen = screen }
                }
            }

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
            sectionHeader("Session", note: "· not saved")
            if !state.pinned {
                ListRow(symbol: "clock", title: state.chatTitle, meta: "now", selected: true)
            }
            ForEach(Mock.sessionChats) { ListRow(symbol: "clock", title: $0.title, meta: $0.age) }
            sectionHeader("Pinned")
            if state.pinned {
                ListRow(symbol: "pin", title: state.chatTitle, meta: "now", selected: true)
            }
            ForEach(Mock.pinnedChats) { ListRow(symbol: "pin", title: $0.title, meta: $0.age) }
        case .work:
            sectionHeader("Projects")
            ListRow(symbol: "folder", title: "lay-x-app", meta: "3", selected: true)
            ListRow(symbol: "folder", title: "mlx-bench", meta: "")
            ListRow(symbol: "folder", title: "docs-site", meta: "")
            ListRow(symbol: "plus", title: "Open folder…", meta: "⌘O")
        case .models:
            sectionHeader("Library")
            ListRow(symbol: "shippingbox", title: "Installed", meta: "6", selected: true)
            ListRow(symbol: "magnifyingglass", title: "Discover", meta: "")
            ListRow(symbol: "arrow.down.to.line", title: "Downloads", meta: "1")
        case .performance:
            sectionHeader("Runs")
            ListRow(symbol: nil, title: "Context sweep · 3 models", meta: "now", selected: true)
            ListRow(symbol: nil, title: "Qwen3 14B · 4 vs 8-bit", meta: "1d")
            ListRow(symbol: nil, title: "Cold start", meta: "3d")
        case .api:
            sectionHeader("Endpoints")
            ForEach(Self.endpoints.indices, id: \.self) { i in
                ListRow(symbol: nil, title: Self.endpoints[i].path, meta: Self.endpoints[i].count, mono: true)
            }
        case .settings:
            sectionHeader("Settings")
            ForEach(SettingsScreen.Category.allCases) { c in
                ListRow(symbol: nil, title: c.rawValue, meta: "", selected: c == state.settingsCategory)
                    .contentShape(Rectangle())
                    .onTapGesture { state.settingsCategory = c }
            }
        }
    }

    private static let endpoints: [(path: String, count: String)] = [
        ("/v1/chat/completions", "1.2k"), ("/v1/completions", "84"), ("/v1/embeddings", "310"), ("/v1/models", "42"),
    ]

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
                if screen == .api {
                    HStack(spacing: 6) { LiveDot(); Text(":1234").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan) }
                } else {
                    Text(screen == .settings ? "⌘," : "⌘\(String(screen.shortcut.character))")
                        .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                }
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
