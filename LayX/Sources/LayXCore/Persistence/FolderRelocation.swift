import Foundation

/// Moves a set of files between folders without ever losing one (Settings → Image Generation → Storage).
public enum FolderRelocation {
    /// Copy → verify → switch → delete originals. Throws before switching if the target already holds a file with
    /// one of the names (it would be shown in place of the original) or if any copy fails or differs in size; the
    /// copies made so far are removed then. Returns the number of files moved.
    public static func relocate(from old: URL, to new: URL, matching: @escaping @Sendable (String) -> Bool,
                         switchOver: @MainActor () -> Void) async throws -> Int {
        let plan = try await Task.detached(priority: .userInitiated) { () -> [String] in
            let fm = FileManager.default
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            guard ModelStore.canonicalPath(old) != ModelStore.canonicalPath(new) else { return [] }
            let names = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter { matching($0) && !$0.hasPrefix(".") }
            let clashes = names.filter { fm.fileExists(atPath: new.appendingPathComponent($0).path) }
            guard clashes.isEmpty else { throw RelocationError.conflicts(clashes.count, example: clashes[0]) }
            var copied: [URL] = []
            do {
                for name in names {
                    let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
                    try fm.copyItem(at: src, to: dst)
                    copied.append(dst)
                    let a = (try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value
                    let b = (try fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value
                    guard a == b else { throw RelocationError.verifyFailed(name) }
                }
            } catch {
                for url in copied { try? fm.removeItem(at: url) }
                throw error
            }
            return names
        }.value
        await switchOver()
        // The new folder is in use; the originals are now redundant copies.
        await Task.detached(priority: .utility) {
            for name in plan { try? FileManager.default.removeItem(at: old.appendingPathComponent(name)) }
        }.value
        return plan.count
    }

    public enum RelocationError: LocalizedError {
        case conflicts(Int, example: String)
        case verifyFailed(String)
        public var errorDescription: String? {
            switch self {
            case .conflicts(let n, let example):
                "That folder already has \(n) file\(n == 1 ? "" : "s") with the same name (e.g. \(example)). Choose an empty folder — nothing was moved."
            case .verifyFailed(let name): "Copying \(name) didn’t complete. Nothing was moved."
            }
        }
    }
}
