import SwiftUI

struct ChatScreen: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if state.phase == .empty {
                    EmptyChat()
                        .transition(.opacity)
                } else {
                    thread
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Composer()
                .frame(width: LX.S.readingWidth)
                .padding(.bottom, 14)
        }
        .animation(.easeOut(duration: 0.18), value: state.phase)
    }

    // MARK: Header
    private var header: some View {
        ScreenHeader {
            Button {} label: {
                HStack(spacing: 8) {
                    Text("Qwen3 14B").font(LX.F.ui(13, .semibold))
                    Text("4bit · 32k").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: LX.R.md).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: LX.R.md).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Switch model (⌘M)")
            .keyboardShortcut("m")

            Text("/").font(LX.F.body).foregroundStyle(Color(hex: 0x5E6172))
            Text(state.chatTitle).font(LX.F.ui(13, .medium)).foregroundStyle(Color(hex: 0xC9CBD6))
            if !state.pinned { Tag(text: "TEMP", color: LX.C.accentText) }
        } trailing: {
            MetricsStrip(
                ttft: state.phase == .empty ? "—" : "182ms",
                tps: state.phase == .empty ? "—" : String(format: "%.1f", state.liveTPS),
                memory: "18.4",
                live: state.phase == .generating)
            Button { state.togglePin() } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.pinned ? "star.fill" : "star").font(.system(size: 11))
                    Text(state.pinned ? "Pinned" : "Pin")
                }
            }
            .buttonStyle(LXButtonStyle(kind: state.pinned ? .primary : .secondary, height: 30))
            IconButton(symbol: "plus", help: "New chat (⌘N)") { state.newChat() }
            IconButton(symbol: "sidebar.right", help: "Inspector (⌘I)") { withAnimation(LX.M.panel) { state.inspector.toggle() } }
        }
    }

    // MARK: Thread
    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MessageView(message: Mock.conversation[0])
                LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                if state.phase == .generating {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("Qwen3 14B").font(LX.F.ui(12.5, .semibold))
                            Text("streaming…").font(LX.F.mono(10.5)).foregroundStyle(LX.C.liveCyan)
                        }
                        Text(state.streamedText)
                            .font(LX.F.bodyLarge)
                            .foregroundStyle(LX.C.body)
                            .lineSpacing(6)
                        BlinkingCaret()
                    }
                } else {
                    MessageView(message: Mock.conversation[1])
                }
            }
            .frame(width: LX.S.readingWidth, alignment: .leading)
            .padding(.top, 24).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

struct MessageView: View {
    let message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(message.author).font(LX.F.ui(12.5, .semibold))
                Text(message.meta).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
            }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(s).font(LX.F.bodyLarge).foregroundStyle(LX.C.body).lineSpacing(6).textSelection(.enabled)
                case .code(let lang, let file, let code):
                    CodeBlock(language: lang, filename: file, code: code)
                }
            }
        }
    }
}

struct EmptyChat: View {
    @EnvironmentObject var state: AppState
    @State private var hovered: Int? = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEW SESSION · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                Text("What are we building?").font(LX.F.display).kerning(-0.4)
                Text("Temporary until you pin it. Nothing leaves this Mac.").font(LX.F.body).foregroundStyle(LX.C.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(Mock.suggestions.enumerated()), id: \.offset) { i, s in
                    Button { state.send() } label: {
                        HStack {
                            Text(s).font(LX.F.body).foregroundStyle(hovered == i ? Color.white : Color(hex: 0xC9CBD6))
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: LX.R.md).fill(LX.C.accent.opacity(hovered == i ? 0.12 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .option)
                    .onHover { if $0 { hovered = i } }
                }
            }
            .padding(4)
            .well(radius: 10, fill: Color.black.opacity(0.25))
        }
        .frame(width: 520)
    }
}

struct Composer: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        VStack(spacing: 0) {
            if state.phase == .generating { GeneratingRibbon() }
            TextField(state.phase == .empty ? "Ask Qwen3 14B anything   ·   / for commands" : "Message Qwen3 14B   ·   / for commands",
                      text: $state.draft, selection: $selection, axis: .vertical)
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
                IconButton(symbol: "plus", help: "Attach")
                Button {} label: {
                    HStack(spacing: 6) { Text("Preset: Swift expert"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                        .font(LX.F.caption).foregroundStyle(LX.C.secondary)
                        .padding(.horizontal, 8).frame(height: 24)
                        .overlay(RoundedRectangle(cornerRadius: LX.R.sm).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 7) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 44, height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(LX.C.accent).frame(width: 4, height: 3) }
                    Text("2.1k/32k").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
                }
                if state.phase == .generating {
                    LXButton(title: "Stop", shortcut: "esc") { state.stop() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    LXButton(title: "Send", shortcut: "⌘↩", kind: .primary) { submit() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.leading, 8).padding(.trailing, 7).frame(height: 38)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: LX.R.xl).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: LX.R.xl).fill(Color(hex: 0x080910, alpha: 0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LX.R.xl))
        .overlay(RoundedRectangle(cornerRadius: LX.R.xl).strokeBorder(Color.white.opacity(focused ? 0.16 : 0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 16)
        .animation(LX.M.hover, value: focused)
    }

    private func submit() {
        state.draft = ""
        state.send()
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

// MARK: - Inspector (⌘I)

struct InspectorPanel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Inspector").font(LX.F.ui(12.5, .semibold)); Spacer() }
                .padding(.horizontal, 16).frame(height: LX.S.header)
            Rectangle().fill(LX.C.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 22) {
                group("Live") {
                    row("Time to first token", "182 ms")
                    row("Prefill", "1,240 tok/s")
                    row("Decode", String(format: "%.1f tok/s", state.liveTPS))
                }
                group("Model") {
                    row("Name", "qwen3-14b-4bit")
                    row("Context", "32,768")
                    row("KV cache", "8-bit")
                }
                group("Sampling") {
                    row("Temperature", "0.70")
                    row("Top-p", "0.95")
                    row("Max tokens", "4,096")
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
        HStack { Text(k).font(LX.F.ui(12)).foregroundStyle(LX.C.secondary); Spacer(); Text(v).font(LX.F.mono(11.5)) }
            .frame(height: 26)
    }
}
