import AppKit
import Charts
import SwiftUI
import LayXCore
import LayXServer

struct APIServerScreen: View {
    @Environment(InferenceStatusModel.self) private var inference
    private var api: APIServerModel { AppServices.shared.api }
    @State private var portText = ""
    @State private var confirmLAN = false
    @State private var copied = false
    @State private var showDocs = false
    @State private var newKeyName = ""
    @State private var addingKey = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("API Server").font(LX.F.title)
                Text("OpenAI-compatible").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).padding(.leading, 6)
            } trailing: {
                LXButton(title: "Docs") { showDocs.toggle() }
                    .popover(isPresented: $showDocs, arrowEdge: .bottom) { docs }
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
        .onAppear { portText = String(api.port) }
        .alert("Expose on local network?", isPresented: $confirmLAN) {
            Button("Cancel", role: .cancel) {}
            Button("Expose") {
                if api.keys.isEmpty { api.createKey(name: "lan") }
                api.setLAN(true)
            }
        } message: {
            Text("Other devices on your network will be able to use this Mac’s models. Every request must send an API key. Traffic is plain HTTP: prompts, replies and keys are not encrypted on the network. LAN access turns off when Lay X quits.")
        }
    }

    // MARK: Status

    private var running: Bool { api.isRunning }

    private var statusText: (String, String) {
        switch api.status {
        case .running:
            let uptime = api.startedAt.map { Self.duration(Date().timeIntervalSince($0)) } ?? ""
            let model = inference.loadedModel.flatMap { ModelRepoID($0.id) }.map(ModelDisplay.name) ?? "no model loaded"
            return ("Running", "uptime \(uptime) · \(model)")
        case .starting: return ("Starting", "binding \(api.host):\(api.port)")
        case .stopped: return ("Stopped", "not listening")
        case .failed(let message): return ("Not running", message)
        }
    }

    private var statusBanner: some View {
        let failed = { if case .failed = api.status { true } else { false } }()
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if running { LiveDot() } else { Circle().fill(failed ? LX.C.error : LX.C.tertiary).frame(width: 6, height: 6) }
                    Text(statusText.0).font(LX.F.ui(15, .semibold))
                    Text(statusText.1).font(LX.F.mono(11)).foregroundStyle(failed ? LX.C.error : LX.C.tertiary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(api.baseURL).font(LX.F.mono(16)).foregroundStyle(running ? LX.C.primary : LX.C.tertiary).textSelection(.enabled)
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy base URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(api.baseURL, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
            }
            Spacer()
            HStack(spacing: 22) {
                bigStat(api.requests.count.formatted(), "requests · since start")
                bigStat(api.errorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", "errors")
                bigStat(api.p50Latency.map { $0 >= 1000 ? String(format: "%.1f s", $0 / 1000) : String(format: "%.0f ms", $0) } ?? "—", "p50 latency")
                bigStat(api.tokensOut >= 1000 ? String(format: "%.0fk", Double(api.tokensOut) / 1000) : "\(api.tokensOut)", "tokens out")
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 44)
            if running || api.status == .starting {
                LXButton(title: "Stop server", kind: .danger) { api.stop() }
                    .keyboardShortcut(".")
            } else {
                LXButton(title: "Start server", symbol: "play.fill", kind: .primary) { api.start() }
                    .keyboardShortcut(".")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(
            LinearGradient(colors: [(running ? LX.C.ok : (failed ? LX.C.error : LX.C.tertiary)).opacity(0.07), .clear],
                           startPoint: .leading, endPoint: UnitPoint(x: 0.4, y: 0.5))
        )
        .well()
    }

    private func bigStat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(LX.F.mono(20))
            Text(k).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary)
        }
    }

    // MARK: Network

    private var network: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Network")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Host").font(LX.F.bodySmall).foregroundStyle(LX.C.secondary).frame(width: 110, alignment: .leading)
                    Text(api.host).font(LX.F.mono(12.5)).foregroundStyle(LX.C.primary)
                        .padding(.horizontal, 10).frame(width: 260, height: LX.S.control, alignment: .leading)
                        .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
                        .help("127.0.0.1 = this Mac only. Turn on local network exposure to listen on all interfaces.")
                }
                GridRow {
                    Text("Port").font(LX.F.bodySmall).foregroundStyle(LX.C.secondary)
                    LXField(placeholder: "1234", text: $portText, mono: true).frame(width: 90)
                        .onSubmit { commitPort() }
                        .onChange(of: portText) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(5))
                            if digits != new { portText = digits }
                        }
                }
            }
            if let p = Int(portText), !(1024...65535).contains(p) {
                Text("Use a port between 1024 and 65535, then press Return.").font(LX.F.caption).foregroundStyle(LX.C.warn)
            }
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(LX.C.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expose on local network").font(LX.F.ui(12.5, .medium))
                    Text(api.exposeLAN
                         ? "On. Listening on 0.0.0.0 — API key required. Plain HTTP: traffic isn’t encrypted."
                         : "Off. Binding to 0.0.0.0 requires an API key and asks again on every launch.")
                        .font(LX.F.caption).foregroundStyle(LX.C.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { api.exposeLAN }, set: { new in if new { confirmLAN = true } else { api.setLAN(false) } }))
                    .toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                    .accessibilityLabel("Expose on local network")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(LX.C.warn.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LX.C.warn.opacity(0.18), lineWidth: 1))
            Toggle(isOn: Binding(get: { api.requireKeyOnLocalhost || api.exposeLAN }, set: { api.requireKeyOnLocalhost = $0 })) {
                Text("Require API key for localhost").font(LX.F.bodySmall)
            }
            .toggleStyle(LXToggleStyle())
            .disabled(api.exposeLAN)
            Toggle(isOn: Binding(get: { api.allowModelSwitching }, set: { api.allowModelSwitching = $0 })) {
                HStack(spacing: 4) {
                    Text("Allow model switching via").font(LX.F.bodySmall)
                    Text("model").font(LX.F.mono(12)).foregroundStyle(LX.C.accentText)
                    Text("field").font(LX.F.bodySmall)
                }
            }
            .toggleStyle(LXToggleStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func commitPort() {
        guard let p = Int(portText), (1024...65535).contains(p) else { return }
        api.setPort(p)
    }

    // MARK: Requests

    private var recent: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Recent requests")
                Spacer()
                Text(running ? "live · metadata only" : "paused").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 0) {
                Text("TIME").frame(width: 80, alignment: .leading)
                Text("").frame(width: 50, alignment: .leading)
                Text("PATH").frame(maxWidth: .infinity, alignment: .leading)
                Text("CLIENT").frame(width: 100, alignment: .leading)
                Text("STATUS").frame(width: 70, alignment: .leading)
                Text("LATENCY").frame(width: 70, alignment: .trailing)
                Text("TOK").frame(width: 50, alignment: .trailing)
            }
            .font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            ForEach(api.requests.prefix(12)) { r in
                let ok = r.status < 400
                HStack(spacing: 0) {
                    Text(r.date.formatted(date: .omitted, time: .standard)).foregroundStyle(LX.C.tertiary).frame(width: 80, alignment: .leading)
                    Text(r.method).foregroundStyle(LX.C.secondary).frame(width: 50, alignment: .leading)
                    Text(r.path + (r.stream ? " ⇢" : "")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(clientName(r)).font(LX.F.bodySmall).lineLimit(1).frame(width: 100, alignment: .leading)
                    HStack(spacing: 5) {
                        Image(systemName: ok ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                        Text("\(r.status)")
                    }
                    .foregroundStyle(ok ? LX.C.ok : LX.C.error)
                    .frame(width: 70, alignment: .leading)
                    Text(r.durationMs >= 1000 ? String(format: "%.2f s", r.durationMs / 1000) : String(format: "%.0f ms", r.durationMs))
                        .frame(width: 70, alignment: .trailing)
                    Text(r.completionTokens.map(String.init) ?? "–").frame(width: 50, alignment: .trailing)
                }
                .font(LX.F.mono(12)).foregroundStyle(LX.C.body)
                .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            }
            if api.requests.isEmpty {
                Text(running ? "Waiting for requests. Try: curl \(api.baseURL)/models" : "Start the server to accept requests.")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .well()
        .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
    }

    private func clientName(_ r: APIRequestRecord) -> String {
        let agent = r.userAgent?.split(separator: " ").first.map(String.init) ?? r.client
        return agent.split(separator: "/").first.map(String.init) ?? agent
    }

    // MARK: Traffic & clients

    private var traffic: some View {
        let perMinute = api.perMinute
        return VStack(alignment: .leading, spacing: 10) {
            HStack { SectionLabel(text: "Requests / min"); Spacer(); Text("last 24 min").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary) }
            Chart(Array(perMinute.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("min", i), y: .value("req", v), width: 10)
                    .foregroundStyle(LX.C.series[1].opacity(i == perMinute.count - 1 ? 1 : 0.6))
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, perMinute.max() ?? 1))
            .frame(height: 62)
            .accessibilityLabel("Requests per minute over the last 24 minutes")
            SectionLabel(text: "Connected clients").padding(.top, 8)
            ForEach(api.clients.prefix(5)) { c in
                HStack(spacing: 8) {
                    Circle().fill(Date().timeIntervalSince(c.lastSeen) < 300 ? LX.C.ok : LX.C.tertiary).frame(width: 6, height: 6)
                    Text(c.name).font(LX.F.body)
                    Text(c.agent).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                    Spacer()
                    Text("\(c.count.formatted()) req").font(LX.F.mono(11.5)).foregroundStyle(LX.C.secondary)
                }
                .frame(height: 30)
            }
            if api.clients.isEmpty {
                Text("No clients yet.").font(LX.F.caption).foregroundStyle(LX.C.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    // MARK: Keys

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "API keys")
                Spacer()
                LXButton(title: "New key", symbol: "plus") { addingKey = true; newKeyName = "" }
            }
            .padding(.bottom, 8)
            if addingKey {
                HStack(spacing: 8) {
                    LXField(placeholder: "Name (e.g. cursor)", text: $newKeyName).onSubmit { create() }
                    LXButton(title: "Create", kind: .primary) { create() }
                    LXButton(title: "Cancel") { addingKey = false }
                }
                .padding(.bottom, 8)
            }
            if let revealed = api.revealedKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New key “\(revealed.name)” — copy it now. It won’t be shown again.").font(LX.F.caption).foregroundStyle(LX.C.warn)
                    HStack(spacing: 6) {
                        Text(revealed.secret).font(LX.F.mono(11.5)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        IconButton(symbol: "doc.on.doc", help: "Copy key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(revealed.secret, forType: .string)
                        }
                        IconButton(symbol: "xmark", help: "Done") { api.revealedKey = nil }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(LX.C.warn.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LX.C.warn.opacity(0.18), lineWidth: 1))
                .padding(.bottom, 8)
            }
            ForEach(api.keys) { k in
                HStack(spacing: 10) {
                    Image(systemName: "key").font(.system(size: 11)).foregroundStyle(LX.C.accent)
                    Text(k.name).font(LX.F.ui(13, .medium))
                    Text("\(k.prefix)…").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Spacer()
                    Text(api.keyLastUsed[k.name].map { "used \(ModelDisplay.age($0)) ago" } ?? "never").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Menu {
                        Button("Rotate (new key, revoke this one)") { api.rotate(k) }
                        Button("Revoke", role: .destructive) { api.revoke(k.id) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(LX.C.error)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Revoke or rotate")
                }
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            }
            if let e = api.keyError {
                Text(e).font(LX.F.caption).foregroundStyle(LX.C.error).padding(.top, 8)
            }
            Text("Keys are stored as hashes in the macOS Keychain. Shown once on creation.")
                .font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary).padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private func create() {
        if api.createKey(name: newKeyName) { addingKey = false }
    }

    // MARK: Docs

    private var docs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Using the API").font(LX.F.ui(13, .semibold))
            Text("Point any OpenAI-compatible client at the base URL. Example:").font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
            Text("""
            curl \(api.baseURL)/chat/completions \\
              -H "Content-Type: application/json" \(api.configuration.requiresKey ? "\\\n  -H \"Authorization: Bearer $LAYX_KEY\" " : "")\\
              -d '{"model":"default","messages":[{"role":"user","content":"Hi"}],"stream":true}'
            """)
            .font(LX.F.mono(11)).textSelection(.enabled)
            .padding(10).well(radius: 8, fill: LX.C.code)
            Text("Supported: GET /v1/models, POST /v1/chat/completions (stream and non-stream), temperature, top_p, max_tokens, stop, seed, stream_options.include_usage, chat_template_kwargs.enable_thinking.")
                .font(LX.F.caption).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Not supported: tools / function calling, images, n > 1, logprobs, JSON mode, /v1/completions, /v1/embeddings. This is not a complete OpenAI API.")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520)
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}
