import Foundation
import LayXCore

/// Settings → Image Generation (UserDefaults).
enum ImagePreferences {
    static let keepLoadedKey = "lx.image.keepLoadedMinutes"      // 0 = unload after each run, -1 = until quit
    static let makeRoomKey = "lx.image.makeRoom"                 // unload an idle chat model when memory is short
    static let stepsKey = "lx.image.steps"
    static let countKey = "lx.image.count"
    static let modelKey = "lx.image.model"

    static var keepLoaded: Duration? {
        let minutes = UserDefaults.standard.object(forKey: keepLoadedKey) as? Int ?? 5
        return minutes < 0 ? nil : .seconds(minutes * 60)
    }
    static var makeRoom: Bool { UserDefaults.standard.object(forKey: makeRoomKey) as? Bool ?? true }
    static var spec: ImageModelSpec {
        UserDefaults.standard.string(forKey: modelKey).flatMap(ImageModelSpec.spec) ?? .sdxlTurbo
    }
}
