import Charts
import SwiftUI
import LayXCore

/// Performance → Live: what the model is doing now and how fast it has been, in plain words.
/// Numbers only (this session) — never any chat content.
struct PerformanceLiveView: View {
    @Environment(InferenceStatusModel.self) private var inference
    private let gb = 1_073_741_824.0

    var body: some View {
        let recent = Array(inference.history.prefix(30))
        let last = recent.first
        VStack(alignment: .leading, spacing: 14) {
            nowCard(last)
            HStack(alignment: .top, spacing: 10) {
                speedCard(last, recent: recent)
                startCard(last, recent: recent)
                readCard(last, recent: recent)
            }
            HStack(alignment: .top, spacing: 10) {
                historyChart(recent).frame(maxWidth: .infinity)
                memoryCard.frame(width: 300)
            }
            recentList(recent)
        }
    }

    // MARK: Now

    private func nowCard(_ last: InferenceStatusModel.LiveSample?) -> some View {
        let snapshot = inference.snapshot
        let loading: String? = { if case .loading(let id, _) = snapshot.model { id } else { nil } }()
        let modelID = inference.loadedModel?.id ?? loading
        let busy = snapshot.activeClient != nil
        let (title, color): (String, Color) = {
            if loading != nil { return ("Loading the model…", LX.C.warn) }
            if let client = snapshot.activeClient {
                var t = "Generating for \(Self.sourceName(client))"
                if let paused = snapshot.pausedClient { t += " · \(Self.sourceName(paused)) paused" }
                if snapshot.queuedCount > 0 { t += " · \(snapshot.queuedCount) waiting" }
                return (t, LX.C.liveCyan)
            }
            if inference.loadedModel != nil { return ("Ready", LX.C.ok) }
            return ("No model loaded", LX.C.tertiary)
        }()
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.14)).frame(width: 40, height: 40)
                if busy || loading != nil {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: inference.loadedModel != nil ? "checkmark" : "moon.zzz")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if busy { LiveStatusText(text: title, font: LX.F.ui(15, .semibold)) }
                else { Text(title).font(LX.F.ui(15, .semibold)).foregroundStyle(LX.C.primary) }
                Text(modelID.flatMap(ModelRepoID.init).map(ModelDisplay.name).map { "Model: \($0)" } ?? "Load a model in Models or start a chat")
                    .font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
            }
            Spacer()
            if let last {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Last reply").font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                    Text(Self.summary(last.metrics)).font(LX.F.ui(12.5)).foregroundStyle(LX.C.body)
                }
            }
        }
        .padding(16)
        .well()
    }

    // MARK: Three plain-language cards

    private func speedCard(_ last: InferenceStatusModel.LiveSample?, recent: [InferenceStatusModel.LiveSample]) -> some View {
        let tps = last?.metrics.decodeTokensPerSecond
        let rating: (String, Color)? = tps.map {
            $0 >= 60 ? ("Very fast", LX.C.ok) : $0 >= 25 ? ("Fast", LX.C.ok) : $0 >= 10 ? ("OK", LX.C.warn) : ("Slow", LX.C.error)
        }
        return StatCard(
            title: "Writing speed", symbol: "pencil.line",
            value: tps.map { String(format: "%.0f", $0) } ?? "—", unit: "tokens/s",
            rating: rating,
            explanation: tps.map { String(format: "≈ %.0f words per second — you read about 4–5", $0 * 0.75) }
                ?? "How fast replies are written once they start",
            spark: recent.reversed().compactMap(\.metrics.decodeTokensPerSecond))
    }

    private func startCard(_ last: InferenceStatusModel.LiveSample?, recent: [InferenceStatusModel.LiveSample]) -> some View {
        let ms = last?.metrics.timeToFirstToken.milliseconds
        let rating: (String, Color)? = ms.map {
            $0 < 300 ? ("Instant", LX.C.ok) : $0 < 1000 ? ("Quick", LX.C.ok) : $0 < 3000 ? ("Noticeable", LX.C.warn) : ("Slow", LX.C.error)
        }
        return StatCard(
            title: "Response start", symbol: "timer",
            value: ms.map { $0 < 1000 ? String(format: "%.0f", $0) : String(format: "%.1f", $0 / 1000) } ?? "—",
            unit: (ms ?? 0) < 1000 ? "ms" : "s",
            rating: rating,
            explanation: ms != nil ? "Wait from sending until the first word appears" : "Time until the first word appears",
            spark: recent.reversed().map(\.metrics.timeToFirstToken.milliseconds),
            lowerIsBetter: true)
    }

    private func readCard(_ last: InferenceStatusModel.LiveSample?, recent: [InferenceStatusModel.LiveSample]) -> some View {
        let m = last?.metrics
        let tps = m?.prefillTokensPerSecond
        let cached = m?.cachedPromptTokens ?? 0
        let explanation: String = {
            guard let m else { return "How fast your message and history are read" }
            var s = "Read \(m.promptTokens) new tokens"
            if cached > 0 { s += " · \(cached) reused from cache" }
            if let tps { s += String(format: " · ≈ %.0f pages/s", tps / 500) }
            return s
        }()
        return StatCard(
            title: "Reading speed", symbol: "text.viewfinder",
            value: tps.map { String(Int($0)) } ?? "—", unit: "tokens/s",
            rating: cached > 0 ? ("Cache hit", LX.C.liveCyan) : nil,
            explanation: explanation,
            spark: recent.reversed().compactMap(\.metrics.prefillTokensPerSecond))
    }

    // MARK: Chart

    private func historyChart(_ recent: [InferenceStatusModel.LiveSample]) -> some View {
        let items = Array(recent.reversed().enumerated())
        let sources = Array(Set(recent.map { Self.sourceName($0.client) })).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Writing speed of recent replies").font(LX.F.ui(13, .semibold))
                Text("tokens/s · taller is faster").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                Spacer()
                ForEach(sources, id: \.self) { s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.sourceColor(s)).frame(width: 8, height: 8)
                        Text(s)
                    }
                    .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
                }
            }
            if items.isEmpty {
                Text("Send a message in Chat, Work or through the API — each reply adds a bar here.")
                    .font(LX.F.body).foregroundStyle(LX.C.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(items, id: \.element.id) { i, s in
                    BarMark(x: .value("Reply", i), y: .value("tok/s", s.metrics.decodeTokensPerSecond ?? 0), width: .ratio(0.7))
                        .foregroundStyle(Self.sourceColor(Self.sourceName(s.client)).gradient)
                        .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                        AxisValueLabel().font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Writing speed of the last \(items.count) replies")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    // MARK: Memory

    private var memoryCard: some View {
        let total = Double(HardwareInfo.current.memoryBytes)
        let model = Double(inference.engineMemory?.activeBytes ?? 0)
        let cache = Double(inference.engineMemory?.cacheBytes ?? 0)
        let used = Double(inference.systemMemoryUsed ?? 0)
        let other = max(used - model - cache, 0)
        let free = max(total - used, 0)
        let parts: [(String, Double, AnyShapeStyle)] = [
            ("Model", model, AnyShapeStyle(LX.C.liveGradient)),
            ("Cache", cache, AnyShapeStyle(Color(hex: 0x5D63B8))),
            ("Other apps", other, AnyShapeStyle(Color(hex: 0x3A3D4E))),
            ("Free", free, AnyShapeStyle(Color.white.opacity(0.07))),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(LX.F.ui(13, .semibold))
                Spacer()
                Text(String(format: "%.0f of %.0f GB free", free / gb, total / gb)).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.2).frame(width: max(0, geo.size.width * p.1 / max(total, 1) - 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                        Text(p.0).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
                        Spacer()
                        Text(String(format: "%.1f GB", p.1 / gb)).font(LX.F.mono(11.5)).foregroundStyle(LX.C.body)
                    }
                }
            }
            if let peak = inference.engineMemory?.peakBytes, peak > 0 {
                Text(String(format: "Peak while generating: %.1f GB", Double(peak) / gb)).font(LX.F.caption).foregroundStyle(LX.C.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    // MARK: Recent list

    private func recentList(_ recent: [InferenceStatusModel.LiveSample]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT REPLIES").font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
                .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            if recent.isEmpty {
                Text("Numbers from Chat, Mini Chat, Work and API replies appear here (this session only, no content).")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(14)
            }
            ForEach(recent.prefix(12)) { s in
                let source = Self.sourceName(s.client)
                HStack(spacing: 10) {
                    Text(s.date.formatted(date: .omitted, time: .shortened)).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(source).font(LX.F.ui(11, .semibold)).foregroundStyle(Self.sourceColor(source))
                        .padding(.horizontal, 7).frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: LX.R.xs).fill(Self.sourceColor(source).opacity(0.14)))
                        .frame(width: 92, alignment: .leading)
                    Text(ModelRepoID(s.modelID).map(ModelDisplay.name) ?? s.modelID).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.summary(s.metrics)).foregroundStyle(LX.C.secondary).lineLimit(1)
                    if s.metrics.stopReason != .endOfSequence {
                        Text(Self.stopText(s.metrics.stopReason)).font(LX.F.mono(10.5)).foregroundStyle(LX.C.warn)
                    }
                }
                .font(LX.F.bodySmall).foregroundStyle(LX.C.body)
                .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            }
        }
        .well()
    }

    // MARK: Helpers

    static func summary(_ m: GenerationMetrics) -> String {
        var s = "\(m.generatedTokens) tokens in \(String(format: "%.1f", m.totalDuration.seconds)) s"
        if let tps = m.decodeTokensPerSecond { s += String(format: " · %.0f tok/s", tps) }
        s += String(format: " · first word %.0f ms", m.timeToFirstToken.milliseconds)
        return s
    }

    static func stopText(_ r: GenerationMetrics.StopReason) -> String {
        switch r {
        case .endOfSequence: "done"
        case .maxTokens: "length limit"
        case .cancelled: "stopped"
        case .contextLimit: "context full"
        case .error: "error"
        }
    }

    static func sourceName(_ c: InferenceClient) -> String {
        ["chat": "Chat", "miniChat": "Mini Chat", "work": "Work", "api": "API", "benchmark": "Benchmark", "image": "Image"][c.rawValue] ?? c.rawValue
    }

    static func sourceColor(_ name: String) -> Color {
        switch name {
        case "Chat": LX.C.accentText
        case "Mini Chat": Color(hex: 0xC59BFF)
        case "Work": Color(hex: 0x8EE6B4)
        case "API": LX.C.liveCyan
        default: LX.C.secondary
        }
    }
}

