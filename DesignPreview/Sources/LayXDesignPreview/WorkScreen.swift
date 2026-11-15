import SwiftUI

struct WorkScreen: View {
    @State private var changes = Mock.changes
    @State private var selectedFile = "ChatView.swift"
    @State private var unified = true
    @State private var refine = ""
    @State private var toast: String?

    private var selectedCount: Int { changes.filter(\.selected).count }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Label("lay-x-app", systemImage: "folder").font(LX.F.ui(13, .semibold)).labelStyle(.titleAndIcon)
                    .foregroundStyle(LX.C.primary)
                Text("~/Work/Lay-X").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                HStack(spacing: 5) { Image(systemName: "arrow.triangle.branch"); Text("main") }
                    .font(LX.F.mono(10.5)).foregroundStyle(Color(hex: 0xC9CBD6))
                    .padding(.horizontal, 7).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            } trailing: {
                HStack(spacing: 8) {
                    Text("\(changes.count) proposed").foregroundStyle(LX.C.warn)
                    Text("·").foregroundStyle(LX.C.tertiary)
                    Text("read-only until approved").foregroundStyle(LX.C.secondary)
                }
                .font(LX.F.mono(11))
            }

            HStack(spacing: 0) {
                fileTree.frame(width: 232)
                Rectangle().fill(LX.C.divider).frame(width: 1)
                diffPane.frame(maxWidth: .infinity)
                Rectangle().fill(LX.C.divider).frame(width: 1)
                assistant.frame(width: 340)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast { Toast(text: toast).padding(.bottom, 70).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(LX.M.panel, value: toast)
    }

    // MARK: Files
    private var fileTree: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(text: "Files").padding(.horizontal, 8).padding(.bottom, 8)
            ForEach(Mock.tree) { node in
                let selected = node.name == selectedFile
                HStack(spacing: 5) {
                    if node.isFolder {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(LX.C.tertiary).frame(width: 10)
                    } else { Color.clear.frame(width: 10) }
                    Image(systemName: node.isFolder ? "folder" : "doc")
                        .font(.system(size: 11)).foregroundStyle(node.isFolder ? LX.C.accent : LX.C.tertiary)
                    Text(node.name).font(LX.F.bodySmall).lineLimit(1)
                    Spacer(minLength: 4)
                    if let s = node.status {
                        Text(s).font(LX.F.mono(10.5)).foregroundStyle(s == "A" ? LX.C.ok : LX.C.warn)
                    }
                }
                .foregroundStyle(selected ? Color.white : Color(hex: 0xC9CBD6))
                .padding(.leading, 8 + CGFloat(node.depth) * 14).padding(.trailing, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: LX.R.sm).fill(LX.C.accent.opacity(selected ? 0.12 : 0)))
                .overlay(RoundedRectangle(cornerRadius: LX.R.sm).strokeBorder(LX.C.accent.opacity(selected ? 0.18 : 0), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { if !node.isFolder { selectedFile = node.name } }
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 12)
    }

    // MARK: Diff
    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(LX.C.secondary)
                Text("Sources/LayX/Chat/\(selectedFile)").font(LX.F.ui(12.5, .medium))
                (Text("+6 ").foregroundStyle(LX.C.ok) + Text("−3").foregroundStyle(LX.C.error)).font(LX.F.mono(11))
                Spacer()
                Segmented(options: [(true, "Unified"), (false, "Split")], selection: $unified)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Rectangle().fill(LX.C.divider).frame(height: 1)

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Mock.diff) { line in DiffRow(line: line) }
                }
                .padding(.vertical, 10)
            }

            Rectangle().fill(LX.C.divider).frame(height: 1)
            HStack(spacing: 8) {
                Text("\(selectedCount) of \(changes.count) selected · no file is written until you apply")
                    .font(LX.F.ui(12)).foregroundStyle(LX.C.secondary).lineLimit(1)
                Spacer()
                LXButton(title: "Reject all", shortcut: "⌘⌫", kind: .danger) { flash("Proposal rejected — nothing was changed") }
                    .keyboardShortcut(.delete, modifiers: .command)
                LXButton(title: "Apply \(selectedCount) changes", symbol: "checkmark", shortcut: "⌘↩", kind: .primary) {
                    flash("Applied \(selectedCount) changes (mock — no files written)")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(Color.black.opacity(0.15))
        }
    }

    // MARK: Assistant
    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("You").font(LX.F.ui(11.5, .semibold)).foregroundStyle(LX.C.secondary)
                    Text("チャットの再描画が重いので、ストリーミング部分をリファクタして").font(LX.F.body).foregroundStyle(LX.C.body).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Qwen3 30B-A3B").font(LX.F.ui(11.5, .semibold)).foregroundStyle(LX.C.accentText)
                    Text("3ファイルの変更を提案します。StreamBuffer を新設し、ChatView を段落単位の遅延描画に変えます。")
                        .font(LX.F.body).foregroundStyle(LX.C.body).lineSpacing(4)
                    Text("read 6 files · 2.4k ctx · 44.1 tok/s").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary).padding(.top, 4)
                }
            }
            .padding(14)

            SectionLabel(text: "Proposed changes").padding(.horizontal, 14).padding(.bottom, 6)
            VStack(spacing: 2) {
                ForEach($changes) { $change in
                    HStack(alignment: .top, spacing: 10) {
                        Checkbox(isOn: $change.selected)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(change.status).font(LX.F.mono(10.5)).foregroundStyle(change.status == "A" ? LX.C.ok : LX.C.warn)
                                Text(change.file).font(LX.F.bodySmall)
                                Spacer()
                                Text(change.stats).font(LX.F.mono(10.5)).foregroundStyle(LX.C.tertiary)
                            }
                            Text(change.summary).font(LX.F.caption).foregroundStyle(LX.C.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(LX.C.accent.opacity(change.file == selectedFile ? 0.10 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LX.C.accent.opacity(change.file == selectedFile ? 0.2 : 0), lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedFile = change.file }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                TextField("Refine the proposal…", text: $refine).textFieldStyle(.plain).font(LX.F.body)
                HStack { Text("@file  /test").font(LX.F.monoSmall).foregroundStyle(LX.C.tertiary); Spacer(); Keycap(text: "⌘↩") }
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 6)
            .well(radius: LX.R.lg, fill: Color(hex: 0x080910, alpha: 0.6))
            .padding(10)
        }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { toast = nil }
    }
}

struct DiffRow: View {
    let line: DiffLine
    var body: some View {
        switch line.kind {
        case .hunk:
            Text(line.text)
                .font(LX.F.mono(11)).foregroundStyle(Color(hex: 0x7A86C8))
                .padding(.leading, 14).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(LX.C.accent.opacity(0.05))
                .padding(.top, line.old == nil && line.text.contains("-88") ? 14 : 0)
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
