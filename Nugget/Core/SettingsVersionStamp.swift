import Foundation

/// The writer-version mark desktop leaves in its settings file.
///
/// Desktop 9.7.10 stamps `GNUGGET_VERSION` on every real `Settings.setValue`
/// call: reads must never create the file, and the legacy `Nugget` store is
/// left untouched so an older build still reads its own preferences.  Mobile
/// has no single settings wrapper — SwiftUI `@AppStorage` and feature-local
/// singletons write `UserDefaults` directly — so the equivalent hook is a
/// `UserDefaults.didChangeNotification` observer installed once at launch.
/// It fires only after a write, refreshes the stamp when the writing build
/// changed, and ignores the notification caused by its own write.
enum SettingsVersionStamp {
    static let writerVersionKey = "GNUGGET_VERSION"

    /// Test override: the offline harness has no app Info.plist, so it supplies
    /// the version it wants stamped instead of reading this process's bundle.
    nonisolated(unsafe) static var writerVersionOverride: String?

    static var writerVersion: String {
        if let override = writerVersionOverride, !override.isEmpty { return override }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        return "0"
    }

    // Written once from the app's main actor at startup and only read for the
    // nil guard; `nonisolated(unsafe)` documents that lifetime to Swift 6.
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Install once from `GoldenNuggetApp.init()`.  Holding the token in a
    /// static keeps the observer alive for the process lifetime.
    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            apply()
        }
    }

    /// Refresh the stamp for a preference write.  Equality is the recursion
    /// guard: writing the stamp posts another notification, which then sees the
    /// current value and does nothing.
    static func apply() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: writerVersionKey) != writerVersion else { return }
        defaults.set(writerVersion, forKey: writerVersionKey)
        defaults.synchronize()
    }
}
