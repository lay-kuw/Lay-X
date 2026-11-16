import AppKit
import SwiftUI
import LayXCore

struct WorkScreen: View {
    @Environment(InferenceStatusModel.self) private var inference
    private var projects: WorkProjects { AppServices.shared.work }

    var body: some View {
        Group {
            if let project = projects.current, let session = projects.session(for: project) {
                WorkProjectView(session: session, branch: WorkProjects.gitBranch(of: session.workspace.root))
                    .id(project.id)
            } else {
                noProject
            }
        }
    }

    private var noProject: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text("Work").font(LX.F.title)
            } trailing: {
                Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(LX.C.tertiary)
                    .help("Read-only until approved — nothing in a project changes until you press Apply")
            }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROJECT · ON-DEVICE").font(LX.F.mono(11)).kerning(0.9).foregroundStyle(LX.C.accent)
                    Text("Open a project folder").font(LX.F.display).kerning(-0.4)
                    Text("Lay X reads files only inside the folder you choose, proposes changes as a diff, and writes nothing until you approve.")
                        .font(LX.F.body).foregroundStyle(LX.C.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = projects.error {
                    Text(error).font(LX.F.caption).foregroundStyle(LX.C.error)
                }
                LXButton(title: "Open folder…", symbol: "folder", kind: .primary) { projects.openFolder() }
            }
            .frame(width: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WorkProjectView: View {
    @Bindable var session: WorkSession
    let branch: String?
    @Environment(InferenceStatusModel.self) private var inference
    @State private var unified = true
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var request = ""
    @State private var preview: TextFile?
    @State private var mentionIndex = 0
    @FocusState private var inputFocused: Bool
    @State private var mentionDismissedFor: String?

    /// `@` completion candidates for the token being typed (empty when not typing a mention).
    private var mentionSuggestions: [MentionCompleter.Suggestion] {
        guard let q = MentionCompleter.activeQuery(in: request), mentionDismissedFor != request else { return [] }
        return MentionCompleter.suggestions(for: q, in: session.entries)
    }

    private func acceptMention(_ s: MentionCompleter.Suggestion) {
        request = MentionCompleter.apply(s, to: request)
        mentionIndex = 0
    }

    private var changes: [ProposedChange] { session.changeSet?.changes ?? [] }
    private var selectedCount: Int { changes.filter(\.selected).count }
    private var focusedChange: ProposedChange? { changes.first { $0.path == session.focusPath } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Label(session.workspace.name, systemImage: "folder").font(LX.F.ui(13, .semibold)).labelStyle(.titleAndIcon)
                    .foregroundStyle(LX.C.primary)
                Text((session.workspace.root.path as NSString).abbreviatingWithTildeInPath).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let branch {
                    HStack(spacing: 5) { Image(systemName: "arrow.triangle.branch"); Text(branch) }
                        .font(LX.F.mono(10.5)).foregroundStyle(Color(hex: 0xC9CBD6))
                        .padding(.horizontal, 7).frame(height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                WorkModelBadge()
            } trailing: {
                HStack(spacing: 10) {
                    if busy {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(LX.C.liveCyan)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .help(session.phase == .reading ? "Reading files…" : "Writing a proposal…")
                    }
                    if !changes.isEmpty {
                        Text("\(changes.count) proposed").font(LX.F.mono(11)).foregroundStyle(LX.C.warn)
                    }
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13)).foregroundStyle(changes.isEmpty ? LX.C.tertiary : LX.C.warn)
                        .frame(width: 28)               // same column as the Clear (trash) button below
                        .padding(.trailing, -2)
                        .help("Read-only until approved — nothing in this folder changes until you press Apply")
                        .accessibilityLabel("Read-only until approved")
                }
            }

            HStack(spacing: 0) {
                fileTree.frame(width: 232)
                Rectangle().fill(LX.C.divider).frame(width: 1)
                centerPane.frame(maxWidth: .infinity)
                Rectangle().fill(LX.C.divider).frame(width: 1)
                assistant.frame(width: 340)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = session.notice {
                Toast(text: notice).padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if session.notice == notice { session.clearMessages() }
                    }
            }
        }
        .animation(LX.M.panel, value: session.notice)
        .animation(LX.M.panel, value: changes.isEmpty)
        .onChange(of: session.focusPath) { loadPreview() }
        .onChange(of: session.changeSet) { loadPreview() }
        .onAppear { loadPreview() }
    }

    // MARK: Files

    private var visibleEntries: [WorkspaceEntry] {
        session.entries.filter { entry in
            var parts = entry.path.split(separator: "/").map(String.init)
            parts.removeLast()
            var prefix = ""
            for p in parts {
                prefix = prefix.isEmpty ? p : "\(prefix)/\(p)"
                if !isExpanded(prefix) { return false }
            }
            return true
        }
    }

    /// Top-level folders and folders containing proposed changes start expanded; the user can toggle any.
    private func isExpanded(_ folder: String) -> Bool {
        if collapsed.contains(folder) { return false }
        if expanded.contains(folder) { return true }
        return changes.contains { $0.path.hasPrefix(folder + "/") } || !folder.contains("/")
    }

    private var fileTree: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(text: "Files").padding(.horizontal, 8).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleEntries + newFileEntries) { node in fileRow(node) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 6).padding(.vertical, 12)
    }

    /// Files the proposal would create (shown in the tree with "A").
    private var newFileEntries: [WorkspaceEntry] {
        changes.filter { $0.kind == .create }.map { WorkspaceEntry(path: $0.path, isDirectory: false, size: 0) }
    }

    private func fileRow(_ node: WorkspaceEntry) -> some View {
        let selected = node.path == session.focusPath
        let status = changes.first { $0.path == node.path }?.status
        return HStack(spacing: 5) {
            if node.isDirectory {
                Image(systemName: isExpanded(node.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(LX.C.tertiary).frame(width: 10)
            } else { Color.clear.frame(width: 10) }
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 11)).foregroundStyle(node.isDirectory ? LX.C.accent : LX.C.tertiary)
            Text(node.name).font(LX.F.bodySmall).lineLimit(1)
            Spacer(minLength: 4)
            if let activity = fileActivity(node.path) {
                Image(systemName: activity.symbol)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.liveCyan)
                    .symbolEffect(.pulse, options: .repeating)
                    .frame(width: 14, alignment: .center)   // eye and pencil share one column
                    .help(activity.help)
            }
            if let status {
                Text(status).font(LX.F.mono(10.5)).foregroundStyle(status == "A" ? LX.C.ok : LX.C.warn)
            }
        }
        .foregroundStyle(selected ? Color.white : Color(hex: 0xC9CBD6))
        .padding(.leading, 8 + CGFloat(node.depth) * 14).padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(LX.C.accent.opacity(selected ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: LX.R.sm).strokeBorder(LX.C.accent.opacity(selected ? 0.18 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                if isExpanded(node.path) { collapsed.insert(node.path); expanded.remove(node.path) }
                else { expanded.insert(node.path); collapsed.remove(node.path) }
            } else {
                session.focusPath = node.path
            }
        }
    }

    /// Live activity for a file in the tree: being written (proposal output) or read (sent to the model).
    private func fileActivity(_ path: String) -> (symbol: String, help: String)? {
        guard busy else { return nil }
        if session.phase == .generating, let writing = currentWritePath, writing == path {
            return ("pencil", "Writing a proposal for this file")
        }
        if session.contextFiles.contains(path) {
            return ("eye", session.phase == .reading ? "Reading this file" : "The model is using this file")
        }
        return nil
    }

    /// Path of the file block currently being written in the live output.
    private var currentWritePath: String? {
        let text = session.liveText
        guard let r = text.range(of: "<<<FILE ", options: .backwards), !text[r.upperBound...].contains("FILE>>>") else { return nil }
        let path = text[r.upperBound...].prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    // MARK: Diff / preview

    /// The file block the model is writing (or wrote last) in the live output.
    private var liveBlock: LiveCodeView.Block? {
        guard session.phase == .generating else { return nil }
        return LiveCodeView.Block.last(in: session.liveText)
    }

    private func loadPreview() {
        guard let path = session.focusPath, focusedChange == nil else { preview = nil; return }
        preview = try? TextFile.read(path, in: session.workspace)
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let live = liveBlock {
                    Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(LX.C.liveCyan)
                        .symbolEffect(.pulse, options: .repeating, isActive: !live.closed)
                    Text(live.path).font(LX.F.ui(12.5, .medium)).lineLimit(1).truncationMode(.middle)
                    LiveStatusText(text: live.closed ? "written" : "writing · \(live.lineCount) lines")
                } else {
                Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(LX.C.secondary)
                Text(session.focusPath ?? "No file selected").font(LX.F.ui(12.5, .medium)).lineLimit(1).truncationMode(.middle)
                }
                if liveBlock != nil {
                } else if let c = focusedChange {
                    Text("\(Text("+\(c.stats.added) ").foregroundStyle(LX.C.ok))\(Text("−\(c.stats.removed)").foregroundStyle(LX.C.error))")
                        .font(LX.F.mono(11))
                } else if preview != nil {
                    Text("read-only").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                }
                Spacer()
                if focusedChange != nil {
                    Segmented(options: [(true, "Unified"), (false, "Split")], selection: $unified)
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            Rectangle().fill(LX.C.divider).frame(height: 1)

            if let live = liveBlock {
                LiveCodeView(block: live)
                    .transition(.opacity)
            } else {
            GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let c = focusedChange {
                        if unified {
                            ForEach(c.diff) { line in DiffRow(line: line) }
                        } else {
                            ForEach(SplitDiff.rows(c.diff)) { row in SplitDiffRow(row: row) }
                        }
                    } else if let file = preview {
                        ForEach(Array(LineDiff.lines(file.text).enumerated()), id: \.offset) { i, line in
                            DiffRow(line: DiffLine(id: i + 1, kind: .context, old: i + 1, new: nil, text: line))
                        }
                    } else {
                        Text(session.focusPath == nil ? "Select a file to view it, or describe a change on the right."
                             : "This file can’t be previewed (binary or too large).")
                            .font(LX.F.body).foregroundStyle(LX.C.tertiary).padding(16)
                    }
                }
                .padding(.vertical, 10)
                // A 2-axis scroll view centres content narrower than itself; pin it to the leading edge.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            }
            }

            if !changes.isEmpty {
                Rectangle().fill(LX.C.divider).frame(height: 1)
                HStack(spacing: 8) {
                    Text("\(selectedCount) of \(changes.count) selected · no file is written until you apply")
                        .font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).lineLimit(1)
                    Spacer()
                    LXButton(title: "Reject all", kind: .danger) { session.reject() }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(session.phase == .applying)
                    LXButton(title: "Apply \(selectedCount) change\(selectedCount == 1 ? "" : "s")", symbol: "checkmark", kind: .primary) {
                        session.apply()
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(selectedCount == 0 || session.phase != .proposed)
                }
                .padding(.horizontal, 14).frame(height: 52)
                .background(Color.black.opacity(0.15))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Assistant

    private var modelName: String {
        inference.loadedModel.flatMap { ModelRepoID($0.id) }.map(ModelDisplay.name) ?? "Assistant"
    }

    private var busy: Bool { session.phase == .reading || session.phase == .generating }

    /// What Work is doing right now (for the live status line).
    private var workStatus: String {
        switch session.phase {
        case .reading: return "Reading project files…"
        case .applying: return "Applying changes…"
        case .generating:
            let text = session.liveText
            if let r = text.range(of: "<<<FILE ", options: .backwards) {
                let path = text[r.upperBound...].prefix { !$0.isNewline }
                let done = text[r.upperBound...].contains("FILE>>>")
                if !done, !path.isEmpty { return "Writing \((String(path) as NSString).lastPathComponent)…" }
            }
            let files = text.components(separatedBy: "FILE>>>").count - 1
            if ThinkingParser.split(text).isThinking { return "Thinking…" }
            return files > 0 ? "Proposed \(files) file\(files == 1 ? "" : "s") · continuing…" : "Planning the change…"
        default: return ""
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Conversation")
                Spacer()
                IconButton(symbol: "trash", help: "Clear conversation") { session.clearConversation() }
                    .disabled(session.turns.isEmpty && !busy)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.turns) { turn in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(turn.role == .user ? "You" : modelName).font(LX.F.ui(11.5, .semibold))
                                .foregroundStyle(turn.role == .user ? LX.C.secondary : LX.C.accentText)
                            Text(turn.text).font(LX.F.body).foregroundStyle(LX.C.body).lineSpacing(4).textSelection(.enabled)
                            if let note = turn.note {
                                Text(note).font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary).padding(.top, 4)
                            }
                        }
                    }
                    if busy {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(modelName).font(LX.F.ui(11.5, .semibold)).foregroundStyle(LX.C.accentText)
                                LiveStatusText(text: workStatus)
                            }
                            let live = ProposalParser.parse(session.liveText).summary
                            if !live.isEmpty {
                                Text(live).font(LX.F.body).foregroundStyle(LX.C.body).lineSpacing(4)
                            }
                            BlinkingCaret()
                        }
                    }
                    if session.canContinue && !busy {
                        HStack(spacing: 8) {
                            LXButton(title: "Continue generating", symbol: "arrow.forward", kind: .secondary) {
                                session.continueGeneration()
                            }
                            Text("stopped at the output limit").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let error = session.error {
                        Text(error).font(LX.F.caption).foregroundStyle(LX.C.error).fixedSize(horizontal: false, vertical: true)
                    }
                    if session.turns.isEmpty && !busy {
                        Text("Describe a change below. Lay X reads the relevant files, then shows the proposed edits as a diff for you to apply or reject.")
                            .font(LX.F.body).foregroundStyle(LX.C.tertiary).lineSpacing(4)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: changes.isEmpty ? .infinity : 260)

            if !changes.isEmpty {
                SectionLabel(text: "Proposed changes").padding(.horizontal, 14).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(changes) { change in changeRow(change) }
                    }
                    .padding(.horizontal, 10)
                }
                if let rejected = session.changeSet?.rejected, !rejected.isEmpty {
                    Text("Skipped: " + rejected.map { "\($0.path) — \($0.reason)" }.joined(separator: "; "))
                        .font(LX.F.caption).foregroundStyle(LX.C.tertiary).padding(.horizontal, 14).padding(.top, 6)
                }
            }

            Spacer(minLength: 0)

            if !mentionSuggestions.isEmpty { mentionList }
            VStack(alignment: .leading, spacing: 0) {
                TextField(changes.isEmpty ? "Describe a change… (@ to add files)" : "Refine the proposal…", text: $request, axis: .vertical)
                    .textFieldStyle(.plain).font(LX.F.body).lineLimit(1...6)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        let s = mentionSuggestions
                        if !s.isEmpty, !press.modifiers.contains(.shift) {
                            acceptMention(s[min(mentionIndex, s.count - 1)])
                            return .handled
                        }
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        request += "\n"
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        let s = mentionSuggestions
                        guard !s.isEmpty else { return .ignored }
                        acceptMention(s[min(mentionIndex, s.count - 1)])
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        let n = mentionSuggestions.count
                        guard n > 0 else { return .ignored }
                        mentionIndex = (mentionIndex + 1) % n
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        let n = mentionSuggestions.count
                        guard n > 0 else { return .ignored }
                        mentionIndex = (mentionIndex - 1 + n) % n
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !mentionSuggestions.isEmpty else { return .ignored }
                        mentionDismissedFor = request
                        return .handled
                    }
                    .onChange(of: request) { mentionIndex = 0 }
                    .onSubmit { submit() }
                    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 7)
                HStack(spacing: 10) {
                    ContextMeter(used: session.contextUsed > 0 ? session.contextUsed : PromptBuilder.estimateTokens(request),
                                 total: session.contextLength ?? inference.loadedModel?.contextLength)
                        .help("Estimated tokens of the last proposal (files + request + output) / model context window")
                    Text("@ adds files").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary)
                    Spacer()
                    if busy {
                        SendButton(mode: .stop) { session.cancel() }.keyboardShortcut(.escape, modifiers: [])
                    } else {
                        SendButton(mode: .send, enabled: !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { submit() }
                    }
                }
                .padding(.leading, 12).padding(.trailing, 7).frame(height: 34)
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: LX.R.xl).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: LX.R.xl).fill(Color(hex: 0x080910, alpha: 0.6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LX.R.xl))
            .overlay(RoundedRectangle(cornerRadius: LX.R.xl).strokeBorder(Color.white.opacity(inputFocused ? 0.16 : 0.09), lineWidth: 1))
            .overlay { if busy { GlowingBorder(radius: LX.R.xl).transition(.opacity) } }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
            .animation(LX.M.hover, value: inputFocused)
            .animation(.easeInOut(duration: 0.3), value: busy)
            .padding(10)
        }
    }

    private var mentionList: some View {
        let items = mentionSuggestions
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { acceptMention(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .font(.system(size: 11)).foregroundStyle(item.isDirectory ? LX.C.accent : LX.C.tertiary).frame(width: 14)
                        Text(item.name).font(LX.F.bodySmall).foregroundStyle(LX.C.primary).lineLimit(1)
                        Text(item.path).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(LX.C.accent.opacity(i == min(mentionIndex, items.count - 1) ? 0.14 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { mentionIndex = i } }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: LX.R.lg).fill(LX.C.overlay))
        .overlay(RoundedRectangle(cornerRadius: LX.R.lg).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .padding(.horizontal, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func changeRow(_ change: ProposedChange) -> some View {
        let focused = change.path == session.focusPath
        return HStack(alignment: .top, spacing: 10) {
            Checkbox(isOn: Binding(get: { change.selected }, set: { _ in session.toggle(change.path) }))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.status).font(LX.F.mono(10.5)).foregroundStyle(change.status == "A" ? LX.C.ok : LX.C.warn)
                    Text((change.path as NSString).lastPathComponent).font(LX.F.bodySmall).lineLimit(1)
                    Spacer()
                    Text(change.kind == .create ? "+\(change.stats.added)" : "+\(change.stats.added) −\(change.stats.removed)")
                        .font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                }
                Text(change.kind == .create ? "New file · \(change.path)" : change.path)
                    .font(LX.F.caption).foregroundStyle(LX.C.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(LX.C.accent.opacity(focused ? 0.10 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LX.C.accent.opacity(focused ? 0.2 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { session.focusPath = change.path }
    }

    private func submit() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        request = ""
        session.propose(text, refining: session.changeSet != nil)
    }
}

// MARK: - Diff rows

struct DiffRow: View {
    let line: DiffLine
    var body: some View {
        switch line.kind {
        case .hunk:
            Text(line.text)
                .font(LX.F.mono(11)).foregroundStyle(Color(hex: 0x7A86C8))
                .padding(.leading, 14).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(LX.C.accent.opacity(0.05))
                .padding(.top, line.id == 0 ? 0 : 14)
        default:
            HStack(spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 6)
                Text(line.new.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 10)
                Text(marker).foregroundStyle(markerColor).frame(width: 16, alignment: .leading)
                Text(Syntax.highlight(line.text)).fixedSize()
                Spacer(minLength: 0)
            }
            .font(LX.F.mono(12))
            .foregroundStyle(Color(hex: 0x4E5160))
            .frame(height: 22)
            .background(background)
            .overlay(alignment: .leading) { Rectangle().fill(bar).frame(width: 2) }
        }
    }
    private var marker: String { line.kind == .added ? "+" : line.kind == .removed ? "-" : "" }
    private var markerColor: Color { line.kind == .added ? LX.C.ok : LX.C.error }
    private var background: Color {
        switch line.kind {
        case .added: LX.C.ok.opacity(0.08)
        case .removed: LX.C.errorBar.opacity(0.09)
        default: .clear
        }
    }
    private var bar: Color {
        switch line.kind {
        case .added: LX.C.ok
        case .removed: LX.C.errorBar
        default: .clear
        }
    }
}

/// Side-by-side rows built from a unified diff (removed lines on the left, added on the right).
enum SplitDiff {
    struct Row: Identifiable {
        let id: Int
        var hunk: String?
        var left: DiffLine?
        var right: DiffLine?
    }

    static func rows(_ lines: [DiffLine]) -> [Row] {
        var out: [Row] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append(Row(id: out.count, left: i < removed.count ? removed[i] : nil, right: i < added.count ? added[i] : nil))
            }
            removed = []; added = []
        }
        for l in lines {
            switch l.kind {
            case .hunk: flush(); out.append(Row(id: out.count, hunk: l.text))
            case .removed: removed.append(l)
            case .added: added.append(l)
            case .context: flush(); out.append(Row(id: out.count, left: l, right: l))
            }
        }
        flush()
        return out
    }
}

struct SplitDiffRow: View {
    let row: SplitDiff.Row
    var body: some View {
        if let hunk = row.hunk {
            DiffRow(line: DiffLine(id: row.id, kind: .hunk, old: nil, new: nil, text: hunk))
        } else {
            HStack(spacing: 0) {
                side(row.left, number: row.left?.old, isLeft: true).frame(width: 520, alignment: .leading)
                Rectangle().fill(LX.C.divider).frame(width: 1)
                side(row.right, number: row.right?.new, isLeft: false).frame(width: 520, alignment: .leading)
            }
            .frame(height: 22)
        }
    }

    @ViewBuilder private func side(_ line: DiffLine?, number: Int?, isLeft: Bool) -> some View {
        let changed = line.map { $0.kind != .context } ?? false
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 10)
            Text(line.map { Syntax.highlight($0.text) } ?? AttributedString("")).fixedSize()
            Spacer(minLength: 0)
        }
        .font(LX.F.mono(12))
        .foregroundStyle(Color(hex: 0x4E5160))
        .frame(maxHeight: .infinity)
        .background(changed ? (isLeft ? LX.C.errorBar.opacity(0.09) : LX.C.ok.opacity(0.08)) : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(changed ? (isLeft ? LX.C.errorBar : LX.C.ok) : .clear).frame(width: 2) }
    }
}

