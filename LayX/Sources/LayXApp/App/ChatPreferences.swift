import Foundation
import LayXCore

/// Chat-related preferences in UserDefaults (settings only — never chat content).
enum ChatPreferences {
    static let temperatureKey = "lx.temperature"
    static let topPKey = "lx.topP"
    static let maxTokensKey = "lx.maxTokens"
    static let defaultChatModelKey = "lx.defaultChatModel"
    static let thinkingKey = "lx.thinking"
    /// The "Soul": persona / standing instructions used as the system prompt for Chat and Mini Chat.
    static let soulKey = "lx.soul"
    /// Work instructions (replace the default role & style; fixed safety/format rules are always added).
    static let workSoulKey = "lx.workSoul"

    static var workInstructions: String? {
        let s = (UserDefaults.standard.string(forKey: workSoulKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(soulLimit))
    }

    static let defaultTemperature = 0.7
    static let defaultTopP = 0.95
    static let defaultMaxTokens = 4096
    static let defaultThinking = true
    static let soulLimit = 8000

    static var thinking: Bool {
        UserDefaults.standard.object(forKey: thinkingKey) as? Bool ?? defaultThinking
    }

    static var soul: String {
        (UserDefaults.standard.string(forKey: soulKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var current: ChatGenerationSettings {
        let d = UserDefaults.standard
        let temperature = d.object(forKey: temperatureKey) as? Double ?? defaultTemperature
        let topP = d.object(forKey: topPKey) as? Double ?? defaultTopP
        let maxTokens = d.object(forKey: maxTokensKey) as? Int ?? defaultMaxTokens
        return ChatGenerationSettings(
            parameters: GenerationParameters(temperature: temperature, topP: topP, maxTokens: maxTokens).validated(),
            systemPrompt: soul.isEmpty ? nil : String(soul.prefix(soulLimit)),
            thinking: thinking,
            webMode: WebPreferences.mode)
    }
}

enum ChatSetupError: LocalizedError {
    case noModelInstalled
    var errorDescription: String? {
        "No model is installed yet. Download one in Models (for example mlx-community/Qwen3-4B-4bit)."
    }
}
