import Foundation
import LayXCore
import Security

/// Web search settings. Non-secret values in UserDefaults; the Brave API key in the Keychain.
/// Web search is read-only: only the search query is sent to the provider and result pages are fetched with
/// plain GET requests — no files, chats or project content are ever uploaded (see `WebClient`).
enum WebPreferences {
    static let modeKey = "lx.web.mode"
    static let providerKey = "lx.web.provider"
    static let searxngURLKey = "lx.web.searxngURL"
    static let maxResultsKey = "lx.web.maxResults"
    static let pagesKey = "lx.web.pagesToRead"

    static var mode: WebSearchMode {
        WebSearchMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off
    }

    static var provider: WebSearchProvider {
        WebSearchProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .duckDuckGo
    }

    /// Full configuration for a search. The Brave key is only read (from the Keychain, cached for the session)
    /// when Brave is the selected provider — never just to draw the UI.
    static var config: WebSearchConfig {
        let d = UserDefaults.standard
        return WebSearchConfig(
            provider: provider,
            braveKey: provider == .brave ? BraveKey.cachedRead() : nil,
            searxngURL: d.string(forKey: searxngURLKey).flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil },
            maxResults: d.object(forKey: maxResultsKey) as? Int ?? 5,
            pagesToRead: d.object(forKey: pagesKey) as? Int ?? 3)
    }

    /// Brave Search API key in the Keychain (generic password, this device only).
    enum BraveKey {
        static let service = "app.layx.web-search"
        static let account = "brave"

        @MainActor private static var cache: String??

        /// Keychain read once per session (avoids repeated permission prompts for ad-hoc–signed builds).
        @MainActor static func cachedRead() -> String? {
            if let cached = cache { return cached }
            let value = read()
            cache = .some(value)
            return value
        }

        static func read() -> String? {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }

        @discardableResult
        @MainActor static func save(_ key: String) -> Bool {
            remove()
            cache = .some(key)
            let a: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrLabel as String: "Lay X — Brave Search API key",
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                    kSecValueData as String: Data(key.utf8)]
            return SecItemAdd(a as CFDictionary, nil) == errSecSuccess
        }

        @MainActor static func remove() {
            cache = .some(nil)
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
            SecItemDelete(q as CFDictionary)
        }
    }
}
