import AppKit
import Carbon.HIToolbox
import SwiftUI
import LayXCore

// MARK: - Panel

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating Mini Chat panel. The conversation itself lives in the shared `ChatSessionStore`;
/// hiding the panel never discards it (it stays in the sidebar's Session list until quit, or forever if pinned).
final class MiniChatController {
    static let shared = MiniChatController()

    let model = MiniChatModel()
    private lazy var panel: MiniPanel = makePanel()
    private let panelSize = NSSize(width: 820, height: 600) // includes room for the shadow

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        // Appear on the display that has the mouse pointer (multi-display aware).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            let x = f.midX - panelSize.width / 2
            let topY = f.maxY - f.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: topY + 40))
        }
        model.prepareForShow()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        })
    }

    /// Shows the Mini Chat conversation in the main window.
    func openInMainWindow() {
        let state = AppState.shared
        if let id = model.sessionID, AppServices.shared.chats.session(id) != nil {
            state.currentChatID = id
        }
        state.screen = .chat
        hide()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> MiniPanel {
        let p = MiniPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isRestorable = false  // never restore (or snapshot) chat content across launches
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MiniChatView(model: model)
            .environment(AppServices.shared.inferenceStatus)
            .frame(width: panelSize.width, height: panelSize.height, alignment: .top))
        host.frame = NSRect(origin: .zero, size: panelSize)
        p.contentView = host
        return p
    }
}

// MARK: - Model

/// Mini Chat's pointer into the shared session store, plus its input draft.
@Observable
final class MiniChatModel {
    var input = ""
    var focusToken = 0
    /// The conversation shown in Mini Chat. Kept across show/hide.
    private(set) var sessionID: UUID?

    var chats: ChatSessionStore { AppServices.shared.chats }
    var session: ChatSession? { chats.session(sessionID) }
    var isGenerating: Bool { chats.isGenerating(sessionID) }

    func prepareForShow() {
        if session == nil { sessionID = nil }  // deleted from the main window meanwhile
        focusToken += 1
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        let id = sessionID.flatMap { chats.session($0) != nil ? $0 : nil } ?? chats.newSession()
        sessionID = id
        input = ""
        chats.send(text, in: id)
    }

    func newConversation() {
        guard !isGenerating else { return }
        sessionID = nil
        input = ""
        focusToken += 1
    }

    func togglePin() {
        guard let id = sessionID, session?.messages.isEmpty == false else { return }
        chats.togglePin(id)
    }

    func stop() {
        if let id = sessionID { chats.stop(id) }
    }
}

// MARK: - View

