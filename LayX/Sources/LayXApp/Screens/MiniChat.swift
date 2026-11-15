import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Panel

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MiniChatController {
    static let shared = MiniChatController()

    private let model = MiniChatModel()
    private lazy var panel: MiniPanel = makePanel()
    private let panelSize = NSSize(width: 820, height: 600) // includes room for the shadow

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let x = f.midX - panelSize.width / 2
            let topY = f.maxY - f.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: topY + 40))
        }
        model.focusToken += 1
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
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.model.discardIfTemporary()
            }
        })
    }

    func openInMainWindow() {
        let state = AppState.shared
        state.screen = .chat
        state.pinned = model.pinned
        state.phase = .conversation
        hide()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MiniChatView(model: model).frame(width: panelSize.width, height: panelSize.height, alignment: .top))
        host.frame = NSRect(origin: .zero, size: panelSize)
        p.contentView = host
        return p
    }
}

// MARK: - Model

final class MiniChatModel: ObservableObject {
    enum Phase { case idle, generating, answered }
    @Published var input = ""
    @Published var phase: Phase = .idle
    @Published var streamed = ""
    @Published var pinned = false
    @Published var focusToken = 0
    private var timer: Timer?
    private var index = Mock.miniAnswer.startIndex

    func submit() {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        timer?.invalidate()
        streamed = ""
        index = Mock.miniAnswer.startIndex
        withAnimation(LX.M.mini) { phase = .generating }
        timer = Timer.scheduledTimer(withTimeInterval: LX.M.streamFlush, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let src = Mock.miniAnswer
        guard index < src.endIndex else {
            timer?.invalidate(); timer = nil
            withAnimation(LX.M.mini) { phase = .answered }
            return
        }
        let end = src.index(index, offsetBy: 2, limitedBy: src.endIndex) ?? src.endIndex
        streamed += src[index..<end]
        index = end
    }

    func discardIfTemporary() {
        guard !pinned else { return }
        timer?.invalidate(); timer = nil
        input = ""; streamed = ""; phase = .idle
    }
}

// MARK: - View

struct MiniChatView: View {
    @ObservedObject var model: MiniChatModel
    @AppStorage(LX.Glass.storageKey) private var transparency = LX.Glass.defaultValue
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Ask Qwen3 14B — on this Mac", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(LX.F.ui(16))
                    .foregroundStyle(Color.white)
                    .focused($focused)
                    .onSubmit { model.submit() }
                if model.phase == .generating {
                    Text("47.9 tok/s").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan)
                } else if model.phase == .idle {
                    Keycap(text: "↵")
                } else {
                    contextChip
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if model.phase == .generating {
                GeneratingRibbon()
            } else if model.phase == .answered {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }

            if model.phase != .idle {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(model.streamed).font(LX.F.ui(13.5)).foregroundStyle(LX.C.body).lineSpacing(5)
                        if model.phase == .generating { BlinkingCaret() }
                    }
                    if model.phase == .answered {
                        Text(Syntax.highlight(Mock.miniDiff).diffColored())
                            .font(LX.F.mono(12)).lineSpacing(4)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .well(radius: 8, fill: LX.C.code)
                    }
                }
                .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))

                footer
            }
        }
        .frame(width: 740)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blending: .behindWindow)
                LX.C.mini.opacity(LX.Glass.tintScale(transparency))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.1)), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
        .padding(.top, 40)
        .animation(LX.M.mini, value: model.phase)
        .onChange(of: model.focusToken) { focused = true }
        .onAppear { focused = true }
        .onKeyPress(.escape) { MiniChatController.shared.hide(); return .handled }
        .background {
            // Invisible buttons provide the panel's keyboard shortcuts.
            Group {
                Button("") { MiniChatController.shared.openInMainWindow() }.keyboardShortcut(.return, modifiers: .command)
                Button("") { model.pinned.toggle() }.keyboardShortcut("p", modifiers: .command)
            }
            .opacity(0)
        }
    }

    private var contextChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9, weight: .semibold))
            Text("Xcode · 24 lines")
        }
        .font(LX.F.mono(10.5))
        .foregroundStyle(LX.C.accentText)
        .padding(.horizontal, 8).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(LX.C.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LX.C.accent.opacity(0.3), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            HStack(spacing: 10) {
                HStack(spacing: 6) { LiveDot(); Text("Qwen3 14B").foregroundStyle(LX.C.secondary) }
                Text("182ms")
                Text("51.2 tok/s")
                Tag(text: model.pinned ? "PINNED" : "TEMP", color: LX.C.accentText)
            }
            .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            Spacer()
            footerAction("Insert", "⌘I") {}
            footerAction(model.pinned ? "Unpin" : "Pin", "⌘P") { model.pinned.toggle() }
            footerAction("Open in Chat", "⌘↩") { MiniChatController.shared.openInMainWindow() }
            footerAction("Actions", "⌘K", emphasized: true) {}
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func footerAction(_ title: String, _ key: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) { Text(title); Keycap(text: key) }
                .font(LX.F.ui(12)).foregroundStyle(LX.C.body)
                .padding(.leading, 8).padding(.trailing, 5).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(Color.white.opacity(emphasized ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
    }
}

private extension AttributedString {
    /// Colors whole diff lines: "+" green, "-" muted.
    func diffColored() -> AttributedString {
        var out = AttributedString()
        for line in String(characters).split(separator: "\n", omittingEmptySubsequences: false) {
            var a = AttributedString(String(line) + "\n")
            a.foregroundColor = line.hasPrefix("+") ? LX.C.ok : (line.hasPrefix("-") ? LX.C.tertiary : LX.C.body)
            out += a
        }
        return out
    }
}

// MARK: - Global hot key (⌥Space)

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate static var action: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping () -> Void) {
        GlobalHotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4C_41_59_58), id: 1) // 'LAYX'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
