import AppKit
import SwiftUI
import LayXCore

struct ChatScreen: View {
    @EnvironmentObject var state: AppState
    @State private var pickerOpen = false
    @Environment(InferenceStatusModel.self) private var inference
    private var chats: ChatSessionStore { AppServices.shared.chats }
    private var session: ChatSession? { chats.session(state.currentChatID) }
    private var isEmpty: Bool { session?.messages.isEmpty ?? true }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if isEmpty {
                    EmptyChat()
                        .transition(.opacity)
                } else if let session {
                    ChatThread(session: session)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Composer()
                .frame(width: LX.S.readingWidth)
                .padding(.bottom, 14)
        }
        .animation(.easeOut(duration: 0.18), value: isEmpty)
        .overlay(alignment: .topLeading) {
            if pickerOpen {
                ZStack(alignment: .topLeading) {
                    // Click outside to dismiss.
                    Color.black.opacity(0.001).onTapGesture { withAnimation(LX.M.mini) { pickerOpen = false } }
                    ModelPickerPanel(open: $pickerOpen)
                        .padding(.top, LX.S.header + 2).padding(.leading, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                }
            }
        }
    }

    // MARK: Header
    private var header: some View {
        ScreenHeader {
            ModelPicker(open: $pickerOpen)
            Text("/").font(LX.F.body).foregroundStyle(Color(hex: 0x5E6172))
            ChatTitle()
            if session?.isPinned != true { Tag(text: "TEMP", color: LX.C.accentText) }
        } trailing: {
            let metrics = session?.messages.last(where: { $0.metrics != nil })?.metrics
            MetricsStrip(
                ttft: metrics.map { String(format: "%.0fms", $0.timeToFirstToken.milliseconds) } ?? "—",
                tps: metrics?.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—",
                memory: inference.engineMemory.map { String(format: "%.1f", Double($0.activeBytes) / 1_073_741_824) } ?? "—",
                live: chats.isGenerating(state.currentChatID))
            let pinned = session?.isPinned == true
            IconButton(symbol: pinned ? "star.fill" : "star",
                       help: pinned ? "Unpin — the saved copy is removed; the chat stays open until you quit" : "Pin — save this chat on this Mac",
                       active: pinned) { state.togglePin() }
                .disabled(isEmpty)
            IconButton(symbol: "plus", help: "New chat") { state.newChat() }
            IconButton(symbol: "sidebar.right", help: "Inspector") { withAnimation(LX.M.panel) { state.inspector.toggle() } }
        }
    }
}

// MARK: - Title (click to rename)

struct ChatTitle: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @FocusState private var focused: Bool
    private var chats: ChatSessionStore { AppServices.shared.chats }

    var body: some View {
        let session = chats.session(state.currentChatID)
        Group {
            if state.renamingChat, let session {
                TextField("Title", text: $text)
                    .textFieldStyle(.plain)
                    .font(LX.F.ui(13, .medium)).foregroundStyle(LX.C.primary)
                    .frame(width: 260)
                    .padding(.horizontal, 6).frame(height: 24)
                    .well(radius: LX.R.sm, fill: Color.black.opacity(0.28))
                    .focused($focused)
                    .onAppear { text = session.title; focused = true }
                    .onSubmit { commit(session.id) }
                    .onKeyPress(.escape) { state.renamingChat = false; return .handled }
                    .onChange(of: focused) { _, now in if !now { commit(session.id) } }
            } else {
                Text(session?.title ?? "Untitled").font(LX.F.ui(13, .medium)).foregroundStyle(Color(hex: 0xC9CBD6))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1) {
                        if session?.messages.isEmpty == false { state.renamingChat = true }
                    }
                    .help("Click to rename")
            }
        }
        .onChange(of: state.currentChatID) { state.renamingChat = false }
    }

    private func commit(_ id: UUID) {
        guard state.renamingChat else { return }
        chats.rename(id, to: text)
        state.renamingChat = false
    }
}

// MARK: - Model picker

