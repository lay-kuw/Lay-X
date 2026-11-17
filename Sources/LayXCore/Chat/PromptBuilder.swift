import Foundation

/// Builds the prompt for a chat turn and keeps it inside the model's context window.
public enum PromptBuilder {
    public struct Result: Sendable, Equatable {
        public var messages: [PromptMessage]
        /// Number of older chat messages left out to fit the context window.
        public var omittedCount: Int
        public var estimatedTokens: Int
    }

    /// Conservative token estimate without a tokenizer: ~1 token per 3 UTF-8 bytes (over-estimates English,
    /// roughly matches CJK), plus a per-message overhead for chat-template markup.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, (text.utf8.count + 2) / 3)
    }

    static let perMessageOverhead = 8
    static let safetyMargin = 64

    /// - Parameters:
    ///   - history: the conversation, oldest first; the last message is normally the new user message.
    ///   - contextLength: model context window in tokens (`nil` = unknown → no trimming).
    ///   - maxOutputTokens: tokens reserved for the reply (capped at half the context).
    public static func build(history: [ChatMessage], systemPrompt: String?, contextLength: Int?,
                             maxOutputTokens: Int) -> Result {
        var system: [PromptMessage] = []
        if let s = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            system = [PromptMessage(role: .system, content: s)]
        }
        let converted = history.map { m in
            PromptMessage(role: m.role, content: m.role == .assistant ? ThinkingParser.stripThinking(m.content) : m.content)
        }
        func cost(_ m: PromptMessage) -> Int { estimateTokens(m.content) + perMessageOverhead }
        let systemCost = system.reduce(0) { $0 + cost($1) }

        guard let contextLength else {
            return Result(messages: system + converted, omittedCount: 0,
                          estimatedTokens: systemCost + converted.reduce(0) { $0 + cost($1) })
        }
        let reserve = min(maxOutputTokens, contextLength / 2)
        let budget = contextLength - reserve - safetyMargin - systemCost

        // Keep the newest messages that fit; always keep the latest one (the engine reports if it alone is too big).
        var kept: [PromptMessage] = []
        var used = 0
        for m in converted.reversed() {
            let c = cost(m)
            if !kept.isEmpty, used + c > budget { break }
            kept.insert(m, at: 0)
            used += c
        }
        // A conversation must not start with an orphaned assistant reply.
        var omitted = converted.count - kept.count
        while kept.count > 1, kept.first?.role == .assistant {
            kept.removeFirst()
            omitted += 1
        }
        return Result(messages: system + kept, omittedCount: omitted, estimatedTokens: systemCost + used)
    }
}

/// Splits reasoning (`<think>…</think>`) from the visible answer.
public enum ThinkingParser {
    public struct Parts: Sendable, Equatable {
        public var thinking: String?
        public var answer: String
        /// True while the model is still inside an unterminated `<think>` block.
        public var isThinking: Bool
    }

    public static func split(_ text: String) -> Parts {
        guard let open = text.range(of: "<think>") else {
            // Opening tag supplied by the prompt template: everything before "</think>" is reasoning.
            if let close = text.range(of: "</think>") {
                let thinking = text[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return Parts(thinking: thinking.isEmpty ? nil : thinking,
                             answer: text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), isThinking: false)
            }
            return Parts(thinking: nil, answer: text, isThinking: false)
        }
        let before = String(text[..<open.lowerBound])
        let afterOpen = text[open.upperBound...]
        if let close = afterOpen.range(of: "</think>") {
            let thinking = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (before + afterOpen[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Parts(thinking: thinking.isEmpty ? nil : thinking, answer: answer, isThinking: false)
        }
        let thinking = afterOpen.trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(thinking: thinking.isEmpty ? nil : thinking, answer: before.trimmingCharacters(in: .whitespacesAndNewlines),
                     isThinking: true)
    }

    /// The answer without reasoning — what is sent back to the model as history.
    public static func stripThinking(_ text: String) -> String { split(text).answer }
}