/// A big number with a plain-language rating and one sentence of explanation.
struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    let rating: (String, Color)?
    let explanation: String
    let spark: [Double]
    var lowerIsBetter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(LX.C.accentText)
                Text(title).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.secondary)
                Spacer()
                if let rating {
                    Text(rating.0).font(LX.F.ui(11, .semibold)).foregroundStyle(rating.1)
                        .padding(.horizontal, 7).frame(height: 19)
                        .background(Capsule().fill(rating.1.opacity(0.14)))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(LX.F.ui(30, .semibold)).kerning(-0.6).foregroundStyle(LX.C.primary)
                    .contentTransition(.numericText())
                Text(unit).font(LX.F.mono(11.5)).foregroundStyle(LX.C.tertiary)
                Spacer(minLength: 6)
                if spark.count > 1 {
                    let lo = spark.min() ?? 0, hi = spark.max() ?? 1
                    let pad = max((hi - lo) * 0.3, hi * 0.05, 0.001)
                    Chart(Array(spark.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("i", i), y: .value("v", v))
                            .foregroundStyle(LinearGradient(colors: [LX.C.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("i", i), y: .value("v", v))
                            .foregroundStyle(LX.C.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .frame(width: 90, height: 30)
                    .accessibilityHidden(true)
                }
            }
            Text(explanation).font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }
}
