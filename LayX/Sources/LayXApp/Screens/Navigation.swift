import SwiftUI

// Top-level screens of the main window.

enum Screen: String, CaseIterable, Identifiable {
    case chat, work, models, performance, api, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .work: "Work"
        case .models: "Models"
        case .performance: "Performance"
        case .api: "API Server"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .work: "folder"
        case .models: "shippingbox"
        case .performance: "chart.bar"
        case .api: "server.rack"
        case .settings: "gearshape"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .chat: "1"
        case .work: "2"
        case .models: "3"
        case .performance: "4"
        case .api: "5"
        case .settings: ","
        }
    }
}

