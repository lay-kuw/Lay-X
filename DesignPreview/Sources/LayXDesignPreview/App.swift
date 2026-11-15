import SwiftUI
import AppKit

@main
struct LayXDesignPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Lay X") {
            RootView()
                .environmentObject(state)
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
                Button(state.pinned ? "Unpin Chat" : "Pin Chat") { state.togglePin() }.keyboardShortcut("p")
                Button("Toggle Inspector") { withAnimation(LX.M.panel) { state.inspector.toggle() } }.keyboardShortcut("i")
                Button("Show Mini Chat  (⌥Space)") { MiniChatController.shared.toggle() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hotKey = GlobalHotKey { MiniChatController.shared.toggle() }
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
                self?.hideSystemButtons()
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

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }
}

// MARK: - App state (mock)

final class AppState: ObservableObject {
    static let shared = AppState()

    enum ChatPhase { case empty, generating, conversation }

    @Published var screen: Screen = .chat
    @Published var settingsCategory: SettingsScreen.Category = .appearance
    @Published var inspector = false

    // Chat
    @Published var phase: ChatPhase = .conversation
    @Published var pinned = false
    @Published var streamedText = ""
    @Published var draft = ""
    @Published var liveTPS: Double = 48.6
    private var streamTimer: Timer?

    var chatTitle: String { phase == .empty ? "Untitled" : "MLX streaming in SwiftUI" }

    func newChat() {
        stop()
        pinned = false
        phase = .empty
        screen = .chat
    }

    func togglePin() { withAnimation(LX.M.hover) { pinned.toggle() } }

    /// Simulates streaming: characters are buffered and flushed every 30 ms, as the design doc specifies.
    private let streamSource = Mock.answerIntro
    private var streamIndex = Mock.answerIntro.startIndex

    func send() {
        stop()
        streamedText = ""
        streamIndex = streamSource.startIndex
        phase = .generating
        streamTimer = Timer.scheduledTimer(withTimeInterval: LX.M.streamFlush, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard streamIndex < streamSource.endIndex else { finish(); return }
        let end = streamSource.index(streamIndex, offsetBy: 2, limitedBy: streamSource.endIndex) ?? streamSource.endIndex
        streamedText += streamSource[streamIndex..<end]
        streamIndex = end
        liveTPS = 46.5 + Double.random(in: 0...3)
    }

    func stop() {
        streamTimer?.invalidate()
        streamTimer = nil
        if phase == .generating { phase = .conversation }
    }

    private func finish() {
        streamTimer?.invalidate()
        streamTimer = nil
        liveTPS = 48.6
        phase = .conversation
    }
}
