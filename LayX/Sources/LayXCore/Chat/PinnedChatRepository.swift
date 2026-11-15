import Foundation

/// Storage for pinned conversations. The only path through which chat content reaches disk.
public protocol PinnedChatStoring: Sendable {
    /// Writes the full session (metadata + all messages), replacing any previous copy.
    func save(_ session: ChatSession) async throws
    func delete(id: UUID) async throws
    func loadAll() async throws -> [ChatSession]
}

public struct PinnedChatRepository: PinnedChatStoring {
    private let db: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.db = database
    }

    public func save(_ session: ChatSession) async throws {
        let encoder = JSONEncoder()
        let messageRows: [[SQLValue]] = try session.messages.enumerated().map { index, m in
            [
                .text(m.id.uuidString), .text(session.id.uuidString), .int(Int64(index)), .text(m.role.rawValue),
                .text(m.content), m.modelID.map(SQLValue.text) ?? .null, .double(m.createdAt.timeIntervalSince1970),
                try m.metrics.map { .blob(try encoder.encode($0)) } ?? .null,
            ]
        }
        let chatRow: [SQLValue] = [
            .text(session.id.uuidString), .text(session.title), session.modelID.map(SQLValue.text) ?? .null,
            .double(session.createdAt.timeIntervalSince1970), .double(session.updatedAt.timeIntervalSince1970),
            .double((session.pinnedAt ?? Date()).timeIntervalSince1970),
        ]
        try await db.transaction { db in
            try db.execute("""
                INSERT INTO pinned_chat (id, title, model_id, created_at, updated_at, pinned_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title, model_id = excluded.model_id, updated_at = excluded.updated_at
                """, chatRow)
            try db.execute("DELETE FROM pinned_message WHERE chat_id = ?", [.text(session.id.uuidString)])
            for row in messageRows {
                try db.execute("""
                    INSERT INTO pinned_message (id, chat_id, position, role, content, model_id, created_at, metrics)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, row)
            }
        }
    }

    public func delete(id: UUID) async throws {
        // ON DELETE CASCADE removes the messages; secure_delete overwrites the freed pages.
        try await db.execute("DELETE FROM pinned_chat WHERE id = ?", [.text(id.uuidString)])
    }

    public func loadAll() async throws -> [ChatSession] {
        let chats = try await db.query("SELECT * FROM pinned_chat ORDER BY pinned_at DESC")
        let messages = try await db.query("SELECT * FROM pinned_message ORDER BY chat_id, position")
        let decoder = JSONDecoder()
        var byChat: [String: [ChatMessage]] = [:]
        for row in messages {
            guard let chatID = row["chat_id"].text,
                  let id = row["id"].text.flatMap(UUID.init(uuidString:)),
                  let role = row["role"].text.flatMap(ChatRole.init(rawValue:)),
                  let content = row["content"].text
            else { continue }
            let metrics = row["metrics"].blob.flatMap { try? decoder.decode(GenerationMetrics.self, from: $0) }
            byChat[chatID, default: []].append(ChatMessage(
                id: id, role: role, content: content, modelID: row["model_id"].text,
                createdAt: Date(timeIntervalSince1970: row["created_at"].double ?? 0), metrics: metrics))
        }
        return chats.compactMap { row in
            guard let idText = row["id"].text, let id = UUID(uuidString: idText) else { return nil }
            return ChatSession(
                id: id, title: row["title"].text ?? "Untitled", modelID: row["model_id"].text,
                messages: byChat[idText] ?? [],
                createdAt: Date(timeIntervalSince1970: row["created_at"].double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"].double ?? 0),
                isPinned: true, pinnedAt: Date(timeIntervalSince1970: row["pinned_at"].double ?? 0))
        }
    }
}
