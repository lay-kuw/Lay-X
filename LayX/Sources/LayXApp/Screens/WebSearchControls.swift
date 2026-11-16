import AppKit
import SwiftUI
import LayXCore

/// Globe control in the composer: click cycles Off → Auto → On. Auto uses the accent colour (like Thinking);
/// On uses the live cyan so it's clear every message goes to the web.
struct WebSearchMenu: View {
    @AppStorage(WebPreferences.modeKey) private var raw = WebSearchMode.off.rawValue
    @State private var hover = false
    private var mode: WebSearchMode { WebSearchMode(rawValue: raw) ?? .off }

    var body: some View {
        Button {
            switch mode {
            case .off: raw = WebSearchMode.auto.rawValue
            case .auto: raw = WebSearchMode.on.rawValue
            case .on: raw = WebSearchMode.off.rawValue
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode == .off ? "globe" : "globe.americas.fill").font(.system(size: 11, weight: .medium))
                Text(mode == .off ? "Web off" : (mode == .on ? "Web on" : "Web auto"))
            }
            .font(LX.F.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: LX.R.sm, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help("Web search: \(mode.title) — click to switch (Off → Auto → On). Only the search query is sent to \(WebPreferences.config.provider.title); files and chats are never uploaded.")
        .contextMenu {
            Button("Web Search Settings…") {
                AppState.shared.settingsCategory = .web
                AppState.shared.screen = .settings
            }
        }
    }

    private var color: Color {
        switch mode {
        case .off: hover ? LX.C.primary : LX.C.secondary
        case .auto: LX.C.accentText
        case .on: LX.C.liveCyan
        }
    }

    private var background: Color {
        switch mode {
        case .off: Color.white.opacity(hover ? 0.06 : 0)
        case .auto: LX.C.accent.opacity(hover ? 0.16 : 0.11)
        case .on: LX.C.liveCyan.opacity(hover ? 0.17 : 0.12)
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