/// Header model picker label (chip icon, name, variant · quant · context). Opens `ModelPickerPanel`.
struct ModelPicker: View {
    @Binding var open: Bool
    @Environment(InferenceStatusModel.self) private var inference
    @State private var hover = false
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        Button { withAnimation(LX.M.mini) { open.toggle() } } label: {
            HStack(spacing: 10) {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "cpu").font(.system(size: 15, weight: .regular)).foregroundStyle(LX.C.accentText)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(LX.F.ui(13, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                    Text(subtitle).font(LX.F.ui(11)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .padding(.leading, 6)
            }
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: LX.R.lg, style: .continuous).fill(Color.white.opacity(open ? 0.06 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
        .help("Choose model")
        .background { Button("") { withAnimation(LX.M.mini) { open.toggle() } }.keyboardShortcut("m").opacity(0) }
    }

    private var isLoading: Bool { if case .loading = inference.snapshot.model { true } else { false } }

    private var current: InstalledModel? {
        switch inference.snapshot.model {
        case .ready(let info): return library.model(info.id)
        case .loading(let id, _): return library.model(id)
        default: return AppServices.defaultChatModel(in: library)
        }
    }

    private var title: String {
        if let m = current { return ModelDisplay.split(m.id).name }
        return library.installed.isEmpty ? "No model" : "Choose a model"
    }

    private var subtitle: String {
        if isLoading { return "Loading…" }
        if case .failed = inference.snapshot.model { return "Failed to load" }
        guard let m = current else { return library.installed.isEmpty ? "Download one in Models" : "" }
        let s = ModelDisplay.subtitle(m, withSize: false)
        return inference.loadedModel == nil ? (s.isEmpty ? "Not loaded" : "\(s) · not loaded") : s
    }
}

/// Floating model list (same corner radius and glass as the window): Loaded / Available / Manage Models.
struct ModelPickerPanel: View {
    @Binding var open: Bool
    @EnvironmentObject var state: AppState
    @Environment(InferenceStatusModel.self) private var inference
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let loadedID = inference.loadedModel?.id
        let loadingID: String? = { if case .loading(let id, _) = inference.snapshot.model { id } else { nil } }()
        let loaded = library.installed.filter { $0.id.description == loadedID || $0.id.description == loadingID }
        let available = library.installed.filter { $0.id.description != loadedID && $0.id.description != loadingID }
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !loaded.isEmpty {
                        header("Loaded")
                        ForEach(loaded) { m in row(m, active: m.id.description == loadedID, loading: m.id.description == loadingID) }
                    }
                    if !available.isEmpty {
                        header("Available").padding(.top, loaded.isEmpty ? 0 : 8)
                        ForEach(available) { m in row(m, active: false, loading: false) }
                    }
                    if library.installed.isEmpty {
                        Text("No models installed yet.").font(LX.F.body).foregroundStyle(LX.C.tertiary).padding(12)
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            PickerRowButton {
                state.modelsTab = .installed
                state.screen = .models
                close()
            } content: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(LX.C.accentText).frame(width: 18)
                    Text("Manage Models").font(LX.F.ui(12.5, .medium)).foregroundStyle(LX.C.accentText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 32)
            }
            .padding(4)
        }
        .frame(width: 300)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).fill(LX.C.overlay.opacity(0.88))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous).strokeBorder(LX.C.edge, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: LX.R.window, style: .continuous)
            .strokeBorder(LinearGradient(colors: [LX.C.highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 18)
        .background { Button("") { close() }.keyboardShortcut(.escape, modifiers: []).opacity(0) }
    }

    private func close() { withAnimation(LX.M.mini) { open = false } }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).font(LX.F.ui(9.5, .semibold)).kerning(0.8).foregroundStyle(LX.C.tertiary)
            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 3)
    }

    private func row(_ m: InstalledModel, active: Bool, loading: Bool) -> some View {
        let parts = ModelDisplay.split(m.id)
        return PickerRowButton(selected: active) {
            UserDefaults.standard.set(m.id.description, forKey: ChatPreferences.defaultChatModelKey)
            if !active && !loading { library.load(m) }
            close()
        } content: {
            HStack(spacing: 9) {
                Group {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: active ? "checkmark" : "cpu").font(.system(size: active ? 11 : 13, weight: active ? .semibold : .regular)) }
                }
                .foregroundStyle(active ? LX.C.accentText : LX.C.tertiary)
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.name).font(LX.F.ui(12.5, .semibold)).foregroundStyle(LX.C.primary).lineLimit(1)
                    Text(ModelDisplay.subtitle(m, withSize: true)).font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if loading {
                    Text("Loading").font(LX.F.ui(10.5)).foregroundStyle(LX.C.tertiary)
                } else if active {
                    Text("Active").font(LX.F.ui(10.5, .semibold)).foregroundStyle(LX.C.onGlass)
                        .padding(.horizontal, 7).frame(height: 19)
                        .accentGlass(radius: LX.R.xs, strength: 0.8)
                } else {
                    Menu {
                        Button("Load") { library.load(m); close() }
                        Button("Use for New Chats") { UserDefaults.standard.set(m.id.description, forKey: ChatPreferences.defaultChatModelKey) }
                        Divider()
                        Button("Show in Models") { state.modelsTab = .installed; state.screen = .models; close() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(.horizontal, 9).frame(height: 42)
        }
    }
}

