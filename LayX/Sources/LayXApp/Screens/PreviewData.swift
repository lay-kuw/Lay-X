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

struct ChatSummary: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var age: String
    var pinned: Bool
}

enum Block: Hashable {
    case text(String)
    case code(language: String, filename: String, code: String)
}

struct Message: Identifiable, Hashable {
    let id = UUID()
    var isUser: Bool
    var author: String
    var meta: String
    var blocks: [Block]
}

enum Mock {
    static let question = "MLX Swiftでトークンをストリーミングしながら、SwiftUIのテキストを滑らかに更新したい。再描画が多すぎて重くなるのを避けるには？"

    static let answerIntro = "ポイントはトークンごとにViewを更新しないことです。生成ループ側でバッファし、約30msごとにまとめてMainActorへ流すと、体感の滑らかさを保ったまま再描画を大幅に減らせます。"

    static let answerCode = """
    @MainActor final class StreamBuffer: ObservableObject {
        @Published private(set) var text = ""
        private var pending = ""
        private var flushTask: Task<Void, Never>?

        func append(_ token: String) {
            pending += token
            guard flushTask == nil else { return }
            flushTask = Task {
                try? await Task.sleep(for: .milliseconds(30))
                text += pending; pending = ""; flushTask = nil
            }
        }
    }
    """

    static let answerOutro = "長文は段落単位で LazyVStack に並べ、スクロール追従は末尾アンカーのみ更新します。"

    static let conversation: [Message] = [
        Message(isUser: true, author: "You", meta: "14:02:11", blocks: [.text(question)]),
        Message(isUser: false, author: "Qwen3 14B", meta: "412 tok · 8.5 s", blocks: [
            .text(answerIntro),
            .code(language: "swift", filename: "StreamBuffer.swift", code: answerCode),
            .text(answerOutro),
        ]),
    ]

    static let sessionChats: [ChatSummary] = [
        ChatSummary(title: "Regex for log lines", age: "12m", pinned: false),
    ]
    static let pinnedChats: [ChatSummary] = [
        ChatSummary(title: "Q1 roadmap — local-first", age: "2d", pinned: true),
        ChatSummary(title: "Prompt library · Review", age: "5d", pinned: true),
        ChatSummary(title: "日本語の要約テンプレート", age: "1w", pinned: true),
    ]

    static let suggestions = ["Explain a Swift concurrency bug", "議事録を3行で要約", "Draft a release note"]

    // Mini Chat
    static let miniAnswer = "onReceive で毎トークン text を更新しているのが原因です。バッファを挟んで30ms単位でflushします。"
    static let miniDiff = """
    - .onReceive(stream) { text += $0 }
    + .onReceive(stream) { buffer.append($0) }
    + .onReceive(buffer.$text) { text = $0 }
    """
}

// MARK: - Work

struct FileNode: Identifiable, Hashable {
    let id = UUID()
    var depth: Int
    var name: String
    var isFolder: Bool
    var status: String? = nil
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case context, added, removed, hunk }
    let id = UUID()
    var kind: Kind
    var old: Int?
    var new: Int?
    var text: String
}

struct ProposedChange: Identifiable, Hashable {
    let id = UUID()
    var file: String
    var status: String
    var stats: String
    var summary: String
    var selected: Bool
}

extension Mock {
    static let tree: [FileNode] = [
        FileNode(depth: 0, name: "Sources", isFolder: true),
        FileNode(depth: 1, name: "LayX", isFolder: true),
        FileNode(depth: 2, name: "Chat", isFolder: true),
        FileNode(depth: 3, name: "ChatView.swift", isFolder: false, status: "M"),
        FileNode(depth: 3, name: "StreamBuffer.swift", isFolder: false, status: "A"),
        FileNode(depth: 3, name: "MessageRow.swift", isFolder: false),
        FileNode(depth: 2, name: "Inference", isFolder: true),
        FileNode(depth: 3, name: "MLXSession.swift", isFolder: false, status: "M"),
        FileNode(depth: 3, name: "Sampler.swift", isFolder: false),
        FileNode(depth: 2, name: "Mini", isFolder: true),
        FileNode(depth: 3, name: "MiniPanel.swift", isFolder: false),
        FileNode(depth: 1, name: "LayXApp.swift", isFolder: false),
        FileNode(depth: 0, name: "Tests", isFolder: true),
        FileNode(depth: 0, name: "Package.swift", isFolder: false),
    ]

    static let diff: [DiffLine] = [
        DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -41,8 +41,11 @@ struct ChatView: View"),
        DiffLine(kind: .context, old: 41, new: 41, text: "    var body: some View {"),
        DiffLine(kind: .context, old: 42, new: 42, text: "        ScrollViewReader { proxy in"),
        DiffLine(kind: .removed, old: 43, new: nil, text: "            ScrollView {"),
        DiffLine(kind: .removed, old: 44, new: nil, text: "                Text(session.output)"),
        DiffLine(kind: .added, old: nil, new: 43, text: "            ScrollView {"),
        DiffLine(kind: .added, old: nil, new: 44, text: "                LazyVStack(alignment: .leading, spacing: 12) {"),
        DiffLine(kind: .added, old: nil, new: 45, text: "                    ForEach(buffer.paragraphs) { MessageRow(text: $0) }"),
        DiffLine(kind: .added, old: nil, new: 46, text: "                }"),
        DiffLine(kind: .context, old: 45, new: 47, text: "            }"),
        DiffLine(kind: .removed, old: 46, new: nil, text: "            .onReceive(session.tokens) { session.output += $0 }"),
        DiffLine(kind: .added, old: nil, new: 48, text: "            .onReceive(session.tokens) { buffer.append($0) }"),
        DiffLine(kind: .added, old: nil, new: 49, text: "            .onChange(of: buffer.text) { proxy.scrollTo(\"end\") }"),
        DiffLine(kind: .context, old: 47, new: 50, text: "        }"),
        DiffLine(kind: .context, old: 48, new: 51, text: "    }"),
        DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -88,4 +91,4 @@ private extension ChatView"),
        DiffLine(kind: .removed, old: 90, new: nil, text: "        .animation(.default, value: session.output)"),
        DiffLine(kind: .added, old: nil, new: 93, text: "        .animation(.smooth(duration: 0.18), value: buffer.text)"),
    ]

    static let changes: [ProposedChange] = [
        ProposedChange(file: "ChatView.swift", status: "M", stats: "+6 −3", summary: "Render paragraphs lazily; buffer tokens", selected: true),
        ProposedChange(file: "StreamBuffer.swift", status: "A", stats: "+38", summary: "New 30 ms flush buffer", selected: true),
        ProposedChange(file: "MLXSession.swift", status: "M", stats: "+2 −1", summary: "Expose tokens as AsyncStream", selected: false),
    ]
}

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