struct MiniChatView: View {
    @Bindable var model: MiniChatModel
    @Environment(InferenceStatusModel.self) private var inference
    @AppStorage(LX.Glass.storageKey) private var storedTransparency = LX.Glass.defaultValue
    @AppStorage(AppearancePreferences.followReduceTransparencyKey) private var followReduce = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LX.Glass.fullGlassKey) private var fullGlass = false
    private var transparency: Double { followReduce && reduceTransparency ? 0 : storedTransparency }
    private var miniTint: Double { LX.Glass.tintScale(transparency) * (fullGlass && !(followReduce && reduceTransparency) ? LX.Glass.fullGlassScale : 1) }
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    private var lastReply: ChatMessage? {
        guard let s = model.session, let last = s.messages.last else { return nil }
        return last.role == .assistant ? last : nil
    }
    private var hasContent: Bool { model.session?.messages.isEmpty == false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Ask \(modelName) — on this Mac", text: $model.input, selection: $selection, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(LX.F.ui(16))
                    .foregroundStyle(Color.white)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        insertNewline()
                        return .handled
                    }
                    .onSubmit { model.submit() }
                if model.isGenerating {
                    Text("generating…").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(minHeight: 54)

            if model.isGenerating {
                GeneratingRibbon()
            } else if hasContent {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }

            if hasContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        if let reply = lastReply {
                            let parts = ThinkingParser.split(reply.content)
                            if parts.isThinking && parts.answer.isEmpty {
                                Text("Thinking…").font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                            }
                            MarkdownView(text: parts.answer, compact: true)
                            if model.isGenerating { BlinkingCaret() }
                        } else if model.isGenerating {
                            BlinkingCaret()
                        }
                        if let id = model.sessionID, let error = model.chats.errors[id] {
                            Text(error).font(LX.F.ui(12.5)).foregroundStyle(LX.C.error)
                        }
                    }
                    .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))

                footer
            }
        }
        .frame(width: 740)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blending: .behindWindow)
                LX.C.mini.opacity(miniTint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.1)), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
        .padding(.top, 40)
        .animation(LX.M.mini, value: hasContent)
        .animation(LX.M.mini, value: model.isGenerating)
        .onChange(of: model.focusToken) { focused = true }
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            if model.isGenerating { model.stop() } else { MiniChatController.shared.hide() }
            return .handled
        }
        .background {
            // Invisible buttons provide the panel's keyboard shortcuts.
            Group {
                Button("") { MiniChatController.shared.openInMainWindow() }.keyboardShortcut(.return, modifiers: .command)
                Button("") { model.togglePin() }.keyboardShortcut("p", modifiers: .command)
                Button("") { model.newConversation() }.keyboardShortcut("n", modifiers: .command)
            }
            .opacity(0)
        }
    }

    private var modelName: String {
        if let id = inference.loadedModel?.id, let r = ModelRepoID(id) { return ModelDisplay.name(r) }
        return AppServices.defaultChatModel(in: AppServices.shared.models).map { ModelDisplay.name($0.id) } ?? "Lay X"
    }

    private var footer: some View {
        let metrics = lastReply?.metrics
        return HStack(spacing: 4) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if inference.loadedModel != nil { LiveDot() }
                    Text(modelName).foregroundStyle(LX.C.secondary)
                }
                if let metrics {
                    Text(String(format: "%.0fms", metrics.timeToFirstToken.milliseconds))
                    if let tps = metrics.decodeTokensPerSecond { Text(String(format: "%.1f tok/s", tps)) }
                }
                Tag(text: model.session?.isPinned == true ? "PINNED" : "TEMP", color: LX.C.accentText)
            }
            .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            Spacer()
            footerAction("New") { model.newConversation() }
            footerAction(model.session?.isPinned == true ? "Unpin" : "Pin") { model.togglePin() }
            footerAction("Open in Chat", emphasized: true) { MiniChatController.shared.openInMainWindow() }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func footerAction(_ title: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LX.F.ui(12)).foregroundStyle(LX.C.body)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(Color.white.opacity(emphasized ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
    }

    private func insertNewline() {
        let text = model.input
        if case .selection(let range)? = selection?.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            var updated = text
            updated.replaceSubrange(range, with: "\n")
            let caret = updated.index(updated.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.lowerBound) + 1)
            model.input = updated
            selection = TextSelection(insertionPoint: caret)
        } else {
            model.input += "\n"
        }
    }
}

// MARK: - Global hot key

/// Registers the Mini Chat shortcut with Carbon's `RegisterEventHotKey` (no Accessibility permission needed).
/// Registration failures (e.g. the shortcut is owned by another app) are reported, not ignored.
@Observable
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let storageKey = "lx.miniHotKey"

    private(set) var status: HotKeyStatus = .disabled
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored fileprivate static var action: (() -> Void)?

    var current: HotKeySpec? {
        HotKeySpec.decode(UserDefaults.standard.string(forKey: Self.storageKey)) ?? .default
    }

    /// Installs the event handler once and registers the saved shortcut.
    func start(action: @escaping () -> Void) {
        Self.action = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        apply(current)
    }

    /// Changes the shortcut (nil = off). The previous one is released first.
    func set(_ spec: HotKeySpec?) {
        UserDefaults.standard.set(HotKeySpec.encode(spec), forKey: Self.storageKey)
        apply(spec)
    }

    private func apply(_ spec: HotKeySpec?) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let spec else { status = .disabled; return }
        let id = EventHotKeyID(signature: OSType(0x4C_41_59_58), id: 1) // 'LAYX'
        let result = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        status = HotKeyStatus.from(osStatus: result, spec: spec)
        if result != noErr {
            hotKeyRef = nil
            Log.app.notice("Mini Chat shortcut registration failed: \(result)")
        }
    }
}
