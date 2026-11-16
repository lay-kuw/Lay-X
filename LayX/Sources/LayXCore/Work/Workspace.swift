import CryptoKit
import Foundation

public enum WorkspaceError: Error, Equatable, Sendable, LocalizedError {
    case notADirectory(String)
    case outsideWorkspace(String)
    case invalidPath(String)
    case notFound(String)
    case notText(String)
    case tooLarge(String, Int64)
    case unreadable(String)
    case conflict([String])
    case applyFailed(String, rolledBack: Bool)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let p): "“\(p)” is not a folder."
        case .outsideWorkspace(let p): "“\(p)” is outside the project folder, so Lay X won’t touch it."
        case .invalidPath(let p): "“\(p)” isn’t a valid path inside the project."
        case .notFound(let p): "“\(p)” doesn’t exist."
        case .notText(let p): "“\(p)” isn’t a text file."
        case .tooLarge(let p, let size): "“\(p)” is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))."
        case .unreadable(let p): "“\(p)” couldn’t be read. Check that Lay X has access to the folder."
        case .conflict(let files):
            "These files changed after the proposal was made: \(files.joined(separator: ", ")). Ask for a refreshed proposal."
        case .applyFailed(let why, let rolledBack):
            rolledBack ? "The changes couldn’t be applied (\(why)). Every file was restored to its previous content."
                       : "The changes couldn’t be applied (\(why)). Some files may need checking."
        }
    }
}

/// A user-authorised project folder. Every path Work touches is resolved through `resolve(_:)`, which
/// canonicalises symlinks and rejects anything that ends up outside the root.
public struct Workspace: Sendable, Hashable {
    public let root: URL

    public static let maxFileBytes: Int64 = 1_000_000

    public init(root: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.notADirectory(root.path)
        }
        self.root = URL(fileURLWithPath: ModelStore.canonicalPath(root), isDirectory: true)
    }

    public var name: String { root.lastPathComponent }

    /// Resolves a project-relative path (as written by the user or the model) to a URL inside the workspace.
    public func resolve(_ relativePath: String) throws -> URL {
        var path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty, path.count < 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), !path.contains("\\")
        else { throw WorkspaceError.invalidPath(relativePath) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceError.outsideWorkspace(relativePath)
        }
        let url = root.appendingPathComponent(path)
        guard ModelStore.isContained(url, in: root) else { throw WorkspaceError.outsideWorkspace(relativePath) }
        return url
    }

    /// Project-relative path for a URL inside the workspace.
    public func relativePath(of url: URL) -> String? {
        let base = ModelStore.canonicalPath(root)
        let full = ModelStore.canonicalPath(url)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }
}

// MARK: - Text files (encoding + line endings preserved)

public enum LineEnding: String, Sendable, Codable, Hashable {
    case lf = "\n", crlf = "\r\n"
}

/// A text file's content plus what's needed to write it back the same way.
public struct TextFile: Sendable, Hashable {
    public var path: String
    /// Content normalised to "\n" line endings.
    public var text: String
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBOM: Bool
    /// SHA-256 of the bytes on disk when read (conflict detection).
    public var sha256: String

    public static func read(_ path: String, in workspace: Workspace) throws -> TextFile {
        let url = try workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(path) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Workspace.maxFileBytes else { throw WorkspaceError.tooLarge(path, size) }
        guard let data = try? Data(contentsOf: url) else { throw WorkspaceError.unreadable(path) }
        return try decode(data, path: path)
    }

    static func decode(_ data: Data, path: String) throws -> TextFile {
        var encoding: String.Encoding = .utf8
        var bom = false
        var body = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true
            body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; bom = true; body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; bom = true; body = data.dropFirst(2)
        }
        if encoding == .utf8, body.prefix(8000).contains(0) { throw WorkspaceError.notText(path) }
        guard let raw = String(data: body, encoding: encoding) else { throw WorkspaceError.notText(path) }
        let ending: LineEnding = raw.contains("\r\n") ? .crlf : .lf
        let text = ending == .crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        return TextFile(path: path, text: text, encoding: encoding, lineEnding: ending, hasBOM: bom,
                        sha256: Self.hash(data))
    }

    /// Bytes for `newText` using this file's encoding, BOM and line endings.
    public func encode(_ newText: String) -> Data? {
        let normalised = newText.replacingOccurrences(of: "\r\n", with: "\n")
        let raw = lineEnding == .crlf ? normalised.replacingOccurrences(of: "\n", with: "\r\n") : normalised
        guard var data = raw.data(using: encoding) else { return nil }
        if hasBOM {
            switch encoding {
            case .utf16LittleEndian: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            default: data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            }
        }
        return data
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new file (defaults: UTF-8, LF, no BOM).
    public static func new(_ path: String) -> TextFile {
        TextFile(path: path, text: "", encoding: .utf8, lineEnding: .lf, hasBOM: false, sha256: "")
    }
}

// MARK: - Scanning

public struct WorkspaceEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var depth: Int { path.split(separator: "/").count - 1 }
    public var name: String { String(path.split(separator: "/").last ?? "") }

    public init(path: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public enum WorkspaceScanner {
    /// Directories never descended into (build output, dependencies, VCS metadata).
    public static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".build", ".swiftpm", "build", "DerivedData", "node_modules", "Pods", "Carthage",
        ".venv", "venv", "__pycache__", ".idea", ".vscode", "dist", "target", ".next", ".cache", "xcuserdata",
    ]
    public static let textExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "mjs",
        "json", "yaml", "yml", "toml", "xml", "plist", "md", "txt", "html", "css", "scss", "sh", "zsh", "bash",
        "java", "kt", "kts", "gradle", "sql", "graphql", "proto", "ini", "cfg", "conf", "env", "gitignore",
        "dockerfile", "makefile", "cmake", "metal", "strings", "entitlements", "pbxproj", "xcconfig", "lua", "php",
        "cs", "fs", "dart", "vue", "svelte", "r", "jl", "ex", "exs", "erl", "hs", "ml", "scala", "clj", "tex",
    ]

    public static func isLikelyText(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return ["makefile", "dockerfile", "license", "readme", "gemfile", "podfile", "procfile"].contains(name) }
        return textExtensions.contains(ext)
    }

    /// Bounded, symlink-safe listing (symlinks are listed but never followed).
    public static func scan(_ workspace: Workspace, maxEntries: Int = 4000, maxDepth: Int = 12) -> [WorkspaceEntry] {
        var out: [WorkspaceEntry] = []
        let fm = FileManager.default
        func walk(_ dir: URL, _ prefix: String, _ depth: Int) {
            guard depth <= maxDepth, out.count < maxEntries,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            else { return }
            let sorted = items.sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return ad != bd ? ad : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            for item in sorted {
                guard out.count < maxEntries else { return }
                let name = item.lastPathComponent
                if name == ".DS_Store" { continue }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true { continue }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if values?.isDirectory == true {
                    if skippedDirectories.contains(name) || name.hasSuffix(".xcassets") || name.hasSuffix(".app") { continue }
                    out.append(WorkspaceEntry(path: path, isDirectory: true, size: 0))
                    walk(item, path, depth + 1)
                } else {
                    out.append(WorkspaceEntry(path: path, isDirectory: false, size: Int64(values?.fileSize ?? 0)))
                }
            }
        }
        walk(workspace.root, "", 0)
        return out
    }
}
