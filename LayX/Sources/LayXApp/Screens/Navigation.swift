import SwiftUI

// Top-level screens of the main window.

enum Screen: String, CaseIterable, Identifiable {
    case chat, work, image, models, performance, api, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .work: "Work"
        case .image: "Image"
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
        case .image: "photo.on.rectangle.angled"
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
        case .image: "3"
        case .models: "4"
        case .performance: "5"
        case .api: "6"
        case .settings: ","
        }
    }
}

