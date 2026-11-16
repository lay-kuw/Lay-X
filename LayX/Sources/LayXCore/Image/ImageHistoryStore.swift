import Foundation

/// Image history: metadata in SQLite, PNG files in one folder (`~/.config/lay-x/images` by default).
/// File names are generated here (never from prompts) and every path is confined to the folder.
public struct ImageHistoryStore: Sendable {
    public let folder: URL
    private let db: SQLiteDatabase

    public init(database: SQLiteDatabase, folder: URL) {
        self.db = database
        self.folder = folder.standardizedFileURL
    }

    /// `~/.config/lay-x/images` (created if missing).
    public static func defaultFolder() throws -> URL {
        let url = LayXPaths.configRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    public func url(for record: ImageRecord) -> URL? {
        guard Self.isSafeName(record.file) else { return nil }
        return folder.appendingPathComponent(record.file)
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".png") && name.count < 128
    }

    static func fileName(date: Date, seed: UInt64, index: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "layx-\(f.string(from: date))-\(seed)\(index > 0 ? "-\(index + 1)" : "").png"
    }

    /// Writes the PNG and records it. Returns the stored record.
    public func save(png: Data, prompt: String, negativePrompt: String, modelID: String, seed: UInt64, steps: Int,
                     cfg: Double = 0, size: ImageSize, loras: String = "", strength: Double = 0, duration: Double, index: Int = 0,
                     date: Date = Date()) async throws -> ImageRecord {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var name = Self.fileName(date: date, seed: seed, index: index)
        var n = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            n += 1
            name = name.replacingOccurrences(of: ".png", with: "") + "-\(n).png"
        }
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        let record = ImageRecord(createdAt: date, prompt: prompt, negativePrompt: negativePrompt, modelID: modelID, seed: seed,
                                 steps: steps, cfg: cfg, width: size.width, height: size.height, loras: loras,
                                 strength: strength, file: name, duration: duration)
        try await db.execute("""
            INSERT INTO image_generation (id, created_at, prompt, negative, model_id, seed, steps, width, height, file, duration_ms, cfg, loras, strength)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(record.id.uuidString), .double(date.timeIntervalSince1970), .text(prompt), .text(negativePrompt),
                  .text(modelID), .int(Int64(bitPattern: seed)), .int(Int64(steps)), .int(Int64(size.width)),
                  .int(Int64(size.height)), .text(name), .double(duration * 1000), .double(cfg), .text(loras), .double(strength)])
        return record
    }

    /// Newest first. Records whose file is gone (deleted in Finder) are dropped from the database.
    public func loadAll() async throws -> [ImageRecord] {
        let rows = try await db.query("SELECT * FROM image_generation ORDER BY created_at DESC")
        var out: [ImageRecord] = []
        var missing: [String] = []
        for row in rows {
            guard let idText = row["id"].text, let id = UUID(uuidString: idText), let file = row["file"].text,
                  Self.isSafeName(file) else { continue }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) else {
                missing.append(idText)
                continue
            }
            out.append(ImageRecord(
                id: id, createdAt: Date(timeIntervalSince1970: row["created_at"].double ?? 0),
                prompt: row["prompt"].text ?? "", negativePrompt: row["negative"].text ?? "",
                modelID: row["model_id"].text ?? "", seed: UInt64(bitPattern: row["seed"].int ?? 0),
                steps: Int(row["steps"].int ?? 0), cfg: row["cfg"].double ?? 0,
                width: Int(row["width"].int ?? 0), height: Int(row["height"].int ?? 0),
                loras: row["loras"].text ?? "", strength: row["strength"].double ?? 0,
                file: file, duration: (row["duration_ms"].double ?? 0) / 1000))
        }
        for id in missing { try? await db.execute("DELETE FROM image_generation WHERE id = ?", [.text(id)]) }
        return out
    }

    /// Deletes the record and its file.
    public func delete(_ record: ImageRecord) async throws {
        try await db.execute("DELETE FROM image_generation WHERE id = ?", [.text(record.id.uuidString)])
        if let url = url(for: record) { try? FileManager.default.removeItem(at: url) }
    }
}
