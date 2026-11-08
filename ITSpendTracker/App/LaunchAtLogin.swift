import Foundation
import ServiceManagement

/// Registers the app as a login item (DEC-037). Only meaningful for an installed copy (e.g. /Applications);
/// macOS refuses to register apps running from a build folder, which is reported, not fatal.
enum LaunchAtLogin {
    private static let askedKey = "launchAtLoginRegistered"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(true, forKey: askedKey)
    }

    /// First launch of an installed copy: register once; later the user's choice in Settings rules.
    static func registerOnFirstInstalledLaunch() {
        guard !UserDefaults.standard.bool(forKey: askedKey),
              Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        try? setEnabled(true)
    }
}
