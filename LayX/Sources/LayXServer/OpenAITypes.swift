import Foundation
import LayXCore

/// OpenAI-compatible wire types (the subset Lay X supports). See `APIServer` for unsupported features.
public enum OpenAI {
    // MARK: Request

    public struct ChatCompletionRequest: Decodable, Sendable {
        public var model: String?
        public var messages: [Message]
        public var temperature: Double?
        public var top_p: Double?
        public var max_tokens: Int?
        public var max_completion_tokens: Int?
        public var stream: Bool?
        public var stream_options: StreamOptions?
        public var stop: Stop?
        public var seed: UInt64?
        public var n: Int?
        public var frequency_penalty: Double?
        public var presence_penalty: Double?
        public var repetition_penalty: Double?
        /// vLLM-style template switches, e.g. `{"enable_thinking": false}`.
        public var chat_template_kwargs: TemplateKwargs?
        // Present only to reject them with a clear message.
        public var tools: AnyDecodable?
        public var functions: AnyDecodable?
        public var tool_choice: AnyDecodable?
        public var response_format: ResponseFormat?
        public var logprobs: Bool?
    }

    public struct StreamOptions: Decodable, Sendable { public var include_usage: Bool? }
    public struct TemplateKwargs: Decodable, Sendable { public var enable_thinking: Bool? }
    public struct ResponseFormat: Decodable, Sendable { public var type: String }

    /// Accepts any JSON value (used only to detect presence).
    public struct AnyDecodable: Decodable, Sendable {
        public init(from decoder: Decoder) throws {}
    }

    public enum Stop: Decodable, Sendable {
        case one(String), many([String])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        public var values: [String] {
            switch self { case .one(let s): [s]; case .many(let a): a }
        }
    }

    public struct Message: Decodable, Sendable {
        public var role: String
        public var content: Content?
    }

    /// `content` may be a string or an array of parts; only text parts are supported.
    public enum Content: Decodable, Sendable {
        case text(String)
        case parts([Part])

        public struct Part: Decodable, Sendable {
            public var type: String
            public var text: String?
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .parts(try c.decode([Part].self)) }
        }

        public var hasNonTextParts: Bool {
            if case .parts(let p) = self { return p.contains { $0.type != "text" } }
            return false
        }

        public var text: String {
            switch self {
            case .text(let s): s
            case .parts(let p): p.compactMap(\.text).joined(separator: "\n")
            }
        }
    }

    // MARK: Responses

    public struct Usage: Encodable, Sendable, Equatable {
        public var prompt_tokens: Int
        public var completion_tokens: Int
        public var total_tokens: Int
    }

    public struct ChatCompletion: Encodable, Sendable {
        public struct Choice: Encodable, Sendable {
            public var index: Int
            public var message: ResponseMessage
            public var finish_reason: String
        }
        public struct ResponseMessage: Encodable, Sendable {
            public var role: String
            public var content: String
        }
        public var id: String
        public var object = "chat.completion"
        public var created: Int
        public var model: String
        public var choices: [Choice]
        public var usage: Usage
    }

    public struct ChatCompletionChunk: Encodable, Sendable {
        public struct Choice: Encodable, Sendable {
            public var index: Int
            public var delta: Delta
            public var finish_reason: String?

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(index, forKey: .index)
                try c.encode(delta, forKey: .delta)
                try c.encode(finish_reason, forKey: .finish_reason)  // explicit null, as OpenAI does
            }
            enum CodingKeys: String, CodingKey { case index, delta, finish_reason }
        }
        public struct Delta: Encodable, Sendable {
            public var role: String?
            public var content: String?
        }
        public var id: String
        public var object = "chat.completion.chunk"
        public var created: Int
        public var model: String
        public var choices: [Choice]
        public var usage: Usage?
    }

    public struct ModelList: Encodable, Sendable {
        public struct Model: Encodable, Sendable {
            public var id: String
            public var object = "model"
            public var created: Int
            public var owned_by = "lay-x"
        }
        public var object = "list"
        public var data: [Model]
    }

    public struct ErrorBody: Encodable, Sendable {
        public struct Detail: Encodable, Sendable {
            public var message: String
            public var type: String
            public var param: String?
            public var code: String?
        }
        public var error: Detail
    }

    public static func finishReason(_ stop: GenerationMetrics.StopReason?) -> String {
        switch stop {
        case .maxTokens?, .contextLimit?: "length"
        default: "stop"
        }
    }
}