/// Full-width hoverable row used in the model panel.
private struct PickerRowButton<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
                    .fill(selected ? LX.C.accent.opacity(hover ? 0.16 : 0.12) : Color.white.opacity(hover ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(LX.M.hover) { hover = h } }
    }
}

// MARK: - Thread

struct ChatThread: View {
    let session: ChatSession
    @Environment(InferenceStatusModel.self) private var inference
    private var chats: ChatSessionStore { AppServices.shared.chats }
    @State private var followBottom = true

    var body: some View {
        let generating = chats.isGenerating(session.id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let omitted = chats.omittedMessages[session.id] {
                        Text("\(omitted) earlier message\(omitted == 1 ? "" : "s") didn’t fit the model’s context window and \(omitted == 1 ? "was" : "were") left out of the last reply.")
                            .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                    }
                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                        let isLast = index == session.messages.count - 1
                        MessageView(message: message, streaming: generating && isLast && message.role == .assistant)
                        if isLast && message.role == .assistant && !generating {
                            MessageActions(sessionID: session.id, message: message)
                        }
                    }
                    if generating && session.messages.last?.role == .user {
                        // Waiting for the model to load / prefill.
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text(modelName).font(LX.F.ui(12.5, .semibold))
                                Text(statusText).font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan)
                            }
                            BlinkingCaret()
                        }
                    }
                    if let error = chats.errors[session.id] {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(LX.C.error)
                            Text(error).font(LX.F.body).foregroundStyle(LX.C.body).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            LXButton(title: "Retry") { chats.regenerate(session.id) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .well(radius: LX.R.lg)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(width: LX.S.readingWidth, alignment: .leading)
                .padding(.top, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, nearBottom in
                followBottom = nearBottom
            }
            .onChange(of: session.messages.last?.content.count) {
                if followBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.messages.count) {
                followBottom = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.id) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var modelName: String {
        let id = inference.loadedModel?.id ?? { if case .loading(let id, _) = inference.snapshot.model { id } else { nil } }()
        return id.flatMap(ModelRepoID.init).map(ModelDisplay.name) ?? "Model"
    }

    private var statusText: String {
        if let web = chats.webStatus[session.id] { return web }
        if case .loading = inference.snapshot.model { return "loading model…" }
        if inference.snapshot.activeClient != nil && inference.snapshot.activeClient != .chat { return "waiting…" }
        return "thinking…"
    }
}

struct MessageView: View, Equatable {
    let message: ChatMessage
    var streaming = false
    /// Reasoning is collapsed unless the user opens it (nil = default collapsed).
    @State private var reasoningExpanded: Bool?

    static func == (a: MessageView, b: MessageView) -> Bool { a.message == b.message && a.streaming == b.streaming }

    var body: some View {
        if message.role == .user { userBody } else { assistantBody }
    }

    /// The user's turn sits on the right in a quiet bubble.
    private var userBody: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(meta).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                    Text("You").font(LX.F.ui(12.5, .semibold))
                }
                Text(message.content).font(LX.F.bodyLarge).foregroundStyle(LX.C.body).lineSpacing(6)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: LX.R.xl, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(author).font(LX.F.ui(12.5, .semibold))
                if streaming {
                    Text("streaming…").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan)
                } else {
                    Text(meta).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                }
            }
            if message.role == .assistant {
                let parts = ThinkingParser.split(message.content)
                if let thinking = parts.thinking {
                    let expanded = reasoningExpanded ?? false
                    Button { withAnimation(LX.M.hover) { reasoningExpanded = !expanded } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                            if parts.isThinking { LiveDot(color: LX.C.liveCyan) }
                            Text(parts.isThinking ? "Thinking…" : "Reasoning")
                            if !parts.isThinking { Text("· \(thinking.count.formatted()) chars").foregroundStyle(LX.C.tertiary) }
                        }
                        .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        Text(thinking).font(LX.F.bodySmall).foregroundStyle(LX.C.tertiary).lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
                    }
                }
                if let note = message.webNote {
                    Label(note, systemImage: "globe").font(LX.F.caption).foregroundStyle(LX.C.tertiary)
                }
                MarkdownView(text: parts.answer)
                if streaming && !parts.isThinking { BlinkingCaret() }
                if !message.sources.isEmpty && !streaming { WebSourcesView(sources: message.sources) }
            } else {
                Text(message.content).font(LX.F.bodyLarge).foregroundStyle(LX.C.body).lineSpacing(6).textSelection(.enabled)
            }
        }
    }

    private var author: String {
        switch message.role {
        case .user: "You"
        case .system: "System"
        case .assistant: message.modelID.flatMap(ModelRepoID.init).map(ModelDisplay.name) ?? "Assistant"
        }
    }

    private var meta: String {
        switch message.role {
        case .assistant:
            var parts: [String] = []
            if let m = message.metrics {
                parts.append("\(m.generatedTokens) tok")
                parts.append(String(format: "%.1f s", m.totalDuration.seconds))
            }
            if message.interrupted { parts.append("stopped") }
            return parts.joined(separator: " · ")
        default:
            return message.createdAt.formatted(date: .omitted, time: .standard)
        }
    }
}