/// Model used by Work (display only — choose it in Chat's picker or Settings → Models & Inference).
struct WorkModelBadge: View {
    @Environment(InferenceStatusModel.self) private var inference
    private var library: ModelLibrary { AppServices.shared.models }

    var body: some View {
        let loaded = inference.loadedModel.flatMap { library.model($0.id) }
        let model = loaded ?? WorkProjects.defaultWorkModel(in: library)
        if let model {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 10))
                Text(ModelDisplay.split(model.id).name).font(LX.F.ui(11.5, .medium))
                Text(ModelDisplay.subtitle(model, withSize: false)).font(LX.F.mono(10)).foregroundStyle(LX.C.tertiary)
                if loaded == nil { Text("· not loaded").font(LX.F.mono(10)).foregroundStyle(LX.C.tertiary) }
            }
            .foregroundStyle(LX.C.secondary)
            .lineLimit(1)
            .padding(.leading, 6)
            .help("Model used by Work")
        }
    }
}

/// Code streaming in from the model: new lines rise and fade in, the line being written glows, and the view
/// follows the end of the file.
struct LiveCodeView: View {
    struct Block: Equatable {
        var path: String
        var lines: [String]
        var closed: Bool
        var lineCount: Int { lines.count }

        /// Last `<<<FILE path` block in streaming output (possibly unterminated).
        static func last(in text: String) -> Block? {
            guard let open = text.range(of: "<<<FILE", options: .backwards) else { return nil }
            let rest = text[open.upperBound...]
            let path = rest.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            guard !path.isEmpty else { return nil }
            var body = rest.drop { !$0.isNewline }.dropFirst()
            var closed = false
            if let end = body.range(of: "FILE>>>") { body = body[..<end.lowerBound]; closed = true }
            var lines = body.components(separatedBy: "\n")
            if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeFirst() }
            if closed {
                while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty || l.trimmingCharacters(in: .whitespaces) == "```" {
                    lines.removeLast()
                }
            }
            return Block(path: path, lines: lines, closed: closed)
        }
    }

    let block: Block

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { i, line in
                        row(i, line, current: i == block.lines.count - 1 && !block.closed)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.98, anchor: .leading)),
                                removal: .identity))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 10)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: block.lines.count)
            }
            .onChange(of: block.lines.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func row(_ i: Int, _ text: String, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: String(i + 1)).font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                .frame(width: 44, alignment: .trailing).padding(.trailing, 14)
            Text(verbatim: text.isEmpty ? " " : text).font(LX.F.mono(12))
                .foregroundStyle(current ? Color.white : LX.C.body)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            if current { BlinkingCaret().padding(.leading, 2) }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .background(alignment: .leading) {
            if current {
                LinearGradient(colors: [LX.C.liveCyan.opacity(0.14), LX.C.accent.opacity(0.06), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(LX.C.ok.opacity(current ? 0.9 : 0.35)).frame(width: 2)
        }
    }
}
