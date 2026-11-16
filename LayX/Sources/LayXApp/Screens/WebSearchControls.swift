import AppKit
import SwiftUI
import LayXCore

/// Globe control in the composer: Off / Auto / On. Quiet chip, whole frame clickable.
struct WebSearchMenu: View {
    @AppStorage(WebPreferences.modeKey) private var raw = WebSearchMode.off.rawValue
    @State private var hover = false
    private var mode: WebSearchMode { WebSearchMode(rawValue: raw) ?? .off }

    var body: some View {
        Menu {
            ForEach([WebSearchMode.on, .auto, .off]) { m in
                Button { raw = m.rawValue } label: {
                    if m == mode { Label(title(m), systemImage: "checkmark") } else { Text(title(m)) }
                }
            }
            Divider()
            Text("Only the search query is sent to \(WebPreferences.config.provider.title). Files and chats are never uploaded.")
            Button("Web Search Settings…") {
                AppState.shared.settingsCategory = .web
                AppState.shared.screen = .settings
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode == .off ? "globe" : "globe.americas.fill").font(.system(size: 11, weight: .medium))
                if mode != .off { Text(mode == .on ? "Web" : "Auto") }
            }
            .font(LX.F.caption)
            .foregroundStyle(mode == .off ? (hover ? LX.C.primary : LX.C.secondary) : LX.C.accentText)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: LX.R.sm, style: .continuous)
                .fill(mode == .off ? Color.white.opacity(hover ? 0.06 : 0) : LX.C.accent.opacity(hover ? 0.16 : 0.11)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help("Web search: \(mode.title)")
    }

    private func title(_ m: WebSearchMode) -> String {
        switch m {
        case .on: "On — search for every message"
        case .auto: "Auto — search when the model thinks it’s needed"
        case .off: "Off"
        }
    }
}

/// Numbered sources under a reply ([1] host — title). Opens in the default browser.
struct WebSourcesView: View {
    let sources: [WebSource]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(LX.M.hover) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 10))
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                    Button { open(s.url) } label: {
                        HStack(spacing: 8) {
                            Text("[\(i + 1)]").font(LX.F.mono(11)).foregroundStyle(LX.C.accentText)
                            Text(s.host).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
                            Text(s.title).font(LX.F.ui(12)).foregroundStyle(LX.C.body).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(LX.C.tertiary)
                        }
                        .padding(.horizontal, 8).frame(height: 26)
                    }
                    .buttonStyle(QuietButtonStyle(radius: LX.R.sm))
                    .help(s.url.absoluteString)
                }
            } else {
                // Compact chips.
                HStack(spacing: 6) {
                    ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { i, s in
                        Button { open(s.url) } label: {
                            Text("\(i + 1) \(s.host)").font(LX.F.mono(10.5)).lineLimit(1)
                                .padding(.horizontal, 7).frame(height: 22)
                        }
                        .buttonStyle(QuietButtonStyle(radius: LX.R.sm))
                        .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(Color.white.opacity(0.04)))
                        .help("\(s.title)\n\(s.url.absoluteString)")
                    }
                }
            }
        }
    }

    private func open(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