/// Copy / regenerate under the latest reply.
struct MessageActions: View {
    let sessionID: UUID
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy reply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ThinkingParser.stripThinking(message.content), forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            IconButton(symbol: "arrow.clockwise", help: "Regenerate") { AppServices.shared.chats.regenerate(sessionID) }
        }
        .padding(.top, -12)
        .padding(.leading, -6)
    }
}

/// Renders Markdown blocks with the design system's typography.
struct MarkdownView: View {
    let text: String
    /// Mini Chat uses a slightly smaller body size (13.5 vs 14).
    var compact = false
    private var bodyFont: Font { compact ? LX.F.ui(13.5) : LX.F.bodyLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    inline(s).font(bodyFont).foregroundStyle(LX.C.body).lineSpacing(compact ? 5 : 6)
                case .heading(let level, let s):
                    inline(s).font(LX.F.ui(level <= 1 ? 17 : (level == 2 ? 15.5 : 14), .semibold)).foregroundStyle(LX.C.primary)
                        .padding(.top, 4)
                case .listItem(let marker, let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(bodyFont).foregroundStyle(LX.C.tertiary)
                        inline(s).font(bodyFont).foregroundStyle(LX.C.body).lineSpacing(compact ? 5 : 6)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                    .padding(.top, -6)
                case .code(let lang, let code, _):
                    CodeBlock(language: lang ?? "", filename: "", code: code)
                case .quote(let s):
                    inline(s).font(bodyFont).foregroundStyle(LX.C.secondary).lineSpacing(compact ? 5 : 6)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(LX.C.accent.opacity(0.4)).frame(width: 2) }
                case .rule:
                    Rectangle().fill(LX.C.divider).frame(height: 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: s, options: options) else { return Text(s) }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = LX.F.mono(12.5)
            attributed[run.range].foregroundColor = LX.C.accentText
        }
        return Text(attributed)
    }
}

// MARK: - Empty state

