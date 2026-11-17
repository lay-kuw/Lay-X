import Foundation

/// A global keyboard shortcut (Carbon virtual key code + Carbon modifier mask), registered with
/// `RegisterEventHotKey` — which needs no Accessibility / Input Monitoring permission.
public struct HotKeySpec: Sendable, Hashable, Codable, Identifiable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public var id: String { "\(modifiers)-\(keyCode)" }

    // Carbon constants (HIToolbox/Events.h), duplicated so Core stays UI-framework free.
    public static let cmd: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    public static let keySpace: UInt32 = 49
    public static let keyReturn: UInt32 = 36
    public static let keyL: UInt32 = 37
    public static let keyK: UInt32 = 40

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default: ⌥Space.
    public static let `default` = HotKeySpec(keyCode: keySpace, modifiers: option)

    /// Shortcuts offered in Settings (a curated list avoids building a key recorder and steers clear of
    /// ⌘Space / ⌃Space, which macOS reserves for Spotlight and input sources).
    public static let choices: [HotKeySpec] = [
        .default,
        HotKeySpec(keyCode: keySpace, modifiers: option | shift),
        HotKeySpec(keyCode: keySpace, modifiers: control | option),
        HotKeySpec(keyCode: keySpace, modifiers: cmd | option),
        HotKeySpec(keyCode: keyL, modifiers: cmd | shift),
        HotKeySpec(keyCode: keyK, modifiers: control | option),
    ]

    /// A shortcut must include at least one of ⌘ ⌥ ⌃ (Shift alone would swallow normal typing).
    public var isValid: Bool { modifiers & (Self.cmd | Self.option | Self.control) != 0 }

    public var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        switch keyCode {
        case Self.keySpace: s += "Space"
        case Self.keyReturn: s += "Return"
        case Self.keyL: s += "L"
        case Self.keyK: s += "K"
        default: s += "Key \(keyCode)"
        }
        return s
    }

    // MARK: Persistence (UserDefaults string "modifiers-keyCode"; "off" disables)

    public static func decode(_ raw: String?) -> HotKeySpec?? {
        guard let raw else { return .some(.default) }  // never configured → default
        if raw == "off" { return .some(nil) }
        let parts = raw.split(separator: "-").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }  // corrupt → caller falls back
        let spec = HotKeySpec(keyCode: parts[1], modifiers: parts[0])
        return spec.isValid ? .some(spec) : nil
    }

    public static func encode(_ spec: HotKeySpec?) -> String { spec?.id ?? "off" }
}

/// Outcome of registering the global shortcut, shown in Settings.
public enum HotKeyStatus: Sendable, Equatable {
    case disabled
    case registered(HotKeySpec)
    /// Another app (or the system) already owns this shortcut.
    case conflict(HotKeySpec)
    case failed(HotKeySpec, code: Int32)

    /// Carbon's `eventHotKeyExistsErr`.
    public static let alreadyRegisteredCode: Int32 = -9878

    public static func from(osStatus: Int32, spec: HotKeySpec) -> HotKeyStatus {
        switch osStatus {
        case 0: .registered(spec)
        case alreadyRegisteredCode: .conflict(spec)
        default: .failed(spec, code: osStatus)
        }
    }

    public var message: String {
        switch self {
        case .disabled: "Off — open Mini Chat from the Chat menu."
        case .registered(let s): "\(s.displayString) opens Mini Chat from any app."
        case .conflict(let s): "\(s.displayString) is already used by another app. Choose a different shortcut."
        case .failed(let s, let code): "\(s.displayString) couldn’t be registered (error \(code))."
        }
    }
}
