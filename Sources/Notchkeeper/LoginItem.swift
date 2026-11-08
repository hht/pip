import AppKit
import ServiceManagement

/// Launch at login: SMAppService.mainApp (macOS 13+). Works with local ad-hoc signatures, though toggling off and on may be required if App is relocated or re-signed.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func text(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return String(localized: "On")
        case .requiresApproval: return String(localized: "Needs approval in System Settings › General › Login Items")
        case .notRegistered: return String(localized: "Off")
        case .notFound: return String(localized: "Can't find the app; it may have been moved. Turn this off and on again.")
        @unknown default: return String(localized: "Unknown")
        }
    }

    /// Returns nil on success, otherwise localized error description.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
