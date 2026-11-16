import Foundation
import Testing
@testable import LayXCore

@Suite struct SQLiteDatabaseTests {
    @Test func migrationsSetUserVersionAndCreateTables() async throws {
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        #expect(try await db.userVersion() == 3)
        let tables = try await db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .compactMap { $0["name"].text }
        #expect(tables == ["api_key", "app_meta", "benchmark_run", "pinned_chat", "pinned_message"])
    }

    @Test func migrationsAreNotReappliedOnReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layx-test-\(UUID().uuidString)").appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let db = try SQLiteDatabase(location: .file(url), migrations: LayXSchema.migrations)
            try await db.execute("INSERT INTO app_meta (key, value) VALUES ('k', 'v')")
            await db.close()
        }
        let reopened = try SQLiteDatabase(location: .file(url), migrations: LayXSchema.migrations)
        #expect(try await reopened.query("SELECT value FROM app_meta WHERE key = 'k'").first?["value"].text == "v")
    }

    @Test func moveCopiesDataAndRemovesOldFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layx-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("a/LayX.sqlite"), new = dir.appendingPathComponent("b/LayX.sqlite")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(location: .file(old), migrations: LayXSchema.migrations)
        try await PinnedChatRepository(database: db).save(ChatSession(title: "Keep", messages: [ChatMessage(role: .user, content: "hi")], isPinned: true, pinnedAt: Date()))
        try await LayXSchema.move(db, from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: old.path + "-wal"))
        let reopened = try SQLiteDatabase(location: .file(new), migrations: LayXSchema.migrations)
        #expect(try await PinnedChatRepository(database: reopened).loadAll().first?.title == "Keep")
    }

    @Test func failingMigrationRollsBack() async throws {
        let bad = LayXSchema.migrations + [Migration(version: 2, sql: "CREATE TABLE x (a); THIS IS NOT SQL;")]
        #expect(throws: DatabaseError.self) { try SQLiteDatabase(location: .inMemory, migrations: bad) }
    }

    @Test func transactionRollsBackOnError() async throws {
        struct Boom: Error {}
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        await #expect(throws: Boom.self) {
            try await db.transaction { db in
                try db.execute("INSERT INTO app_meta (key, value) VALUES ('a', '1')")
                throw Boom()
            }
        }
        #expect(try await db.query("SELECT * FROM app_meta").isEmpty)
    }

    @Test func roundTripsAllValueTypes() async throws {
        let db = try SQLiteDatabase(location: .inMemory, migrations: [
            Migration(version: 1, sql: "CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n TEXT)"),
        ])
        let blob = Data([0, 1, 2, 255])
        try await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)",
                             [.int(42), .double(1.5), .text("こんにちは 'quoted'"), .blob(blob), .null])
        let row = try #require(try await db.query("SELECT * FROM t").first)
        #expect(row["i"].int == 42)
        #expect(row["d"].double == 1.5)
        #expect(row["s"].text == "こんにちは 'quoted'")
        #expect(row["b"].blob == blob)
        #expect(row["n"] == .null)
    }
}

@Suite struct PinnedChatRepositoryTests {
    private func makeRepo() throws -> PinnedChatRepository {
        PinnedChatRepository(database: try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations))
    }

    private func sampleSession() -> ChatSession {
        let metrics = GenerationMetrics(
            promptTokens: 12, generatedTokens: 30, timeToFirstToken: .milliseconds(180),
            prefillDuration: .milliseconds(120), decodeDuration: .milliseconds(600),
            totalDuration: .milliseconds(800), stopReason: .endOfSequence)
        return ChatSession(
            title: "Hello", modelID: "mlx-community/test",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                ChatMessage(role: .assistant, content: "Hello!", modelID: "mlx-community/test", metrics: metrics),
            ],
            isPinned: true, pinnedAt: Date())
    }

    @Test func saveAndLoadPreservesContentAndOrder() async throws {
        let repo = try makeRepo()
        let session = sampleSession()
        try await repo.save(session)
        let loaded = try await repo.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == session.id)
        #expect(loaded[0].messages.map(\.content) == ["Hi", "Hello!"])
        #expect(loaded[0].messages[1].metrics?.generatedTokens == 30)
        #expect(loaded[0].isPinned)
    }

    @Test func saveReplacesMessages() async throws {
        let repo = try makeRepo()
        var session = sampleSession()
        try await repo.save(session)
        session.messages.append(ChatMessage(role: .user, content: "More"))
        session.title = "Renamed"
        try await repo.save(session)
        let loaded = try await repo.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].title == "Renamed")
        #expect(loaded[0].messages.count == 3)
    }

    @Test func deleteRemovesChatAndMessages() async throws {
        let db = try SQLiteDatabase(location: .inMemory, migrations: LayXSchema.migrations)
        let repo = PinnedChatRepository(database: db)
        let session = sampleSession()
        try await repo.save(session)
        try await repo.delete(id: session.id)
        #expect(try await repo.loadAll().isEmpty)
        #expect(try await db.query("SELECT * FROM pinned_message").isEmpty)
    }
}
