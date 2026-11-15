import SwiftUI
import Combine

struct ModelsScreen: View {
    enum Tab: Hashable { case installed, discover, downloads }
    @State private var tab: Tab = .installed
    @State private var filter = ""
    @State private var selection: LocalModel.ID? = Mock.models.first?.id
    @State private var progress = 0.62
    @State private var paused = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var selected: LocalModel? { Mock.models.first { $0.id == selection } }
    private var filtered: [LocalModel] {
        filter.isEmpty ? Mock.models : Mock.models.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Models").font(LX.F.title)
                Segmented(options: [(Tab.installed, "Installed"), (.discover, "Discover"), (.downloads, "Downloads")], selection: $tab)
                    .padding(.leading, 10)
            } trailing: {
                LXField(placeholder: "Filter or paste HF repo", text: $filter, symbol: "magnifyingglass").frame(width: 220)
                LXButton(title: "Add model", symbol: "plus", shortcut: "⌘⇧N", kind: .primary) {}
            }

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        storage
                        table
                        download
                    }
                    .padding(16)
                }
                Rectangle().fill(LX.C.divider).frame(width: 1)
                details.frame(width: 320)
            }
        }
        .onReceive(timer) { _ in
            guard !paused else { return }
            progress = progress >= 1 ? 0.2 : progress + 0.004
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionLabel(text: "Storage").fixedSize()
                (Text("98.2 GB").foregroundStyle(LX.C.primary) + Text(" used by models · 312 GB free").foregroundStyle(LX.C.tertiary))
                    .font(LX.F.mono(12))
                Spacer()
                Text("~/Library/Application Support/LayX/Models").font(LX.F.mono(11)).foregroundStyle(LX.C.accentText)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(LX.C.series[0]).frame(width: geo.size.width * 0.096)
                    Rectangle().fill(LX.C.series[1]).frame(width: geo.size.width * 0.042)
                    Rectangle().fill(LX.C.series[2]).frame(width: geo.size.width * 0.038)
                    Rectangle().fill(Color.white.opacity(0.22)).frame(width: geo.size.width * 0.08)
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 8)
            HStack(spacing: 16) {
                legend(LX.C.series[0], "Llama 3.3 70B · 39.7")
                legend(LX.C.series[1], "Qwen3 30B-A3B · 17.2")
                legend(LX.C.series[2], "Gemma 3 27B · 15.6")
                legend(Color.white.opacity(0.22), "Other 3 · 25.7")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8); Text(t) }
            .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                th("Model", .leading).frame(maxWidth: .infinity, alignment: .leading)
                th("Params", .leading).frame(width: 90, alignment: .leading)
                th("Quant", .leading).frame(width: 80, alignment: .leading)
                th("Size", .trailing).frame(width: 80, alignment: .trailing)
                th("Context", .trailing).frame(width: 80, alignment: .trailing)
                th("tok/s", .trailing).frame(width: 70, alignment: .trailing)
                th("Used", .trailing).frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            ForEach(filtered) { m in
                let on = m.id == selection
                HStack(spacing: 0) {
                    HStack(spacing: 9) {
                        if m.loaded { LiveDot() } else { Color.clear.frame(width: 6, height: 6) }
                        Text(m.name).font(LX.F.ui(12.5, on ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(m.params).font(LX.F.mono(12)).frame(width: 90, alignment: .leading)
                    Tag(text: m.quant, color: Color(hex: 0xC9CBD6)).frame(width: 80, alignment: .leading)
                    Text(m.size).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                    Text(m.context).font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                    Text(String(format: "%.1f", m.tps)).font(LX.F.mono(12)).frame(width: 70, alignment: .trailing)
                    Text(m.used).font(LX.F.mono(12)).foregroundStyle(LX.C.tertiary).frame(width: 60, alignment: .trailing)
                }
                .foregroundStyle(LX.C.body)
                .padding(.horizontal, 12).frame(height: LX.S.tableRow)
                .background(LX.C.accent.opacity(on ? 0.08 : 0))
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { selection = m.id }
            }
        }
        .well()
        .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
    }

    private func th(_ t: String, _ a: HorizontalAlignment) -> some View {
        Text(t.uppercased()).font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
    }

    private var download: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").foregroundStyle(LX.C.liveCyan)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("gpt-oss-20b").font(LX.F.ui(12.5, .medium))
                    Text("mlx-community/gpt-oss-20b-MXFP4").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Spacer()
                    Text(String(format: "%.1f / 11.4 GB", 11.4 * progress)).font(LX.F.mono(11.5)).contentTransition(.numericText())
                    Text(paused ? "paused" : "84 MB/s").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule().fill(LX.C.liveGradient).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
            LXButton(title: paused ? "Resume" : "Pause") { paused.toggle() }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .well()
    }

    @ViewBuilder private var details: some View {
        if let m = selected {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(LX.F.ui(15, .semibold))
                    Text(m.repo).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                HStack(spacing: 6) {
                    if m.loaded { Tag(text: "LOADED", color: LX.C.ok) }
                    Tag(text: "TOOLS", color: Color(hex: 0xC9CBD6))
                    Tag(text: m.context == "128k" ? "LONG CTX" : "THINKING", color: Color(hex: 0xC9CBD6))
                }
                Text("Runs fully on-device with MLX. Numbers below come from your last benchmark on this Mac.")
                    .font(LX.F.bodySmall).foregroundStyle(LX.C.secondary).lineSpacing(3)
                VStack(spacing: 0) {
                    kv("Parameters", m.params)
                    kv("Quantization", m.quant)
                    kv("On disk", m.size)
                    kv("Max context", m.context)
                    kv("License", "see model card")
                }
                HStack(spacing: 8) {
                    stat(m.loaded ? "182ms" : "—", "TTFT")
                    stat(m.loaded ? "1,240" : "—", "Prefill")
                    stat(String(format: "%.1f", m.tps), "Decode")
                }
                .padding(12).well()
                Spacer()
                HStack(spacing: 8) {
                    LXButton(title: "Open in Chat", kind: .primary) { AppState.shared.screen = .chat }
                    LXButton(title: m.loaded ? "Unload" : "Load") {}
                    LXButton(title: "Delete", kind: .danger) {}
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
        } else {
            Text("Select a model").font(LX.F.body).foregroundStyle(LX.C.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(LX.C.secondary); Spacer(); Text(v).font(LX.F.mono(12)) }
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
