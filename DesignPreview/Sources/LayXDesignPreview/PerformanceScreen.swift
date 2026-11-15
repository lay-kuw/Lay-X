import SwiftUI
import Charts

struct PerformanceScreen: View {
    enum Mode: Hashable { case live, benchmarks }
    @State private var mode: Mode = .benchmarks
    @State private var hoverContext: Int? = 8
    @State private var running = false

    private let xs = [1, 2, 4, 8, 16, 32]

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Performance").font(LX.F.title)
                Text("M4 Max · 40-core GPU · 64 GB · macOS 26 · MLX").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary).padding(.leading, 6)
            } trailing: {
                Segmented(options: [(Mode.live, "Live"), (.benchmarks, "Benchmarks")], selection: $mode)
                LXButton(title: "Export CSV") {}
                LXButton(title: running ? "Running…" : "Run benchmark", symbol: "play.fill", shortcut: "⌘R", kind: .primary) {
                    running = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { running = false }
                }
                .keyboardShortcut("r")
            }
            if running { GeneratingRibbon() }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        SectionLabel(text: "Selected run").fixedSize()
                        Text("Qwen3 14B · 4-bit · prompt 2,048 · gen 512 · 5 iterations").font(LX.F.ui(12)).foregroundStyle(LX.C.secondary)
                    }
                    kpis
                    chartCard
                    comparison
                }
                .padding(16)
            }
        }
    }

    // MARK: KPI tiles
    private var kpis: some View {
        HStack(spacing: 10) {
            KPITile(label: "Time to first token", value: "182", unit: "ms", note: "p50 · p95 241 ms", spark: [8, 10, 9, 12, 11, 10, 9, 8])
            KPITile(label: "Prefill", value: "1,240", unit: "tok/s", note: "2k prompt · median of 5", spark: [12, 14, 13, 16, 15, 17, 16, 18])
            KPITile(label: "Decode", value: "48.6", unit: "tok/s", note: "at 1k ctx · −36% at 32k", spark: [18, 18, 17, 16, 14, 12, 10, 9])
            KPITile(label: "Peak memory", value: "12.7", unit: "GB", note: "weights 9.1 · KV 3.6", spark: [6, 8, 9, 11, 12, 13, 14, 14])
        }
    }

    // MARK: Line chart with hover crosshair
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Decode speed vs context length").font(LX.F.ui(13, .semibold))
                Text("tok/s · higher is better").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                Spacer()
                ForEach(Array(Mock.sweepModels.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 6) { Rectangle().fill(LX.C.series[i]).frame(width: 10, height: 2); Text(name) }
                        .font(LX.F.ui(11)).foregroundStyle(LX.C.secondary)
                }
            }
            Chart {
                ForEach(Mock.sweep) { p in
                    LineMark(x: .value("Context", log2(Double(p.contextK))), y: .value("tok/s", p.tps))
                        .foregroundStyle(by: .value("Model", p.model))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Context", log2(Double(p.contextK))), y: .value("tok/s", p.tps))
                        .foregroundStyle(by: .value("Model", p.model))
                        .symbolSize(30)
                }
                if let h = hoverContext {
                    RuleMark(x: .value("Context", log2(Double(h))))
                        .foregroundStyle(Color.white.opacity(0.22))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 0) { tooltip(for: h) }
                }
            }
            .chartForegroundStyleScale(domain: Mock.sweepModels, range: LX.C.series)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: xs.map { log2(Double($0)) }) { v in
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text("\(Int(pow(2, d)))k").font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 20, 40, 60, 80, 100]) { _ in
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
                                    let nearest = xs.min { abs(log2(Double($0)) - v) < abs(log2(Double($1)) - v) }
                                    hoverContext = nearest
                                }
                            case .ended:
                                hoverContext = nil
                            }
                        }
                }
            }
            .frame(height: 280)
            .accessibilityLabel("Decode tokens per second by context length for three models")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .well()
    }

    private func tooltip(for ctx: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(ctx)k ctx").font(LX.F.mono(10.5)).foregroundStyle(LX.C.secondary)
            ForEach(Array(Mock.sweepModels.enumerated()), id: \.offset) { i, name in
                if let p = Mock.sweep.first(where: { $0.model == name && $0.contextK == ctx }) {
                    HStack(spacing: 6) {
                        Rectangle().fill(LX.C.series[i]).frame(width: 8, height: 2)
                        Text(String(format: "%.1f", p.tps)).font(LX.F.mono(11.5))
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

    // MARK: Comparison table
    private var comparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("MODEL COMPARISON · 2K PROMPT").frame(maxWidth: .infinity, alignment: .leading)
                Text("TTFT").frame(width: 100, alignment: .trailing)
                Text("PREFILL TOK/S").frame(width: 130, alignment: .trailing)
                Text("DECODE TOK/S").frame(width: 300, alignment: .leading).padding(.leading, 30)
                Text("PEAK MEM").frame(width: 100, alignment: .trailing)
            }
            .font(LX.F.label).kerning(0.6).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            ForEach(Array(Mock.comparison.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 0) {
                    HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(LX.C.series[i]).frame(width: 8, height: 8); Text(row.model) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.ttft) ms").font(LX.F.mono(12)).frame(width: 100, alignment: .trailing)
                    Text(row.prefill.formatted()).font(LX.F.mono(12)).frame(width: 130, alignment: .trailing)
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(Color.white.opacity(0.05))
                                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3)
                                    .fill(LX.C.series[i]).frame(width: geo.size.width * row.decode / 80)
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f", row.decode)).font(LX.F.mono(12)).frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 300).padding(.leading, 30)
                    Text(String(format: "%.1f GB", row.memory)).font(LX.F.mono(12)).frame(width: 100, alignment: .trailing)
                }
                .font(LX.F.bodySmall).foregroundStyle(LX.C.body)
                .padding(.horizontal, 14).frame(height: LX.S.tableRow)
                .overlay(alignment: .bottom) { Rectangle().fill(LX.C.rowLine).frame(height: 1) }
            }
        }
        .well()
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
                Chart(Array(spark.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v))
                        .foregroundStyle(LX.C.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: 0...26)
                .frame(width: 98, height: 26)
                .accessibilityHidden(true)
            }
            Text(note).font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }
}
