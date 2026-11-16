import Foundation

public enum ChatRole: String, Sendable, Codable, Hashable {
    case system, user, assistant
}

/// Measured numbers for one assistant turn. All durations come from a monotonic clock.
public struct GenerationMetrics: Sendable, Codable, Hashable {
    public var promptTokens: Int
    public var generatedTokens: Int
    /// Request accepted by the engine → first generated token (includes prefill).
    public var timeToFirstToken: Duration
    /// Prompt processing time (prefill only).
    public var prefillDuration: Duration
    /// First token → last token.
    public var decodeDuration: Duration
    /// Request accepted → finished (excludes queue wait and model loading).
    public var totalDuration: Duration
    public var stopReason: StopReason
    /// Prompt tokens served from a reused KV cache (not prefilled). nil/0 = full prefill.
    public var cachedPromptTokens: Int?

    public enum StopReason: String, Sendable, Codable, Hashable {
        case endOfSequence, maxTokens, cancelled, contextLimit, error
    }

    public init(promptTokens: Int, generatedTokens: Int, timeToFirstToken: Duration, prefillDuration: Duration,
                decodeDuration: Duration, totalDuration: Duration, stopReason: StopReason) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.timeToFirstToken = timeToFirstToken
        self.prefillDuration = prefillDuration
        self.decodeDuration = decodeDuration
        self.totalDuration = totalDuration
        self.stopReason = stopReason
    }

    public var prefillTokensPerSecond: Double? { Self.rate(promptTokens, prefillDuration) }
    /// The first token is produced by prefill, so decode throughput counts the remaining tokens.
    public var decodeTokensPerSecond: Double? { Self.rate(max(generatedTokens - 1, 0), decodeDuration) }

    static func rate(_ tokens: Int, _ duration: Duration) -> Double? {
        let seconds = duration.seconds
        guard tokens > 0, seconds > 0 else { return nil }
        return Double(tokens) / seconds
    }
}

extension Duration {
    public var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    public var milliseconds: Double { seconds * 1000 }
}

public struct ChatMessage: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var modelID: String?
    public var createdAt: Date
    public var metrics: GenerationMetrics?
    /// The reply was stopped by the user or an error before it finished.
    public var interrupted: Bool
    /// Web sources the reply was grounded on (cited as [n]).
    public var sources: [WebSource] = []
    /// Non-fatal web search problem shown with the reply (memory only).
    public var webNote: String?

    public init(id: UUID = UUID(), role: ChatRole, content: String, modelID: String? = nil,
                createdAt: Date = Date(), metrics: GenerationMetrics? = nil, interrupted: Bool = false) {
        self.interrupted = interrupted
        self.id = id
        self.role = role
        self.content = content
        self.modelID = modelID
        self.createdAt = createdAt
        self.metrics = metrics
    }
}

/// A conversation. Lives in memory; persisted only while `isPinned` is true.
public struct ChatSession: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var modelID: String?
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var pinnedAt: Date?

    public init(id: UUID = UUID(), title: String = "Untitled", modelID: String? = nil, messages: [ChatMessage] = [],
                createdAt: Date = Date(), updatedAt: Date = Date(), isPinned: Bool = false, pinnedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
    }
}
