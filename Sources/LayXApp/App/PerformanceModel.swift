import AppKit
import Foundation
import LayXCore
import UniformTypeIdentifiers

/// Benchmarks: run, cancel, persist, select, export. Results contain synthetic-prompt measurements only.
@MainActor
@Observable
final class PerformanceModel {
    private(set) var results: [BenchmarkResult] = []
    var selectedID: UUID?
    private(set) var progress: BenchmarkProgress?
    private(set) var runningConfig: BenchmarkConfig?
    var notice: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var store: BenchmarkStore?
    @ObservationIgnored private let coordinator: InferenceCoordinator

    static let engineName = "MLX Swift 0.32.3 · mlx-swift-lm 3.32.3"

    init(store: BenchmarkStore?, coordinator: InferenceCoordinator) {
        self.store = store
        self.coordinator = coordinator
        Task { await reload() }
    }

    var isRunning: Bool { task != nil }
    var selected: BenchmarkResult? { results.first { $0.id == selectedID } ?? results.first }

    func replaceStore(_ newStore: BenchmarkStore?) async {
        store = newStore
        selectedID = nil
        await reload()
    }

    func reload() async {
        guard let store else { return }
        results = (try? await store.loadAll()) ?? []
        if selectedID == nil { selectedID = results.first?.id }
    }

    /// Loads the default model if needed, then runs `config` through the shared coordinator.
    func run(_ config: BenchmarkConfig) {
        guard task == nil else { return }
        runningConfig = config
        progress = BenchmarkProgress(step: 0, total: 1, promptTarget: config.promptTokens.first ?? 0, warmup: true)
        task = Task {
            defer { task = nil; progress = nil; runningConfig = nil }
            do {
                if await coordinator.snapshot.model.loadedModel == nil {
                    guard let m = AppServices.defaultChatModel(in: AppServices.shared.models) else { throw ChatSetupError.noModelInstalled }
                    try await coordinator.load(m.reference)
                }
                let result = try await BenchmarkRunner.run(config, coordinator: coordinator, engineName: Self.engineName) { p in
                    Task { @MainActor in self.progress = p }
                }
                guard !result.samples.isEmpty else { notice = "Benchmark cancelled — no samples recorded."; return }
                try? await store?.save(result)
                results.insert(result, at: 0)
                selectedID = result.id
                notice = result.completed ? "Benchmark finished." : "Benchmark cancelled — partial results saved."
            } catch is CancellationError {
                notice = "Benchmark cancelled."
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "The benchmark failed."
            }
        }
    }

    func cancel() { task?.cancel() }

    func delete(_ id: UUID) {
        Task {
            try? await store?.delete(id)
            results.removeAll { $0.id == id }
            if selectedID == id { selectedID = results.first?.id }
        }
    }

    func exportCSV(_ result: BenchmarkResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "LayX-benchmark-\(result.date.formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.csv().write(to: url, atomically: true, encoding: .utf8)
            notice = "Exported \(url.lastPathComponent)."
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Latest result per model whose configuration matches `key` (comparable conditions only).
    func comparable(to key: String) -> [BenchmarkResult] {
        var seen = Set<String>()
        return results.filter { r in
            guard r.config.comparisonKey == key, !seen.contains(r.modelID) else { return false }
            seen.insert(r.modelID)
            return true
        }
    }

    /// Latest context-sweep result per model (chart series), at most three.
    var sweeps: [BenchmarkResult] {
        var seen = Set<String>()
        return results.filter { r in
            guard r.config.isSweep, !seen.contains(r.modelID) else { return false }
            seen.insert(r.modelID)
            return true
        }.prefix(3).map { $0 }
    }
}
