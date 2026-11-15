import Foundation

/// Lay X application schema. Only pinned conversations, benchmark results and app metadata are stored.
/// Unpinned conversations never reach this database.
public enum LayXSchema {
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: """
            CREATE TABLE pinned_chat (
                id          TEXT PRIMARY KEY NOT NULL,
                title       TEXT NOT NULL,
                model_id    TEXT,
                created_at  REAL NOT NULL,
                updated_at  REAL NOT NULL,
                pinned_at   REAL NOT NULL
            );
            CREATE TABLE pinned_message (
                id          TEXT PRIMARY KEY NOT NULL,
                chat_id     TEXT NOT NULL REFERENCES pinned_chat(id) ON DELETE CASCADE,
                position    INTEGER NOT NULL,
                role        TEXT NOT NULL,
                content     TEXT NOT NULL,
                model_id    TEXT,
                created_at  REAL NOT NULL,
                metrics     BLOB
            );
            CREATE INDEX pinned_message_chat ON pinned_message(chat_id, position);
            CREATE TABLE benchmark_run (
                id          TEXT PRIMARY KEY NOT NULL,
                created_at  REAL NOT NULL,
                payload     BLOB NOT NULL
            );
            CREATE TABLE app_meta (
                key         TEXT PRIMARY KEY NOT NULL,
                value       TEXT NOT NULL
            );
            """),
    ]

    /// `~/Library/Application Support/Lay X/LayX.sqlite`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Lay X", isDirectory: true).appendingPathComponent("LayX.sqlite")
    }
}
