import Foundation
import LayXCore

/// Chat-related preferences in UserDefaults (non-sensitive values only — never chat content).
enum ChatPreferences {
    static let temperatureKey = "lx.temperature"
    static let topPKey = "lx.topP"
    static let maxTokensKey = "lx.maxTokens"
    static let defaultChatModelKey = "lx.defaultChatModel"
    static let presetKey = "lx.chatPreset"

    static let defaultTemperature = 0.7
    static let defaultTopP = 0.95
    static let defaultMaxTokens = 4096

    /// System-prompt presets offered in the composer.
    static let presets: [(name: String, prompt: String?)] = [
        ("Default", nil),
        ("Concise", "Answer concisely. Prefer short paragraphs and bullet points. No preamble."),
        ("Swift expert", "You are an expert Swift, SwiftUI and Apple-platform engineer. Prefer modern Swift 6 concurrency. Show code when it helps."),
        ("Japanese", "常に自然な日本語で回答してください。"),
    ]

    static var presetName: String {
        let name = UserDefaults.standard.string(forKey: presetKey) ?? "Default"
        return presets.contains { $0.name == name } ? name : "Default"
    }

    static var current: ChatGenerationSettings {
        let d = UserDefaults.standard
        let temperature = d.object(forKey: temperatureKey) as? Double ?? defaultTemperature
        let topP = d.object(forKey: topPKey) as? Double ?? defaultTopP
        let maxTokens = d.object(forKey: maxTokensKey) as? Int ?? defaultMaxTokens
        let prompt = presets.first { $0.name == presetName }?.prompt
        return ChatGenerationSettings(
            parameters: GenerationParameters(temperature: temperature, topP: topP, maxTokens: maxTokens).validated(),
            systemPrompt: prompt)
    }
}

enum ChatSetupError: LocalizedError {
    case noModelInstalled
    var errorDescription: String? {
        "No model is installed yet. Download one in Models (for example mlx-community/Qwen3-4B-4bit)."
    }
}
