import Foundation
import ServiceManagement

/// Launch-at-login, via `SMAppService.mainApp` (macOS 13+).
///
/// This is the modern replacement for the old `SMLoginItemSetEnabled` /
/// login-items-plist dance — no helper bundle, no deprecated API. macOS records
/// the registration against this app's code signature, so the toggle only
/// persists reliably for a *signed* build; an ad-hoc dev build can register but
/// the OS may drop it across reinstalls. That's a dev-only wrinkle — the shipped,
/// notarized app is stable.
///
/// A registered login item launches the app in the background at login. Because
/// the app is `LSUIElement`, that means a menu-bar icon quietly appearing, which
/// is exactly the intent for something you talk to rather than open.
@MainActor
enum LoginItem {
    /// Whether the app is currently set to open at login. `.enabled` is the one
    /// we treat as on; `.requiresApproval` means the user disabled it (or MDM
    /// did) in System Settings > General > Login Items and must re-approve there.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the OS is deferring to the user in System Settings — we can't
    /// flip it programmatically from here, so the UI should point them there.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Turns launch-at-login on or off. Returns whether the end state matches the
    /// request; on failure the caller can surface the System Settings route.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // register() is a no-op if already enabled, so calling it when
                // the status is .requiresApproval is harmless — but it won't
                // override a user's explicit opt-out; that lives in Settings.
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled == enabled
        } catch {
            NSLog("[login-item] failed to \(enabled ? "register" : "unregister"): \(error)")
            return false
        }
    }

    /// Opens the Login Items pane so the user can approve or remove the item
    /// themselves — the only recourse when the status is `.requiresApproval`.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
