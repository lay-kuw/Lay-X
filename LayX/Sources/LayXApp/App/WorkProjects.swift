import AppKit
import Foundation
import LayXCore

/// The user's authorised project folders and their Work sessions (one per project, in memory).
/// Only folder paths and bookmarks are persisted (UserDefaults) — never file contents or proposals.
@MainActor
@Observable
final class WorkProjects {
    struct Project: Codable, Hashable, Identifiable {
        var path: String
        var bookmark: Data?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    private(set) var projects: [Project] = []
    var currentID: String?
    private(set) var sessions: [String: WorkSession] = [:]
    var error: String?

    static let storageKey = "lx.workProjects"
    static let defaultWorkModelKey = "lx.defaultWorkModel"
    @ObservationIgnored private var accessing: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        }
        currentID = projects.first?.id
    }

    var current: Project? { projects.first { $0.id == currentID } }

    /// The Work session for the current project (created on first use).
    var currentSession: WorkSession? {
        guard let project = current else { return nil }
        return session(for: project)
    }

    func session(for project: Project) -> WorkSession? {
        if let s = sessions[project.id] { return s }
        let url = resolve(project)
        do {
            let ws = try Workspace(root: url)
            let services = AppServices.shared
            let s = WorkSession(workspace: ws, coordinator: services.coordinator, prepareModel: {
                guard let model = Self.defaultWorkModel(in: services.models) else { throw ChatSetupError.noModelInstalled }
                return try await services.coordinator.load(model.reference)
            })
            sessions[project.id] = s
            return s
        } catch {
            self.error = "“\(project.name)” isn’t available any more (moved or deleted?)."
            return nil
        }
    }

    static func defaultWorkModel(in library: ModelLibrary) -> InstalledModel? {
        if let id = UserDefaults.standard.string(forKey: defaultWorkModelKey), let m = library.model(id) { return m }
        return AppServices.defaultChatModel(in: library)
    }

    /// Native folder picker. The chosen folder becomes the only place Work can read or write.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Lay X can read files in this folder and propose changes. Nothing is written without your approval."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    func add(_ url: URL) {
        let path = ModelStore.canonicalPath(url)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if !projects.contains(where: { $0.path == path }) {
            projects.insert(Project(path: path, bookmark: bookmark), at: 0)
            save()
        }
        currentID = path
    }

    func remove(_ id: String) {
        sessions[id]?.cancel()
        sessions[id] = nil
        projects.removeAll { $0.id == id }
        if currentID == id { currentID = projects.first?.id }
        save()
    }

    private func resolve(_ project: Project) -> URL {
        if let data = project.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                // No-op outside the sandbox; required if Lay X is sandboxed later.
                if !accessing.contains(project.id), url.startAccessingSecurityScopedResource() { accessing.insert(project.id) }
                return url
            }
        }
        return URL(fileURLWithPath: project.path, isDirectory: true)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    /// Current git branch read from `.git/HEAD` (no shell commands are ever run).
    static func gitBranch(of root: URL) -> String? {
        guard let head = try? String(contentsOf: root.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst("ref: refs/heads/".count)) }
        return String(t.prefix(7))
    }
}
