import Foundation

/// Default on-disk locations. Everything Lay X stores by default lives under `~/.config/lay-x/`:
///   models/    downloaded MLX models
///   database/  LayX.sqlite (pinned chats, benchmark results)
/// Both can be moved in Settings.
public enum LayXPaths {
    public static var configRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("lay-x", isDirectory: true)
    }
}
