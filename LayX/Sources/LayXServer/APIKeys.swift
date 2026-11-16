import CryptoKit
import Foundation
import Security
import Synchronization

/// Metadata about an API key. The secret itself is shown once at creation and never stored — only its SHA-256.
public struct APIKeyRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// First characters of the key, for recognition in the UI (e.g. "lx-7Hq2").
    public var prefix: String
    public var hash: String
    public var createdAt: Date
}

public protocol APIKeyStoring: Sendable {
    func all() throws -> [APIKeyRecord]
    func add(_ record: APIKeyRecord) throws
    func remove(id: String) throws
}

public enum APIKeys {
    /// `lx-` + 40 base62 characters (~238 bits) from the system CSPRNG.
    public static func generate() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var bytes = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "lx-" + String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    public static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a key, stores its hash, and returns the secret (show once).
    public static func create(name: String, in store: any APIKeyStoring) throws -> (secret: String, record: APIKeyRecord) {
        let secret = generate()
        let record = APIKeyRecord(id: UUID().uuidString, name: String(name.prefix(60)), prefix: String(secret.prefix(7)),
                                  hash: hash(secret), createdAt: Date())
        try store.add(record)
        return (secret, record)
    }

    /// Verifies a presented key against stored hashes. Compares every stored hash in constant time
    /// (no early exit on the first mismatching byte or record).
    public static func verify(_ presented: String, in records: [APIKeyRecord]) -> APIKeyRecord? {
        let candidate = Array(hash(presented).utf8)
        var match: APIKeyRecord?
        for r in records {
            let stored = Array(r.hash.utf8)
            guard stored.count == candidate.count else { continue }
            var diff: UInt8 = 0
            for i in 0..<stored.count { diff |= stored[i] ^ candidate[i] }
            if diff == 0 { match = r }
        }
        return match
    }
}

/// Keychain-backed store (generic passwords, service `app.layx.api-keys`, this device only).
public struct KeychainAPIKeyStore: APIKeyStoring {
    public static let service = "app.layx.api-keys"
    public init() {}

    public func all() throws -> [APIKeyRecord] {
        // The file-based keychain can't return data for multiple items at once (errSecParam), so list the
        // accounts first, then read each item.
        let list: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw KeychainError(status: status) }
        let decoder = JSONDecoder()
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.compactMap { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var data: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let d = data as? Data else { return nil }
            return try? decoder.decode(APIKeyRecord.self, from: d)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func add(_ record: APIKeyRecord) throws {
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: record.id,
            kSecAttrLabel as String: "Lay X API key “\(record.name)”",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public var status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

/// In-memory store (tests, and fallback when the Keychain is unavailable).
public final class InMemoryAPIKeyStore: APIKeyStoring {
    private let records = Mutex<[APIKeyRecord]>([])
    public init() {}
    public func all() throws -> [APIKeyRecord] { records.withLock { $0 } }
    public func add(_ record: APIKeyRecord) throws { records.withLock { $0.append(record) } }
    public func remove(id: String) throws { records.withLock { $0.removeAll { $0.id == id } } }
}
