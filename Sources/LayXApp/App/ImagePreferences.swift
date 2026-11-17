import Foundation
import LayXCore

/// Settings → Image Generation and the Image composer's remembered values (UserDefaults).
enum ImagePreferences {
    static let keepLoadedKey = "lx.image.keepLoadedMinutes"      // 0 = unload after each run, -1 = until quit
    static let makeRoomKey = "lx.image.makeRoom"                 // unload an idle chat model when memory is short
    static let countKey = "lx.image.count"
    static let seedModeKey = "lx.image.seedMode"
    static let paramsKey = "lx.image.params"                     // per-model steps / CFG / size
    static let lorasKey = "lx.image.activeLoRAs"

    static var keepLoaded: Duration? {
        let minutes = UserDefaults.standard.object(forKey: keepLoadedKey) as? Int ?? 5
        return minutes < 0 ? nil : .seconds(minutes * 60)
    }
    static var makeRoom: Bool { UserDefaults.standard.object(forKey: makeRoomKey) as? Bool ?? true }

    /// The model chosen in the Image picker this session (nil at launch and after unloading it).
    @MainActor static var spec: ImageModelSpec? {
        let installed = AppServices.shared.models.imageModels
        guard let id = AppServices.shared.images.selectedModelID else { return nil }
        return installed.first { $0.id.description == id }.map { ImageModelSpec.spec(for: $0) }
    }

    @MainActor static func select(_ id: ModelRepoID?) { AppServices.shared.images.selectedModelID = id?.description }

    /// Steps, CFG and size remembered per model (defaults from the model).
    struct Params: Codable, Equatable {
        var steps: Int
        var cfg: Double
        var width: Int
        var height: Int
        var size: ImageSize { .init(width, height) }

        static func defaults(_ spec: ImageModelSpec) -> Params {
            Params(steps: spec.defaultSteps, cfg: spec.defaultCFG, width: spec.defaultSize.width, height: spec.defaultSize.height)
        }
    }

    static func params(for spec: ImageModelSpec) -> Params {
        let all = (UserDefaults.standard.data(forKey: paramsKey)).flatMap { try? JSONDecoder().decode([String: Params].self, from: $0) } ?? [:]
        return all[spec.id.description] ?? .defaults(spec)
    }

    static func setParams(_ p: Params, for spec: ImageModelSpec) {
        var all = (UserDefaults.standard.data(forKey: paramsKey)).flatMap { try? JSONDecoder().decode([String: Params].self, from: $0) } ?? [:]
        all[spec.id.description] = p
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: paramsKey)
    }

    static var activeLoRAs: [LoRAChoice] {
        get { UserDefaults.standard.data(forKey: lorasKey).flatMap { try? JSONDecoder().decode([LoRAChoice].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lorasKey) }
    }
}
