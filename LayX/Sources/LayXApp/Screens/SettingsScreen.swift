import AppKit
import SwiftUI
import LayXCore

struct SettingsScreen: View {
    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case soul = "Soul"
        case inference = "Models & Inference"
        case mini = "Mini Chat"
        case privacy = "Chats & Privacy"
        case web = "Web Search"
        case api = "API Server"
        case appearance = "Appearance"
        case shortcuts = "Shortcuts"
        case advanced = "Advanced"
        var id: String { rawValue }

        /// Extra words that find a category from the search field.
        var keywords: [String] {
            switch self {
            case .general: ["launch", "login", "window", "dock", "quit"]
            case .soul: ["persona", "system prompt", "personality", "instructions"]
            case .inference: ["model", "memory", "kv", "cache", "temperature", "top-p", "tokens", "storage", "unload", "work"]
            case .mini: ["shortcut", "hotkey", "option space", "panel"]
            case .privacy: ["pinned", "chats", "delete", "history", "database", "privacy"]
            case .web: ["web", "search", "internet", "brave", "duckduckgo", "searxng", "globe", "sources"]
            case .api: ["server", "port", "lan", "network", "key", "openai"]
            case .appearance: ["glow", "glass", "transparency", "color", "theme"]
            case .shortcuts: ["keyboard", "hotkey", "shortcut"]
            case .advanced: ["reset", "cache", "downloads", "logs", "about", "version"]
            }
        }

