import Foundation
import ServiceManagement

/// User preferences stored in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    enum CompressionStrength: Int { case balanced = 0, strong = 1 }

    static var compression: CompressionStrength {
        get { CompressionStrength(rawValue: d.integer(forKey: "compression")) ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "compression") }
    }
    /// Optional longest-edge limit applied when compressing images/videos. 0 = no resize.
    static var compressMaxDimension: Int {
        get { d.integer(forKey: "compressMaxDimension") }
        set { d.set(newValue, forKey: "compressMaxDimension") }
    }
    static var ffmpegPath: String? {
        get { d.string(forKey: "ffmpegPath") }
        set { d.set(newValue, forKey: "ffmpegPath") }
    }
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var hasSeenWelcome: Bool {
        get { d.bool(forKey: "hasSeenWelcome") }
        set { d.set(newValue, forKey: "hasSeenWelcome") }
    }
    static var revealResults: Bool {
        get { d.object(forKey: "revealResults") as? Bool ?? false }
        set { d.set(newValue, forKey: "revealResults") }
    }
    static var playSounds: Bool {
        get { d.object(forKey: "playSounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSounds") }
    }
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("Launch at login failed: \(error)") }
        }
    }
}
