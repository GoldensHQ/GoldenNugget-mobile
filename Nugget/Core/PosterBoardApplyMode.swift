import Foundation

/// How a PosterBoard selection reaches the device.
///
/// There are two, and they are not two implementations of one thing — they are two
/// different mechanisms that happen to install the same wallpapers, so the choice
/// belongs to the user and the UI has to say what it costs.
///
///  - `.backup` is this port's original path: fetch the store's database, compile
///    the packs into payloads, and ride them through a protective backup and a
///    restore. It is the *reference's* mechanism, it works on every device the
///    rest of the app works on, and it ends in a reboot.
///  - `.airlift` is the AirCard path: open an AirTraffic tunnel over the pairing
///    record this app already holds and write straight into PosterBoard's data
///    container. No backup, no reboot — a respring is enough — but it needs
///    iOS 26.2+, LocalDevVPN, an unlocked device, and it cannot do a store reset.
///    It remains functional but is **deprecated** for PosterBoard: the page labels
///    it, new installs start on `.backup`, and the run log warns when it is used.
///
/// Protective backup is now the default. It costs a full backup and a reboot, but
/// it is the supported path: it works on every device the rest of the app works
/// on and is the only one that can do a store reset. A stored `.airlift` choice is
/// still honoured so the deprecated path does not silently change under a user,
/// but nothing new defaults to it.
enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case airlift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backup: return String(localized: "Protective backup")
        case .airlift: return String(localized: "AirLift (AirTraffic)")
        }
    }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .airlift: return "bolt.horizontal.circle.fill"
        }
    }

    /// Whether the mode is still offered but no longer recommended.
    ///
    /// This is a product-level deprecation, not a compiler one: `.airlift` stays
    /// available and is still called by both entry points, but the picker labels
    /// it and the page explains why `.backup` is the default.
    var isDeprecated: Bool { self == .airlift }

    /// What the apply will and will not do, in the user's terms.
    var summary: String {
        switch self {
        case .backup:
            return "Fetches the store database, then carries the wallpapers through a "
                + "protective backup. Works on every supported device, ends in a reboot."
        case .airlift:
            return "Writes into PosterBoard's container over a tunnel — no backup, and a "
                + "respring instead of a reboot. Needs iOS 26.2 or newer, LocalDevVPN and "
                + "an unlocked device."
        }
    }

    /// Whether a reset can be honoured in this mode.
    ///
    /// A reset is a store operation: it clears what PosterBoard has indexed. The
    /// AirLift path only ever adds a descriptor directory, so a reset selected
    /// there is not silently dropped — the apply says it cannot and stops before
    /// touching the device.
    var supportsReset: Bool {
        self == .backup
    }
}

/// The selected mode, persisted the same way `autoRefresh` is.
enum PosterBoardApplyModeSettings {
    static let key = "PosterBoardApplyMode"

    /// Protective backup unless the user chose the deprecated AirLift path.
    ///
    /// A device that has never touched the picker has nothing stored, so the
    /// default is what such a device gets: `.backup`, the supported path. A
    /// stored `.airlift` choice is still read back, so deprecation does not
    /// quietly change an apply a user has already set up. `resolved` then drops
    /// that choice only when the device cannot use it at all.
    static func resolved(deviceVersion: String, buildVersion: String) -> PosterBoardApplyMode {
        if AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return .backup
        }
        return current
    }

    static var current: PosterBoardApplyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .backup }
            return PosterBoardApplyMode(rawValue: raw) ?? .backup
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
