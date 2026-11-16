import Charts
import SwiftUI
import LayXCore

struct PerformanceScreen: View {
    enum Mode: Hashable { case live, benchmarks }
    @State private var mode: Mode = .benchmarks
    @State private var hoverContext: Int?
    @Environment(InferenceStatusModel.self) private var inference
    private var perf: PerformanceModel { AppServices.shared.performance }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Performance").font(LX.F.title)
                Text("\(HardwareInfo.current.summary) · MLX").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).padding(.leading, 6)
                    .lineLimit(1)
            } trailing: {
                Segmented(options: [(Mode.live, "Live"), (.benchmarks, "Benchmarks")], selection: $mode)
                LXButton(title: "Export CSV") { if let r = perf.selected { perf.exportCSV(r) } }
                    .disabled(perf.selected == nil)
                if perf.isRunning {
                    LXButton(title: "Stop", symbol: "stop.fill", kind: .primary) { perf.cancel() }
                        .keyboardShortcut(".")
                } else {
                    Menu {
                        Button("Quick — 2k prompt · gen 256 · 3 runs") { perf.run(.quick) }
                        Button("Context sweep — 1k to 32k · gen 128 · 2 runs") { perf.run(.contextSweep) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                            Text("Run benchmark")
                        }
                    } primaryAction: {
                        perf.run(.quick)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    .buttonStyle(LXButtonStyle(kind: .primary))
                    .keyboardShortcut("r")
                }
            }
            if perf.isRunning { GeneratingRibbon() }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let p = perf.progress, let config = perf.runningConfig {
                        HStack(spacing: 8) {
                            SectionLabel(text: "Running").fixedSize()
                            Text("\(config.label) · prompt \(p.promptTarget.formatted())\(p.warmup ? " · warm-up" : "") · \(p.step)/\(p.total)")
                                .font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
                        }
                    }
                    switch mode {
                    case .benchmarks: benchmarks
                    case .live: live
                    }
                }
                .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = perf.notice {
                Toast(text: notice).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if perf.notice == notice { perf.notice = nil }
                    }
            }
        }
        .animation(LX.M.panel, value: perf.notice)
    }

    // MARK: Benchmarks

    @ViewBuilder private var benchmarks: some View {
        if let run = perf.selected {
            HStack(spacing: 8) {
                SectionLabel(text: "Selected run").fixedSize()
                Text("\(ModelRepoID(run.modelID).map(ModelDisplay.name) ?? run.modelID)\(run.quantization.map { " · \($0)" } ?? "") · \(run.config.label)\(run.completed ? "" : " · partial")")
                    .font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).lineLimit(1)
            }
            kpis(run)
            chartCard
            comparison(run)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No benchmark runs yet").font(LX.F.ui(15, .semibold))
                Text("Run benchmark measures time to first token, prefill and decode speed on this Mac with a fixed synthetic prompt (no chat content). A context sweep measures decode speed from 1k to 32k tokens of context.")
                    .font(LX.F.body).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).well()
        }
    }

    private func kpis(_ run: BenchmarkResult) -> some View {
        let h = run.headline
        let samples = run.samples.filter { $0.promptTarget == h?.promptTarget }.map(\.metrics)
        let points = run.points
        let decodeDrop: String? = {
            guard points.count > 1, let first = points.first, let last = points.last, first.decodeMedian > 0 else { return nil }
            return String(format: "%+.0f%% at %@", (last.decodeMedian / first.decodeMedian - 1) * 100, BenchmarkConfig.k(last.promptTarget))
        }()
        return HStack(spacing: 10) {
            KPITile(label: "Time to first token", value: h.map { String(format: "%.0f", $0.ttftMedianMs) } ?? "—", unit: "ms",
                    note: h.map { String(format: "p50 · p95 %.0f ms", $0.ttftP95Ms) } ?? "",
                    spark: samples.map { $0.timeToFirstToken.milliseconds })
            KPITile(label: "Prefill", value: h.map { Int($0.prefillMedian).formatted() } ?? "—", unit: "tok/s",
                    note: h.map { "\(BenchmarkConfig.k($0.promptTokens)) prompt · median of \(samples.count)" } ?? "",
                    spark: samples.compactMap(\.prefillTokensPerSecond))
            KPITile(label: "Decode", value: h.map { String(format: "%.1f", $0.decodeMedian) } ?? "—", unit: "tok/s",
                    note: decodeDrop.map { "at \(BenchmarkConfig.k(points.first?.promptTarget ?? 0)) ctx · \($0)" } ?? "median of \(samples.count)",
                    spark: points.count > 1 ? points.map(\.decodeMedian) : samples.compactMap(\.decodeTokensPerSecond))
            KPITile(label: "Peak memory", value: run.peakMemoryBytes.map { String(format: "%.1f", Double($0) / 1_073_741_824) } ?? "—", unit: "GB",
                    note: run.weightBytes.map { String(format: "weights %.1f · load %.1f s", Double($0) / 1_073_741_824, run.loadDuration?.seconds ?? 0) } ?? "",
                    spark: [])
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        let sweeps = perf.sweeps
        let names = sweeps.map { ModelRepoID($0.modelID).map(ModelDisplay.name) ?? $0.modelID }
        let xs = Array(Set(sweeps.flatMap { $0.points.map(\.promptTarget) })).sorted()
        let maxY = max(10, (sweeps.flatMap { $0.points.map(\.decodeMedian) }.max() ?? 0) * 1.2)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Decode speed vs context length").font(LX.F.ui(13, .semibold))
                Text("tok/s · higher is better").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                Spacer()
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 6) { Rectangle().fill(LX.C.series[i]).frame(width: 10, height: 2); Text(name) }
                        .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
                }
            }
            if sweeps.isEmpty {
                Text("Run a context sweep to chart decode speed from 1k to 32k tokens of context. Up to three models are compared.")
                    .font(LX.F.body).foregroundStyle(LX.C.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart {
                    ForEach(Array(sweeps.enumerated()), id: \.offset) { i, run in
                        ForEach(run.points) { p in
                            LineMark(x: .value("Context", log2(Double(p.promptTarget))), y: .value("tok/s", p.decodeMedian))
                                .foregroundStyle(by: .value("Model", names[i]))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            PointMark(x: .value("Context", log2(Double(p.promptTarget))), y: .value("tok/s", p.decodeMedian))
                                .foregroundStyle(by: .value("Model", names[i]))
                                .symbolSize(30)
                        }
                    }
                    if let h = hoverContext {
                        RuleMark(x: .value("Context", log2(Double(h))))
                            .foregroundStyle(Color.white.opacity(0.22))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading, spacing: 0) { tooltip(for: h, sweeps: sweeps) }
                    }
                }
                .chartForegroundStyleScale(domain: names, range: Array(LX.C.series.prefix(max(names.count, 1))))
                .chartLegend(.hidden)
                .chartYScale(domain: 0...maxY)
                .chartXAxis {
                    AxisMarks(values: xs.map { log2(Double($0)) }) { v in
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(BenchmarkConfig.k(Int(pow(2, d)))).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
                        AxisValueLabel().font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard let frame = proxy.plotFrame else { return }
                                    let x = loc.x - geo[frame].origin.x
                                    if let v: Double = proxy.value(atX: x) {
                                        hoverContext = xs.min { abs(log2(Double($0)) - v) < abs(log2(Double($1)) - v) }
                                    }
                                case .ended:
                                    hoverContext = nil
                                }
                            }
                    }
                }
                .frame(height: 280)
                .accessibilityLabel("Decode tokens per second by context length")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func tooltip(for ctx: Int, sweeps: [BenchmarkResult]) -> some View {
        HStack(spacing: 12) {
            Text("\(BenchmarkConfig.k(ctx)) ctx").font(LX.F.mono(10.5)).foregroundStyle(LX.C.secondary)
            ForEach(Array(sweeps.enumerated()), id: \.offset) { i, run in
                if let p = run.points.first(where: { $0.promptTarget == ctx }) {
                    HStack(spacing: 6) {
                        Rectangle().fill(LX.C.series[i]).frame(width: 8, height: 2)
                        Text(String(format: "%.1f", p.decodeMedian)).font(LX.F.mono(11.5))
                    }
                }
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: LX.R.md).fill(LX.C.overlay))
        .overlay(RoundedRectangle(cornerRadius: LX.R.md).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
        .padding(.leading, 10)
    }

    // MARK: Comparison (same configuration only)

    private func comparison(_ selected: BenchmarkResult) -> some View {
        let rows = perf.comparable(to: selected.config.comparisonKey).prefix(6)
        let maxDecode = max(1, rows.compactMap { $0.headline?.decodeMedian }.max() ?? 1)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("MODEL COMPARISON · \(selected.config.comparisonKey.uppercased())").frame(maxWidth: .infinity, alignment: .leading)
                Text("TTFT").frame(width: 100, alignment: .trailing)
                Text("PREFILL TOK/S").frame(width: 130, alignment: .trailing)
                Text("DECODE TOK/S").frame(width: 300, alignment: .leading).padding(.leading, 30)
                Text("PEAK MEM").frame(width: 100, alignment: .trailing)
            }
            .font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                let h = row.headline
                let color = LX.C.series[i % LX.C.series.count]
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        Text(ModelRepoID(row.modelID).map(ModelDisplay.name) ?? row.modelID)
                        if let q = row.quantization { Text(q).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary) }
                        if let h { Text("\(BenchmarkConfig.k(h.promptTarget)) prompt").font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(h.map { String(format: "%.0f ms", $0.ttftMedianMs) } ?? "—").font(LX.F.mono(12)).frame(width: 100, alignment: .trailing)
                    Text(h.map { Int($0.prefillMedian).formatted() } ?? "—").font(LX.F.mono(12)).frame(width: 130, alignment: .trailing)
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(Color.white.opacity(0.05))
                                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(color).frame(width: geo.size.width * (h?.decodeMedian ?? 0) / maxDecode)
                            }
                        }
                        .frame(height: 6)
                        Text(h.map { String(format: "%.1f", $0.decodeMedian) } ?? "—").font(LX.F.mono(12)).frame(width: 48, alignment: .trailing)
                    }
                    .frame(width: 300).padding(.leading, 30)
                    Text(row.peakMemoryBytes.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "—")
                        .font(LX.F.mono(12)).frame(width: 100, alignment: .trailing)
                }
                .font(LX.F.bodySmall).foregroundStyle(LX.C.body)
                .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                .background(LX.C.accent.opacity(row.id == selected.id ? 0.06 : 0))
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { perf.selectedID = row.id }
            }
            Text("Only runs with the same generation settings are compared. Prompt sizes may differ; each row shows its headline prompt.")
                .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .well()
    }

    // MARK: Live

    private var live: some View {
        let last = inference.history.first
        let gb = 1_073_741_824.0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                KPITile(label: "Time to first token", value: last.map { String(format: "%.0f", $0.metrics.timeToFirstToken.milliseconds) } ?? "—",
                        unit: "ms", note: last.map { "\($0.metrics.promptTokens) prompt tokens" } ?? "no generation yet",
                        spark: inference.history.prefix(20).reversed().map { $0.metrics.timeToFirstToken.milliseconds })
                KPITile(label: "Prefill", value: last?.metrics.prefillTokensPerSecond.map { Int($0).formatted() } ?? "—",
                        unit: "tok/s", note: "last generation",
                        spark: inference.history.prefix(20).reversed().compactMap { $0.metrics.prefillTokensPerSecond })
                KPITile(label: "Decode", value: last?.metrics.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "tok/s", note: last.map { "\($0.metrics.generatedTokens) tokens" } ?? "",
                        spark: inference.history.prefix(20).reversed().compactMap { $0.metrics.decodeTokensPerSecond })
                KPITile(label: "MLX memory", value: inference.engineMemory.map { String(format: "%.1f", Double($0.activeBytes) / gb) } ?? "—",
                        unit: "GB", note: inference.engineMemory.map { String(format: "cache %.1f · peak %.1f", Double($0.cacheBytes) / gb, Double($0.peakBytes) / gb) } ?? "",
                        spark: [])
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("RECENT GENERATIONS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("SOURCE").frame(width: 90, alignment: .leading)
                    Text("PROMPT").frame(width: 80, alignment: .trailing)
                    Text("OUT").frame(width: 70, alignment: .trailing)
                    Text("TTFT").frame(width: 90, alignment: .trailing)
                    Text("DECODE").frame(width: 90, alignment: .trailing)
                    Text("STOP").frame(width: 100, alignment: .trailing)
                }
                .font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
                .padding(.horizontal, 14).frame(height: 30)
                Rectangle().fill(LX.C.divider).frame(height: 1)
                ForEach(inference.history.prefix(30)) { s in
                    HStack(spacing: 0) {
                        Text(ModelRepoID(s.modelID).map(ModelDisplay.name) ?? s.modelID).frame(maxWidth: .infinity, alignment: .leading)
                        Text(s.client.rawValue).font(LX.F.mono(11)).foregroundStyle(LX.C.secondary).frame(width: 90, alignment: .leading)
                        Text("\(s.metrics.promptTokens)").font(LX.F.mono(12)).frame(width: 80, alignment: .trailing)
                        Text("\(s.metrics.generatedTokens)").font(LX.F.mono(12)).frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.0f ms", s.metrics.timeToFirstToken.milliseconds)).font(LX.F.mono(12)).frame(width: 90, alignment: .trailing)
                        Text(s.metrics.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").font(LX.F.mono(12)).frame(width: 90, alignment: .trailing)
                        Text(s.metrics.stopReason.rawValue).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).frame(width: 100, alignment: .trailing)
                    }
                    .font(LX.F.bodySmall).foregroundStyle(LX.C.body)
                    .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                    .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
                }
                if inference.history.isEmpty {
                    Text("Numbers from Chat, Mini Chat, Work and API generations appear here (this session only, no content).")
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
            .well()
        }
    }
}

struct KPITile: View {
    let label: String
    let value: String
    let unit: String
    let note: String
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(LX.F.caption).foregroundStyle(LX.C.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(LX.F.monoLarge).kerning(-0.4)
                Text(unit).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                Spacer(minLength: 6)
                if spark.count > 1 {
                    let lo = spark.min() ?? 0, hi = spark.max() ?? 1
                    let pad = max((hi - lo) * 0.3, hi * 0.05, 0.001)
                    Chart(Array(spark.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("i", i), y: .value("v", v))
                            .foregroundStyle(LX.C.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .frame(width: 98, height: 26)
                    .accessibilityHidden(true)
                }
            }
            Text(note).font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }
}
