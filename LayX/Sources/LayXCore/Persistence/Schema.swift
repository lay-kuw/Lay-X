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
        Migration(version: 2, sql: """
            ALTER TABLE pinned_message ADD COLUMN sources BLOB;
            """),
        // API key *hashes* (SHA-256 of random keys; the keys themselves are never stored anywhere).
        Migration(version: 3, sql: """
            CREATE TABLE api_key (
                id          TEXT PRIMARY KEY NOT NULL,
                name        TEXT NOT NULL,
                prefix      TEXT NOT NULL,
                hash        TEXT NOT NULL,
                created_at  REAL NOT NULL
            );
            """),
    ]

    public static let fileName = "LayX.sqlite"

    /// Moves the database to `newURL`: consistent copy (`VACUUM INTO`), then the old file and its WAL/SHM
    /// side files are deleted so pinned-chat content isn't left behind. The caller must stop using `db`.
    public static func move(_ db: SQLiteDatabase, from oldURL: URL, to newURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: newURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try await db.copy(to: newURL)
        await db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: oldURL.path + suffix))
        }
    }

    /// `~/.config/lay-x/database/LayX.sqlite` (folder created if missing).
    public static func defaultURL() throws -> URL {
        let dir = LayXPaths.configRoot.appendingPathComponent("database", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(fileName)
    }
}
