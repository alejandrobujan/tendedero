import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static let helperID = "app.tendedero.Tendedero.LoginHelper"

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { return true }
        }
        // Apple recommends this legacy query for SMLoginItemSetEnabled jobs.
        let jobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: Any]]
        return jobs?.contains { $0["Label"] as? String == helperID } ?? false
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            // Remove a Monterey registration when toggling after an OS upgrade.
            _ = SMLoginItemSetEnabled(helperID as CFString, false)
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } else if !SMLoginItemSetEnabled(helperID as CFString, enabled) {
            throw NSError(domain: helperID, code: 1)
        }
    }
}
