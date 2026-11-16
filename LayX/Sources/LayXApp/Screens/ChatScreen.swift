import AppKit
import SwiftUI
import LayXCore

struct ChatScreen: View {
    @EnvironmentObject var state: AppState
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
    }

    // MARK: Header
    private var header: some View {
        ScreenHeader {
            ModelPicker()
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

/// Header model picker: a quiet label that opens a popover listing installed models with their details.
struct ModelPicker: View {
    @EnvironmentObject var state: AppState
    @Environment(InferenceStatusModel.self) private var inference
    @State private var open = false
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                if inference.loadedModel != nil {
                    Circle().fill(LX.C.ok).frame(width: 6, height: 6)
                } else if isLoading {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                }
                Text(title).font(LX.F.ui(13, .semibold)).foregroundStyle(LX.C.primary)
                if let detail { Text(detail).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 30)
        }
        .buttonStyle(QuietButtonStyle())
        .help("Choose model")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
        .background {
            Button("") { open.toggle() }.keyboardShortcut("m").opacity(0)
        }
    }

    private var isLoading: Bool { if case .loading = inference.snapshot.model { true } else { false } }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "On this Mac").padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            if library.installed.isEmpty {
                Text("No models installed yet.").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary).padding(10)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(library.installed) { m in
                        ModelPickerRow(model: m, loaded: inference.loadedModel?.id == m.id.description,
                                       loading: { if case .loading(let id, _) = inference.snapshot.model { id == m.id.description } else { false } }()) {
                            UserDefaults.standard.set(m.id.description, forKey: ChatPreferences.defaultChatModelKey)
                            if inference.loadedModel?.id != m.id.description { library.load(m) }
                            open = false
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            Rectangle().fill(LX.C.divider).frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 4) {
                Button { state.modelsTab = .discover; state.screen = .models; open = false } label: {
                    Label("Get more models", systemImage: "arrow.down.circle").font(LX.F.ui(12)).padding(.horizontal, 8).frame(height: 26)
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                if inference.loadedModel != nil {
                    Button { library.unload(); open = false } label: {
                        Text("Unload").font(LX.F.ui(12)).padding(.horizontal, 8).frame(height: 26)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(8)
        .frame(width: 340)
    }

    private var title: String {
        switch inference.snapshot.model {
        case .ready(let info): return ModelRepoID(info.id).map(ModelDisplay.name) ?? info.id
        case .loading(let id, _): return ModelRepoID(id).map(ModelDisplay.name) ?? id
        default:
            if let m = AppServices.defaultChatModel(in: library) { return ModelDisplay.name(m.id) }
            return "No model"
        }
    }

    private var detail: String? {
        switch inference.snapshot.model {
        case .ready(let info):
            return [info.quantization?.replacingOccurrences(of: "-", with: ""), info.contextLength.map { ModelDisplay.context($0) }]
                .compactMap { $0 }.joined(separator: " · ")
        case .loading: return "loading…"
        case .failed: return "failed"
        case .none: return library.installed.isEmpty ? nil : "not loaded"
        }
    }
}

private struct ModelPickerRow: View {
    let model: InstalledModel
    let loaded: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ModelDisplay.name(model.id)).font(LX.F.ui(13, loaded ? .semibold : .medium)).foregroundStyle(LX.C.primary)
                    Text([ModelDisplay.parameters(model.id), model.manifest.quantizationBits.map { "\($0)-bit" },
                          model.manifest.contextLength.map { "\(ModelDisplay.context($0)) ctx" }, ModelDisplay.bytes(model.diskBytes)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                }
                Spacer(minLength: 8)
                if loading {
                    ProgressView().controlSize(.small)
                } else if loaded {
                    Text("LOADED").font(LX.F.mono(9.5)).kerning(0.5).foregroundStyle(LX.C.ok)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
                .fill(loaded ? LX.C.accent.opacity(0.10) : Color.white.opacity(hover ? 0.06 : 0)))
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
                        if message.role == .user {
                            LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(height: 1)
                        }
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
                MarkdownView(text: parts.answer)
                if streaming && !parts.isThinking { BlinkingCaret() }
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
            if generating { GeneratingRibbon() }
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
        .shadow(color: .black.opacity(0.35), radius: 20, y: 16)
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
