import SwiftUI

// All data in the preview is mock. Nothing here touches MLX, the network or the file system.

enum Screen: String, CaseIterable, Identifiable {
    case chat, work, models, performance, api, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .work: "Work"
        case .models: "Models"
        case .performance: "Performance"
        case .api: "API Server"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .work: "folder"
        case .models: "shippingbox"
        case .performance: "chart.bar"
        case .api: "server.rack"
        case .settings: "gearshape"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .work: "2"
        case .models: "3"
        case .performance: "4"
        case .api: "5"
        case .settings: ","
        }
    }
}

/// Prototype mock data for screens not yet wired to live services (Work, Performance, API Server).
/// Each later stage deletes its section.
enum Mock {}

// MARK: - Performance

struct SweepPoint: Identifiable {
    let id = UUID()
    var model: String
    var contextK: Int
    var tps: Double
}

extension Mock {
    static let sweepModels = ["Qwen3 30B-A3B", "Qwen3 14B", "Gemma 3 27B"]
    static let sweep: [SweepPoint] = {
        let xs = [1, 2, 4, 8, 16, 32]
        let values: [[Double]] = [
            [74.1, 72.8, 70.2, 66.0, 58.4, 47.9],
            [50.2, 49.1, 47.6, 44.3, 39.0, 31.2],
            [26.1, 25.6, 24.6, 22.9, 20.1, 16.4],
        ]
        var out: [SweepPoint] = []
        for (m, name) in sweepModels.enumerated() {
            for (i, x) in xs.enumerated() { out.append(SweepPoint(model: name, contextK: x, tps: values[m][i])) }
        }
        return out
    }()

    struct Comparison: Identifiable { let id = UUID(); var model: String; var ttft: Int; var prefill: Int; var decode: Double; var memory: Double }
    static let comparison: [Comparison] = [
        Comparison(model: "Qwen3 30B-A3B", ttft: 138, prefill: 1910, decode: 71.3, memory: 19.4),
        Comparison(model: "Qwen3 14B", ttft: 182, prefill: 1240, decode: 48.6, memory: 12.7),
        Comparison(model: "Gemma 3 27B", ttft: 311, prefill: 640, decode: 24.9, memory: 18.8),
    ]
}

// MARK: - API

struct APIRequest: Identifiable, Hashable {
    let id = UUID()
    var time: String
    var method: String
    var path: String
    var client: String
    var status: Int
    var latency: String
    var tokens: String
}

struct APIKey: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var masked: String
    var lastUsed: String
}

extension Mock {
    static let requests: [APIRequest] = [
        APIRequest(time: "14:02:41", method: "POST", path: "/v1/chat/completions", client: "Cursor", status: 200, latency: "1.84 s", tokens: "612"),
        APIRequest(time: "14:02:37", method: "POST", path: "/v1/embeddings", client: "Raycast", status: 200, latency: "92 ms", tokens: "—"),
        APIRequest(time: "14:02:30", method: "POST", path: "/v1/chat/completions", client: "curl", status: 401, latency: "3 ms", tokens: "—"),
        APIRequest(time: "14:02:22", method: "POST", path: "/v1/chat/completions", client: "Cursor", status: 200, latency: "2.31 s", tokens: "804"),
        APIRequest(time: "14:02:10", method: "GET", path: "/v1/models", client: "Raycast", status: 200, latency: "1 ms", tokens: "—"),
    ]
    static let keys: [APIKey] = [
        APIKey(name: "cursor", masked: "lx-sk-…a3f9", lastUsed: "used 1m ago"),
        APIKey(name: "raycast", masked: "lx-sk-…71c2", lastUsed: "used 4m ago"),
        APIKey(name: "scripts", masked: "lx-sk-…0be8", lastUsed: "never"),
    ]
    static let requestsPerMinute: [Int] = [12, 18, 15, 22, 30, 26, 19, 24, 34, 41, 38, 29, 22, 27, 33, 46, 52, 44, 36, 31, 28, 35, 40, 37]
}
