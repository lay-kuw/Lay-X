import Foundation

enum AppearancePreferences {
    /// When on and macOS "Reduce transparency" is on, glass becomes solid (transparency 0).
    static let followReduceTransparencyKey = "lx.followReduceTransparency"
    /// Close the app when the main window closes (off: Mini Chat and the API server keep running).
    static let quitOnCloseKey = "lx.quitWhenWindowCloses"
}