struct EmptyChat: View {
    @EnvironmentObject var state: AppState
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEW SESSION · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                Text("What are we building?").font(LX.F.display).kerning(-0.4)
                Text(library.installed.isEmpty
                     ? "Download a model in Models to start. Everything runs on this Mac."
                     : "Temporary until you pin it. Nothing leaves this Mac.")
                    .font(LX.F.body).foregroundStyle(LX.C.secondary)
            }
            if library.installed.isEmpty {
                LXButton(title: "Open Models", symbol: "shippingbox", kind: .primary) {
                    state.modelsTab = .discover
                    state.screen = .models
                }
            }
        }
        .frame(width: 520)
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var state: AppState
    @Environment(\.fullGlass) private var fullGlass
    @Environment(InferenceStatusModel.self) private var inference
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    @AppStorage(ChatPreferences.thinkingKey) private var thinking = ChatPreferences.defaultThinking
    private var chats: ChatSessionStore { AppServices.shared.chats }
    private var generating: Bool { chats.isGenerating(state.currentChatID) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $state.draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LX.F.bodyLarge)
                .lineLimit(1...6)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }  // plain Return → onSubmit
                    insertNewline()
                    return .handled
                }
                .onSubmit { submit() }
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)
            HStack(spacing: 6) {
                Button { thinking.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: thinking ? "brain" : "bolt").font(.system(size: 10, weight: .medium))
                        Text(thinking ? "Thinking" : "No thinking")
                    }
                    .font(LX.F.caption)
                    .padding(.horizontal, 8).frame(height: 24)
                }
                .buttonStyle(QuietButtonStyle(radius: LX.R.sm, active: thinking))
                WebSearchMenu()
                .help("Click to switch reasoning on or off for models that support it (e.g. Qwen3). Other models ignore it.")
                Spacer()
                contextMeter
                if generating {
                    SendButton(mode: .stop) { state.stop() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    SendButton(mode: .send, enabled: !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { submit() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.leading, 8).padding(.trailing, 7).frame(height: 38)
        }
        .background {
            ZStack {
                if !fullGlass { RoundedRectangle(cornerRadius: LX.R.xl).fill(.ultraThinMaterial) }
                RoundedRectangle(cornerRadius: LX.R.xl).fill(Color(hex: 0x080910, alpha: fullGlass ? 0.3 : 0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.xl))
        .overlay(RoundedRectangle(cornerRadius: LX.R.xl).strokeBorder(Color.white.opacity(focused ? 0.16 : 0.09), lineWidth: 1))
        .overlay { if generating { GlowingBorder(radius: LX.R.xl).transition(.opacity) } }
        .shadow(color: .black.opacity(0.35), radius: 20, y: 16)
        .animation(.easeInOut(duration: 0.3), value: generating)
        .animation(LX.M.hover, value: focused)
        .onAppear { focused = true }
        .onChange(of: state.currentChatID) { focused = true }
    }

    private var modelName: String {
        if let id = inference.loadedModel?.id, let r = ModelRepoID(id) { return ModelDisplay.name(r) }
        return AppServices.defaultChatModel(in: AppServices.shared.models).map { ModelDisplay.name($0.id) } ?? "the model"
    }

    private var placeholder: String {
        let empty = chats.session(state.currentChatID)?.messages.isEmpty ?? true
        return empty ? "Ask \(modelName) anything" : "Message \(modelName)"
    }

    /// Estimated prompt size vs. the model's context window.
    private var contextMeter: some View {
        let messages = chats.session(state.currentChatID)?.messages ?? []
        let used = messages.reduce(PromptBuilder.estimateTokens(state.draft)) { $0 + PromptBuilder.estimateTokens($1.content) }
        let ctx = inference.loadedModel?.contextLength
        let fraction = ctx.map { min(Double(used) / Double($0), 1) } ?? 0
        return HStack(spacing: 7) {
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 44, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(fraction > 0.85 ? LX.C.warn : LX.C.accent).frame(width: max(4, 44 * fraction), height: 3)
                }
            Text("\(Self.compact(used))/\(ctx.map(Self.compact) ?? "—")").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
        }
        .help("Estimated tokens in this chat / model context window")
    }

    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: n >= 10_000 ? "%.0fk" : "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func submit() {
        let text = state.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !generating else { return }
        state.draft = ""
        state.send(text)
    }

    /// Shift+Return: insert a line break at the caret (replacing any selected text).
    private func insertNewline() {
        let text = state.draft
        if case .selection(let range)? = selection?.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            var updated = text
            updated.replaceSubrange(range, with: "\n")
            let caret = updated.index(updated.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.lowerBound) + 1)
            state.draft = updated
            selection = TextSelection(insertionPoint: caret)
        } else {
            state.draft += "\n"
        }
    }
}

// MARK: - Inspector

struct InspectorPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(InferenceStatusModel.self) private var inference

    var body: some View {
        let metrics = AppServices.shared.chats.session(state.currentChatID)?.messages.last(where: { $0.metrics != nil })?.metrics
        let settings = ChatPreferences.current
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Inspector").font(LX.F.ui(12.5, .semibold)); Spacer() }
                .padding(.horizontal, 16).frame(height: LX.S.header)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 22) {
                group("Last reply") {
                    row("Time to first token", metrics.map { String(format: "%.0f ms", $0.timeToFirstToken.milliseconds) } ?? "—")
                    row("Prefill", metrics?.prefillTokensPerSecond.map { "\(Int($0).formatted()) tok/s" } ?? "—")
                    row("Decode", metrics?.decodeTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    row("Tokens", metrics.map { "\($0.promptTokens) in · \($0.generatedTokens) out" } ?? "—")
                }
                group("Model") {
                    row("Name", inference.loadedModel.map { ModelRepoID($0.id)?.name ?? $0.id } ?? "—")
                    row("Context", inference.loadedModel?.contextLength.map { $0.formatted() } ?? "—")
                    row("Quantization", inference.loadedModel?.quantization ?? "—")
                    row("Load time", inference.loadedModel.map { String(format: "%.2f s", $0.loadDuration.seconds) } ?? "—")
                }
                group("Sampling") {
                    row("Temperature", String(format: "%.2f", settings.parameters.temperature))
                    row("Top-p", String(format: "%.2f", settings.parameters.topP))
                    row("Max tokens", settings.parameters.maxTokens.formatted())
                }
            }
            .padding(16)
            Spacer()
        }
    }
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { SectionLabel(text: title).padding(.bottom, 6); content() }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary); Spacer(); Text(v).font(LX.F.mono(11.5)).lineLimit(1) }
            .frame(height: 26)
    }
}