        static func matching(_ query: String) -> [Category] {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return allCases }
            return allCases.filter { $0.rawValue.lowercased().contains(q) || $0.keywords.contains { $0.contains(q) } }
        }
    }


    @EnvironmentObject var state: AppState
    @AppStorage(LX.Glass.storageKey) private var transparency = LX.Glass.defaultValue
    @AppStorage(LX.Glow.storageKey) private var glowRaw = LX.Glow.violet.rawValue
    @AppStorage(AppearancePreferences.followReduceTransparencyKey) private var followSystem = true
    @AppStorage(LX.Glass.fullGlassKey) private var fullGlass = false
    @AppStorage(EnginePreferences.keepLoadedKey) private var keepLoaded = 15
    @AppStorage(EnginePreferences.memoryLimitKey) private var memoryLimitGB = 0.0
    @AppStorage(EnginePreferences.kvBitsKey) private var kvBits = 0
    @AppStorage(EnginePreferences.gpuLimitKey) private var gpuLimit = 1.0
    @AppStorage(WorkProjects.defaultWorkModelKey) private var defaultWorkID = ""
    @AppStorage(ChatPreferences.temperatureKey) private var temperature = ChatPreferences.defaultTemperature
    @AppStorage(ChatPreferences.topPKey) private var topP = ChatPreferences.defaultTopP
    @AppStorage(ChatPreferences.maxTokensKey) private var maxTokensValue = ChatPreferences.defaultMaxTokens
    @AppStorage(ChatPreferences.defaultChatModelKey) private var defaultChatID = ""
    @State private var maxTokens = ""


    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                Text(state.settingsCategory.rawValue).font(LX.F.title)
            } trailing: {
                LXField(placeholder: "Search settings", text: $state.settingsSearch, symbol: "magnifyingglass").frame(width: 220)
                    .onSubmit {
                        if let first = Category.matching(state.settingsSearch).first { state.settingsCategory = first }
                    }
            }
            ScrollView {
                Group {
                    switch state.settingsCategory {
                    case .appearance: appearancePage
                    case .inference: inferencePage
                    case .mini: miniChatPage
                    case .soul: soulPage
                    case .general: generalPage
                    case .privacy: privacyPage
                    case .web: WebSearchSettings(screen: self)
                    case .api: apiPage
                    case .shortcuts: shortcutsPage
                    case .advanced: advancedPage
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
                row("Full glass", "Make the whole window translucent — content panes and cards too, not only the sidebar") {
                    Toggle("", isOn: $fullGlass).toggleStyle(LXToggleStyle()).labelsHidden().fixedSize()
                }
                row("Reset to default", "50% transparency, Deep Violet, full glass off — the look used in the design mocks") {
                    LXButton(title: "Reset") {
                        withAnimation(LX.M.panel) {
                            transparency = LX.Glass.defaultValue
                            glowRaw = LX.Glow.violet.rawValue
                            fullGlass = false
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
                        row("Chat & Mini Chat", "Used for new chats and Mini Chat") { defaultChatMenu }
                        row("Work", "Used for project proposals (larger models follow the edit format better)") { defaultWorkMenu }
                        row("Keep model loaded", "Unload after a period of inactivity to free memory") {
                            Menu {
                                ForEach(EnginePreferences.keepLoadedOptions, id: \.minutes) { o in
                                    Button(o.label) { keepLoaded = o.minutes }
                                }
                            } label: { menuLabel(EnginePreferences.keepLoadedOptions.first { $0.minutes == keepLoaded }?.label ?? "15 minutes", width: 140) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
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
                        row("Model memory limit", "Largest model Lay X will load, and MLX's soft memory cap. Auto = 75% of RAM") {
                            GradientSlider(value: Binding(get: { memoryLimitGB == 0 ? (EnginePreferences.physicalGB * 0.75).rounded() : memoryLimitGB },
                                                          set: { memoryLimitGB = $0.rounded() }),
                                           range: 8...max(16, (EnginePreferences.physicalGB * 0.9).rounded())) {
                                memoryLimitGB == 0 ? "Auto" : "\(Int($0)) GB"
                            }
                        }
                        row("GPU usage limit", "Caps how much of the GPU generation may use, leaving headroom for smooth scrolling and other apps. Lower = smoother UI, slower replies") {
                            GradientSlider(value: $gpuLimit, range: 0.3...1) { $0 >= 0.995 ? "Max" : "\(Int(($0 * 100).rounded()))%" }
                        }
                        row("KV cache quantization", "8-bit halves cache size with negligible quality loss") {
                            Segmented(options: [(0, "Off"), (8, "8-bit"), (4, "4-bit")], selection: $kvBits, mono: true)
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
                            LXField(placeholder: maxTokensValue.formatted(), text: $maxTokens, mono: true).frame(width: 100)
                                .onAppear { maxTokens = maxTokensValue.formatted() }
                                .onChange(of: maxTokens) { _, new in
                                    let digits = new.filter(\.isNumber)
                                    if let v = Int(digits), v > 0 { maxTokensValue = min(v, 131_072) }
                                }
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

    // MARK: Soul
    @AppStorage(ChatPreferences.soulKey) private var soul = ""
    @AppStorage(ChatPreferences.workSoulKey) private var workSoul = ""

    private var soulPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SoulEditor(title: "Chat & Mini Chat", text: $soul,
                       placeholder: "Who should the assistant be? e.g. “You are a calm senior engineer. Answer in Japanese unless asked otherwise. Be concise and show code when it helps.”")
            SoulEditor(title: "Work instructions",
                       text: Binding(get: { workSoul.isEmpty ? WorkPrompt.defaultInstructions : workSoul },
                                     set: { workSoul = $0.trimmingCharacters(in: .whitespacesAndNewlines) == WorkPrompt.defaultInstructions.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : $0 }),
                       placeholder: "Describe how Work should approach your projects.",
                       resetTitle: workSoul.isEmpty ? nil : "Reset to default",
                       onReset: { workSoul = "" })
            DisclosureGroup {
                Text(WorkPrompt.fixedRules)
                    .font(LX.F.mono(11.5)).foregroundStyle(LX.C.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).well(radius: LX.R.lg)
                    .padding(.top, 6)
            } label: {
                Text("Always-applied Work rules (read-only — Lay X's safety and diff format depend on them)")
                    .font(LX.F.caption).foregroundStyle(LX.C.tertiary)
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(LX.C.accentText)
                Text("Chat & Mini Chat have no built-in instructions — only your Soul is sent (plus search results and a citation note when web search is used). Work instructions replace Work's default role and style; the fixed rules are always added after them. Changes apply from the next reply and are stored only on this Mac.")
                    .font(LX.F.ui(12)).foregroundStyle(Color(hex: 0xC9CBD6)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LX.R.lg).fill(LX.C.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: LX.R.lg).strokeBorder(LX.C.accent.opacity(0.16), lineWidth: 1))
        }
    }

    // MARK: Mini Chat
    private var miniChatPage: some View {
        let hotKey = GlobalHotKey.shared
        return VStack(alignment: .leading, spacing: 22) {
            group("Shortcut") {
                row("Open Mini Chat", "Works from any app. No Accessibility permission is needed.") {
                    Menu {
                        ForEach(HotKeySpec.choices) { spec in
                            Button { hotKey.set(spec) } label: {
                                if hotKey.current == spec { Label(spec.displayString, systemImage: "checkmark") } else { Text(spec.displayString) }
                            }
                        }
                        Divider()
                        Button("Off") { hotKey.set(nil) }
                    } label: { menuLabel(hotKey.current?.displayString ?? "Off", width: 160) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                row("Status", nil) {
                    Text(hotKey.status.message)
                        .font(LX.F.ui(12))
                        .foregroundStyle({ if case .registered = hotKey.status { LX.C.secondary } else if case .disabled = hotKey.status { LX.C.tertiary } else { LX.C.warn } }())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            group("Conversation") {
                row("Keeps its conversation", "Hiding Mini Chat doesn’t clear it. Temporary chats disappear when Lay X quits; pin to keep one.") {
                    Text("Shared with Chat").font(LX.F.ui(12)).foregroundStyle(LX.C.tertiary)
                }
            }
        }
    }

    private var defaultChatMenu: some View {
        let library = AppServices.shared.models
        let current = library.model(defaultChatID).map { ModelDisplay.name($0.id) }
            ?? AppServices.defaultChatModel(in: library).map { "\(ModelDisplay.name($0.id)) (last used)" } ?? "No models installed"
        return Menu {
            ForEach(library.installed) { m in
                Button(ModelDisplay.name(m.id)) { defaultChatID = m.id.description }
            }
            if !defaultChatID.isEmpty {
                Divider()
                Button("Most recently used") { defaultChatID = "" }
            }
        } label: { menuLabel(current, width: 200) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    func menuLabel(_ text: String, width: CGFloat) -> some View {
        HStack {
            Text(text).font(LX.F.ui(12.5)).foregroundStyle(LX.C.primary).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LX.C.tertiary)
        }
        .padding(.horizontal, 10).frame(width: width, height: LX.S.control)
        .well(radius: LX.R.md, fill: Color.black.opacity(0.28))
    }

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
        panel.message = "Choose the folder Lay X uses for models. Model folders (owner/name) already in it are listed too."
        panel.directoryURL = AppServices.shared.models.store.root
        if panel.runModal() == .OK, let url = panel.url {
            storageError = AppServices.shared.models.changeStorage(to: url)
        }
    }

    private var defaultWorkMenu: some View {
        let library = AppServices.shared.models
        let current = library.model(defaultWorkID).map { ModelDisplay.name($0.id) } ?? "Same as Chat"
        return Menu {
            Button("Same as Chat") { defaultWorkID = "" }
            Divider()
            ForEach(library.installed) { m in Button(ModelDisplay.name(m.id)) { defaultWorkID = m.id.description } }
        } label: { menuLabel(current, width: 200) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .well()
                .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
        }
    }

    func row<C: View>(_ title: String, _ help: String?, @ViewBuilder control: () -> C) -> some View {
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

/// Multi-line persona editor used on the Soul page.
struct SoulEditor: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    /// When set, shows a reset button instead of Clear.
    var resetTitle: String? = nil
    var onReset: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(LX.F.body).foregroundStyle(LX.C.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(LX.F.body).foregroundStyle(LX.C.body)
                        .scrollContentBackground(.hidden)
                        .lineSpacing(4)
                        .onChange(of: text) { _, new in
                            if new.count > ChatPreferences.soulLimit { text = String(new.prefix(ChatPreferences.soulLimit)) }
                        }
                }
                .frame(minHeight: 160)
                .padding(.horizontal, 11).padding(.vertical, 8)
                Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1)
                HStack {
                    Text("\(text.count.formatted()) / \(ChatPreferences.soulLimit.formatted())")
                        .font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary)
                    Spacer()
                    if let onReset {
                        if let resetTitle { LXButton(title: resetTitle) { onReset() } }
                        else { Text("Default").font(LX.F.mono(11)).foregroundStyle(LX.C.tertiary) }
                    } else {
                        LXButton(title: "Clear") { text = "" }.disabled(text.isEmpty)
                    }
                }
                .padding(.horizontal, 16).frame(height: 44)
            }
            .well()
            .clipShape(RoundedRectangle(cornerRadius: LX.R.lg))
        }
    }
}
