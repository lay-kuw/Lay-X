import SwiftUI
import Combine
import Charts

struct APIServerScreen: View {
    @State private var running = true
    @State private var host = "127.0.0.1"
    @State private var port = "1234"
    @State private var exposeLAN = false
    @State private var confirmLAN = false
    @State private var requireKey = true
    @State private var allowSwitch = true
    @State private var keys = Mock.keys
    @State private var requests = Mock.requests
    @State private var copied = false

    private let tick = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()
    private var baseURL: String { "http://\(exposeLAN ? "0.0.0.0" : host):\(port)/v1" }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("API Server").font(LX.F.title)
                Text("OpenAI-compatible").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).padding(.leading, 6)
            } trailing: {
                LXButton(title: "Docs") {}
            }
            ScrollView {
                VStack(spacing: 12) {
                    statusBanner
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) { network; recent }
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 12) { traffic; apiKeys }
                            .frame(width: 400)
                    }
                }
                .padding(16)
            }
        }
        .onReceive(tick) { _ in
            guard running else { return }
            let pool = Mock.requests
            var r = pool[Int.random(in: 0..<pool.count)]
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            r = APIRequest(time: f.string(from: Date()), method: r.method, path: r.path, client: r.client, status: r.status, latency: r.latency, tokens: r.tokens)
            withAnimation(LX.M.panel) {
                requests.insert(r, at: 0)
                if requests.count > 6 { requests.removeLast() }
            }
        }
        .alert("Expose on local network?", isPresented: $confirmLAN) {
            Button("Cancel", role: .cancel) {}
            Button("Expose") { exposeLAN = true }
        } message: {
            Text("Other devices on your network will be able to reach this Mac's models. An API key will be required for every request.")
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if running { LiveDot() } else { Circle().fill(LX.C.tertiary).frame(width: 6, height: 6) }
                    Text(running ? "Running" : "Stopped").font(LX.F.ui(15, .semibold))
                    Text(running ? "uptime 3h 12m · Qwen3 14B" : "not listening").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                HStack(spacing: 8) {
                    Text(baseURL).font(LX.F.mono(16)).foregroundStyle(running ? LX.C.primary : LX.C.tertiary).textSelection(.enabled)
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy base URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(baseURL, forType: .string)
                        copied = true
                    }
                }
            }
            Spacer()
            HStack(spacing: 22) {
                bigStat("1,636", "requests · 24h")
                bigStat("0.4%", "errors")
                bigStat("1.2 s", "p50 latency")
                bigStat("412k", "tokens out")
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 44)
            if running {
                LXButton(title: "Stop server", shortcut: "⌘.", kind: .danger) { withAnimation { running = false } }
                    .keyboardShortcut(".")
            } else {
                LXButton(title: "Start server", symbol: "play.fill", shortcut: "⌘.", kind: .primary) { withAnimation { running = true } }
                    .keyboardShortcut(".")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(
            LinearGradient(colors: [(running ? LX.C.ok : LX.C.tertiary).opacity(0.07), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.4, y: 0.5))
        )
        .well()
    }

    private func bigStat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(LX.F.mono(20))
            Text(k).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary)
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Network")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Host").font(LX.F.bodySmall).foregroundStyle(LX.C.secondary).frame(width: 110, alignment: .leading)
                    LXField(placeholder: "127.0.0.1", text: $host, mono: true).frame(width: 260).disabled(exposeLAN)
                }
                GridRow {
                    Text("Port").font(LX.F.bodySmall).foregroundStyle(LX.C.secondary)
                    LXField(placeholder: "1234", text: $port, mono: true).frame(width: 90)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(LX.C.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expose on local network").font(LX.F.ui(12.5, .medium))
                    Text(exposeLAN ? "On. Listening on 0.0.0.0 — API key required." : "Off. Binding to 0.0.0.0 requires an API key and asks again on every launch.")
                        .font(LX.F.caption).foregroundStyle(LX.C.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { exposeLAN }, set: { new in if new { confirmLAN = true } else { exposeLAN = false } }))
                    .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                    .accessibilityLabel("Expose on local network")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(LX.C.warn.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LX.C.warn.opacity(0.18), lineWidth: 1))
            Toggle(isOn: $requireKey) { Text("Require API key for localhost").font(LX.F.bodySmall) }.toggleStyle(LXToggleStyle())
            Toggle(isOn: $allowSwitch) { Text("Allow model switching via the model field").font(LX.F.bodySmall) }.toggleStyle(LXToggleStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private var recent: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Recent requests")
                Text(running ? "streaming · tail -f" : "paused").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 0) {
                Group {
                    Text("TIME").frame(width: 80, alignment: .leading)
                    Text("").frame(width: 50, alignment: .leading)
                    Text("PATH").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CLIENT").frame(width: 80, alignment: .leading)
                    Text("STATUS").frame(width: 70, alignment: .leading)
                    Text("LATENCY").frame(width: 70, alignment: .trailing)
                    Text("TOK").frame(width: 50, alignment: .trailing)
                }
            }
            .font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            ForEach(requests) { r in
                HStack(spacing: 0) {
                    Text(r.time).foregroundStyle(LX.C.tertiary).frame(width: 80, alignment: .leading)
                    Text(r.method).foregroundStyle(LX.C.secondary).frame(width: 50, alignment: .leading)
                    Text(r.path).frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.client).font(LX.F.bodySmall).frame(width: 80, alignment: .leading)
                    HStack(spacing: 5) {
                        Image(systemName: r.status == 200 ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                        Text("\(r.status)")
                    }
                    .foregroundStyle(r.status == 200 ? LX.C.ok : LX.C.error)
                    .frame(width: 70, alignment: .leading)
                    Text(r.latency).frame(width: 70, alignment: .trailing)
                    Text(r.tokens).frame(width: 50, alignment: .trailing)
                }
                .font(LX.F.mono(12)).foregroundStyle(LX.C.body)
                .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .well()
        .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { SectionLabel(text: "Requests / min"); Text("last 24 min").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary) }
            Chart(Array(Mock.requestsPerMinute.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("min", i), y: .value("req", v), width: 10)
                    .foregroundStyle(LX.C.series[1].opacity(i == Mock.requestsPerMinute.count - 1 ? 1 : 0.6))
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 62)
            .accessibilityLabel("Requests per minute over the last 24 minutes, peaking at 52")

            SectionLabel(text: "Connected clients").padding(.top, 6)
            client("Cursor", "openai-node/5.x", "1,184 req", active: true)
            client("Raycast", "raycast-ai/1.9", "402 req", active: true)
            client("curl", "curl/8.7", "50 req", active: false)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func client(_ name: String, _ ua: String, _ count: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(active ? LX.C.ok : LX.C.tertiary).frame(width: 6, height: 6)
            Text(name).font(LX.F.bodySmall)
            Text(ua).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            Spacer()
            Text(count).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
        }
        .frame(height: 28)
    }

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "API keys")
                LXButton(title: "New key", symbol: "plus") {
                    withAnimation { keys.append(APIKey(name: "key-\(keys.count + 1)", masked: "lx-sk-…\(String(Int.random(in: 4096...65535), radix: 16))", lastUsed: "never")) }
                }
            }
            ForEach(keys) { k in
                HStack(spacing: 10) {
                    Image(systemName: "key").font(.system(size: 12)).foregroundStyle(LX.C.accent)
                    Text(k.name).font(LX.F.ui(12.5, .medium))
                    Text(k.masked).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Spacer()
                    Text(k.lastUsed).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                    IconButton(symbol: "xmark", help: "Revoke \(k.name)") { withAnimation { keys.removeAll { $0.id == k.id } } }
                }
                .frame(height: 34)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            }
            Text("Keys are stored in the macOS Keychain and shown once on creation.").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }
}
