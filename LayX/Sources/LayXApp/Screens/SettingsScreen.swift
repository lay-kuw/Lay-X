import AppKit
import SwiftUI

struct SettingsScreen: View {
    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case inference = "Models & Inference"
        case mini = "Mini Chat"
        case privacy = "Chats & Privacy"
        case api = "API Server"
        case appearance = "Appearance"
        case shortcuts = "Shortcuts"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    enum KVQuant: Hashable { case off, eight, four }

    @EnvironmentObject var state: AppState
    @AppStorage(LX.Glass.storageKey) private var transparency = LX.Glass.defaultValue
    @AppStorage(LX.Glow.storageKey) private var glowRaw = LX.Glow.violet.rawValue
    @State private var followSystem = true
    @State private var search = ""
    @State private var defaultChat = "Qwen3 14B · 4-bit"
    @State private var defaultWork = "Qwen3 30B-A3B · 4-bit"
    @State private var keepLoaded = "15 minutes"
    @State private var memoryLimit = 40.0
    @State private var kv: KVQuant = .eight
    @State private var promptCache = true
    @State private var temperature = 0.7
    @State private var topP = 0.95
    @State private var maxTokens = "4,096"

    private let modelOptions = ["Qwen3 14B · 4-bit", "Qwen3 30B-A3B · 4-bit", "Gemma 3 27B · 4-bit", "Phi-4 mini · 8-bit"]

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text(state.settingsCategory.rawValue).font(LX.F.title)
            } trailing: {
                LXField(placeholder: "Search settings", text: $search, symbol: "magnifyingglass").frame(width: 220)
            }
            ScrollView {
                Group {
                    switch state.settingsCategory {
                    case .appearance: appearancePage
                    case .inference: inferencePage
                    default:
                        Text("This section is not part of the design preview yet.")
                            .font(LX.F.body).foregroundStyle(LX.C.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: 760)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Appearance
    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Background") {
                row("Glow color", "The deep light in the top-left corner of the window") {
                    glowPicker
                }
            }
            group("Glass") {
                row("Transparency", "How much of the wallpaper shows through the window, panes and Mini Chat") {
                    GradientSlider(value: $transparency, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                }
                row("Reset to default", "50% transparency and Deep Violet — the look used in the design mocks") {
                    LXButton(title: "Reset") {
                        withAnimation(LX.M.panel) {
                            transparency = LX.Glass.defaultValue
                            glowRaw = LX.Glow.violet.rawValue
                        }
                    }
                }
                row("Follow “Reduce transparency”", "When the system setting is on, panes become solid") {
                    Toggle("", isOn: $followSystem).toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(LX.C.accentText)
                Text("Changes apply instantly to every window.")
                    .font(LX.F.ui(12)).foregroundStyle(Color(hex: 0xC9CBD6))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LX.R.lg).fill(LX.C.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: LX.R.lg).strokeBorder(LX.C.accent.opacity(0.16), lineWidth: 1))
        }
    }

    private var glowPicker: some View {
        HStack(spacing: 10) {
            ForEach(LX.Glow.allCases) { preset in
                let selected = preset.rawValue == glowRaw
                Button { glowRaw = preset.rawValue } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
                            .fill(RadialGradient(colors: [preset.swatch, Color(hex: 0x0A0B11)],
                                                 center: .topLeading, startRadius: 0, endRadius: 44))
                            .frame(width: 44, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: LX.R.md, style: .continuous)
                                .strokeBorder(selected ? LX.C.accent.opacity(0.9) : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                        Text(preset.title)
                            .font(LX.F.ui(10.5, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? LX.C.primary : LX.C.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Models & Inference
    private var inferencePage: some View {
                VStack(alignment: .leading, spacing: 22) {
                    group("Default model") {
                        row("Chat & Mini Chat", "Used for new chats and Mini Chat") { menu($defaultChat, modelOptions) }
                        row("Work", "Larger context for multi-file edits") { menu($defaultWork, modelOptions) }
                        row("Keep model loaded", "Unload after a period of inactivity to free memory") {
                            menu($keepLoaded, ["5 minutes", "15 minutes", "1 hour", "Always"], width: 140)
                        }
                    }
                    group("Storage") {
                        row("Model storage", storageHelp) {
                            HStack(spacing: 8) {
                                Text((AppServices.shared.models.store.root.path as NSString).abbreviatingWithTildeInPath)
                                    .font(LX.F.mono(11.5)).foregroundStyle(LX.C.accentText)
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                                    .help(AppServices.shared.models.store.root.path)
                                LXButton(title: "Choose…") { chooseStorage() }
                                if !AppServices.shared.models.isDefaultStorage {
                                    LXButton(title: "Default") { storageError = AppServices.shared.models.changeStorage(to: nil) }
                                }
                            }
                        }
                    }
                    if let storageError {
                        Text(storageError).font(LX.F.caption).foregroundStyle(LX.C.error)
                    }
                    group("Memory") {
                        row("GPU memory limit", "Upper bound for weights + KV cache (wired memory)") {
                            GradientSlider(value: $memoryLimit, range: 8...64) { "\(Int($0)) GB" }
                        }
                        row("KV cache quantization", "8-bit halves cache size with negligible quality loss") {
                            Segmented(options: [(KVQuant.off, "Off"), (.eight, "8-bit"), (.four, "4-bit")], selection: $kv, mono: true)
                        }
                        row("Prompt cache", "Reuse prefill across turns of the same chat") {
                            Toggle("", isOn: $promptCache).toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                        }
                    }
                    group("Sampling defaults") {
                        row("Temperature", "Per-chat presets can override") {
                            GradientSlider(value: $temperature, range: 0...2) { String(format: "%.2f", $0) }
                        }
                        row("Top-p", nil) {
                            GradientSlider(value: $topP, range: 0...1) { String(format: "%.2f", $0) }
                        }
                        row("Max output tokens", nil) {
                            LXField(placeholder: "4,096", text: $maxTokens, mono: true).frame(width: 100)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle").foregroundStyle(LX.C.accentText)
                        Text("Chats are temporary by default. Only pinned chats are written to disk — change this in Chats & Privacy.")
                            .font(LX.F.ui(12)).foregroundStyle(Color(hex: 0xC9CBD6))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: LX.R.lg).fill(LX.C.accent.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: LX.R.lg).strokeBorder(LX.C.accent.opacity(0.16), lineWidth: 1))
                }
    }

    @State private var storageError: String?

    private var storageHelp: String {
        "Where downloaded models are kept. Existing models stay in the old folder."
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Models"
        panel.message = "Choose a folder for Lay X models. If it isn’t empty, a “Lay X Models” folder is created inside it."
        panel.directoryURL = AppServices.shared.models.store.root
        if panel.runModal() == .OK, let url = panel.url {
            storageError = AppServices.shared.models.changeStorage(to: url)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .well()
                .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
        }
    }

    private func row<C: View>(_ title: String, _ help: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LX.F.body)
                if let help { Text(help).font(LX.F.caption).foregroundStyle(LX.C.tertiary) }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1) }
    }

    private func menu(_ selection: Binding<String>, _ options: [String], width: CGFloat = 200) -> some View {
        Menu {
            ForEach(options, id: \.self) { o in Button(o) { selection.wrappedValue = o } }
        } label: {
            HStack {
                Text(selection.wrappedValue).font(LX.F.ui(12.5)).foregroundStyle(LX.C.primary)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
            }
            .padding(.horizontal, 10).frame(width: width, height: LX.S.control)
            .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
