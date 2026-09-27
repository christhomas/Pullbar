import ServiceManagement

/// What "Launch at login" can do for the copy of the app that is running.
///
/// `SMAppService.mainApp` registers the app at its current path, so it only
/// works for an app bundle at a lasting location. The mode is worked out from
/// the bundle path and the login item's status alone, so it can be tested
/// without touching the system.
enum LaunchAtLoginMode: Equatable {
    /// A normal install: the toggle works. `enabled` is its current state.
    case available(enabled: Bool)
    /// Registered, but switched off in System Settings > Login Items; only
    /// the user can switch it back on there.
    case needsApproval
    /// A quarantined download that macOS runs from a random, temporary "App
    /// Translocation" folder until it is moved. A login item registered there
    /// would stop working.
    case moveToApplications
    /// Built by a Homebrew formula into a versioned Cellar folder that the
    /// next `brew upgrade` deletes; `brew services` starts it at login.
    case managedByHomebrew
    /// Not an app bundle at all (`swift run`, `make run`).
    case unavailable

    static func mode(bundlePath: String, status: SMAppService.Status) -> LaunchAtLoginMode {
        guard bundlePath.hasSuffix(".app") else { return .unavailable }
        if bundlePath.contains("/AppTranslocation/") {
            return .moveToApplications
        }
        if bundlePath.contains("/Cellar/") { return .managedByHomebrew }
        switch status {
        case .enabled: return .available(enabled: true)
        case .requiresApproval: return .needsApproval
        default: return .available(enabled: false)
        }
    }

    static var current: LaunchAtLoginMode {
        mode(bundlePath: Bundle.main.bundleURL.path, status: SMAppService.mainApp.status)
    }
}
