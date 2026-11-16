import SwiftUI
import AppKit
import LayXCore
#if canImport(LayXMLX)
import LayXMLX
#endif

/// Process entry point. `--mlx-selftest` runs a GPU round-trip and exits (used by scripts/build-app.sh).
@main
enum LayXMain {
    static func main() {
        #if canImport(LayXMLX)
        if CommandLineTools.handle(CommandLine.arguments) { return }
        #endif
        LayXApplication.main()
    }
}

struct LayXApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Lay X") {
            RootView()
                .environmentObject(state)
                .environment(AppServices.shared.inferenceStatus)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { state.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("Go") {
                ForEach(Screen.allCases) { screen in
                    Button(screen.title) { state.screen = screen }
                        .keyboardShortcut(screen.shortcut, modifiers: .command)
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Appearance…") { state.screen = .settings; state.settingsCategory = .appearance }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
            CommandMenu("Chat") {
                Button(state.chats.session(state.currentChatID)?.isPinned == true ? "Unpin Chat" : "Pin Chat") { state.togglePin() }
                    .keyboardShortcut("p")
                Button("Toggle Inspector") { withAnimation(LX.M.panel) { state.inspector.toggle() } }.keyboardShortcut("i")
                Button("Show Mini Chat") { MiniChatController.shared.toggle() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no app bundle).
        _ = AppServices.shared  // open the database and start the inference coordinator
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        GlobalHotKey.shared.start { MiniChatController.shared.toggle() }
    }

    /// Unpinned chats are memory-only: never let AppKit restore windows (and their content) on relaunch.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Stops generations and waits for queued pinned-chat writes before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let chats = AppServices.shared.chats
        chats.cancelAll()
        Task { @MainActor in
            await chats.flushWrites()
            await AppServices.shared.coordinator.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Makes the window transparent so the wallpaper shows through the glass,
/// and hides the system traffic lights (Lay X draws its own inside the sidebar pane).
struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> WindowChrome { WindowChrome() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.isRestorable = false
            context.coordinator.attach(to: window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the system window buttons hidden (AppKit can restore them after full screen).
final class WindowChrome {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow) {
        self.window = window
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didEndLiveResizeNotification,
        ]
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideSystemButtons() }
            }
        }
        hideSystemButtons()
    }

    func hideSystemButtons() {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
    }

    isolated deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }
}

// MARK: - App state

/// Window-level UI state (navigation, current chat, draft). Conversation content lives in `ChatSessionStore`.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var screen: Screen = .chat
    @Published var settingsCategory: SettingsScreen.Category = .appearance
    @Published var inspector = false
    @Published var modelsTab: ModelsScreen.Tab = .installed

    /// Session shown in the main window's Chat screen.
    @Published var currentChatID: UUID?
    @Published var draft = ""
    /// Header title is in edit mode.
    @Published var renamingChat = false

    var chats: ChatSessionStore { AppServices.shared.chats }

    /// Ensures there is a current session (an empty temporary one if needed) and returns its id.
    @discardableResult
    func ensureCurrentChat() -> UUID {
        if let id = currentChatID, chats.session(id) != nil { return id }
        let id = chats.newSession()
        currentChatID = id
        return id
    }

    func newChat() {
        renamingChat = false
        currentChatID = chats.newSession()
        draft = ""
        screen = .chat
    }

    func togglePin() {
        guard let id = currentChatID, let s = chats.session(id), !s.messages.isEmpty else { return }
        withAnimation(LX.M.hover) { chats.togglePin(id) }
    }

    func send(_ text: String) {
        let id = ensureCurrentChat()
        chats.send(text, in: id)
    }

    func stop() {
        if let id = currentChatID { chats.stop(id) }
    }

    func deleteChat(_ id: UUID) {
        chats.delete(id)
        if currentChatID == id { currentChatID = chats.temporarySessions.first?.id ?? chats.pinnedSessions.first?.id }
    }
}
