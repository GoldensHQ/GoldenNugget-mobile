import CoreLocation
import Foundation
import UIKit

/// Why an apply was refused when the Always-location requirement is enabled.
///
/// Deliberately English, like the app's other `LocalizedError` descriptions:
/// this text goes into the run log and into the bug report a user attaches.
enum ApplyLocationRequirementError: LocalizedError {
    case alwaysRequired(CLAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .alwaysRequired(let status):
            switch status {
            case .denied, .restricted:
                return "Always Location permission is required to apply. Set Location to Always in Settings, or turn off “Require Always Location for apply” there."
            default:
                return "Always Location permission is required to apply. Grant Always access when prompted, then tap Apply again — or turn off “Require Always Location for apply” in Settings."
            }
        }
    }
}

/// Keeps an apply run alive while the app is not on screen.
///
/// An apply is minutes of device I/O — a protective backup, a manifest rewrite,
/// then a restore.  Three things can stop it when the user leaves the app, so
/// this service owns all three for exactly the lifetime of the run:
///
///   1. `UIApplication.isIdleTimerDisabled` — the screen must not sleep midway
///      through a restore.  The previous value is restored on `finish`, so an
///      app that did not want the timer disabled before the run still does not
///      want it disabled afterwards.
///   2. A self-renewing UIKit background task.  UIKit grants roughly 30 seconds;
///      the expiration handler ends that task and immediately asks for the next
///      one while a run is still active.  This is what keeps the Swift `Task`
///      in `GoldenNuggetView.runApply` executing.
///   3. Background location updates with Always authorization.  UIKit eventually
///      stops granting background time; a background-location app keeps getting
///      woken until the run ends.  No location is read, stored or sent — the
///      events are used only as a wake-up source. That part is required by
///      default; Settings has an explicit opt-out for devices where Always
///      cannot be granted, in which case the first two mechanisms still apply.
///
/// Every choice here is scoped to `start`/`finish`.  There is no global switch
/// that leaves the screen awake or the location icon on after an apply.
@MainActor
final class ApplyKeepAlive: NSObject, ObservableObject {
    static let shared = ApplyKeepAlive()

    enum Key {
        static let requireAlways = "ApplyKeepAlive.RequireAlways"
    }

    /// Plain `UserDefaults`, not `@AppStorage`: the engine reads the setting on
    /// the main actor before a run, and Settings binds through the setter below
    /// so the published value and the stored value cannot disagree.
    private static var storedRequireAlways: Bool {
        get { UserDefaults.standard.object(forKey: Key.requireAlways) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.requireAlways) }
    }

    // MARK: - Published state (Settings reads these)

    /// The current Always/When In Use/never state, for the Settings row.
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = CLLocationManager().authorizationStatus

    /// Whether Apply refuses to start until location access is Always.
    ///
    /// On by default: a run that cannot keep going after the user leaves the
    /// app is not a run the user agreed to. Settings exposes the opt-out for a
    /// device where Always cannot be granted; the engine reads this same value
    /// on the main actor when it claims the keepalive.
    @Published private(set) var requireAlways: Bool = ApplyKeepAlive.storedRequireAlways

    /// Whether background location updates are running right now.
    @Published private(set) var usingLocation = false

    /// Whether a run owns the keepalive.
    @Published private(set) var isApplying = false

    // MARK: - Run-owned state

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var previousIdleTimerDisabled = false
    private var locationManager: CLLocationManager?
    private var locationUpdateCount = 0

    /// Only the run that claimed the keepalive may release it.  A second apply
    /// rejected by `InFlightCall` still runs its own error path; without a
    /// token that path would stop the first run's keepalive.
    private var ownerToken: UUID?

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Claim the keepalive for one apply.  Called from `GoldenNuggetEngine` just
    /// before the run is reserved in `InFlightCall`; `finish` is its exact
    /// counterpart and is called on both the success and the failure path.
    ///
    /// Throws before claiming anything when the Always-location requirement is
    /// on but unmet. This is the engine-side guard: the Apply button runs the
    /// same preflight before its confirmation sheet, but a run must never
    /// depend on a particular view having done so.
    @discardableResult
    func start() throws -> UUID {
        // A rejected overlapping apply gets a token that owns nothing, so its
        // error path cannot release the keepalive held by the live run.
        guard !isApplying else { return UUID() }
        try requireAlwaysLocationForApply()
        let token = UUID()
        ownerToken = token
        isApplying = true
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        beginBackgroundTask()
        configureLocationKeepalive()
        log("screen sleep disabled and background task held for this run")
        return token
    }

    /// Release everything the run owned, whether it succeeded, failed or was
    /// stopped.  Order matters: drop the `isApplying` flag first so an in-flight
    /// authorization callback cannot restart location updates after we stop.
    func finish(token: UUID? = nil) {
        guard isApplying else { return }
        if let token, ownerToken != token { return }
        ownerToken = nil
        isApplying = false
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        endBackgroundTask()
        stopLocationUpdates()
        log("screen sleep restored and background keepalive released")
    }

    // MARK: - Screen and UIKit background time

    private func beginBackgroundTask() {
        guard isApplying, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GoldenNugget.ApplyKeepAlive") { [weak self] in
            Task { @MainActor in
                guard let self, self.isApplying else { return }
                // UIKit is about to suspend us.  Handing the expired task back
                // and taking a fresh one is the only supported way to extend the
                // grace period; background location covers the case where UIKit
                // stops granting it.
                self.log("UIKit background time expired — renewing for the active run")
                self.endBackgroundTask()
                self.beginBackgroundTask()
            }
        }
        if backgroundTask == .invalid {
            log("could not start a UIKit background task — the run is only protected while on screen")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Background location keepalive

    private func ensureLocationManager() -> CLLocationManager {
        if let locationManager { return locationManager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.activityType = .other
        // Coarse accuracy and no distance filter: the goal is a frequent, cheap
        // wake-up while a run is active, not a position fix.  No delegate method
        // reads the returned coordinate.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        locationManager = manager
        return manager
    }

    private func configureLocationKeepalive() {
        guard isApplying else { return }
        let manager = ensureLocationManager()
        locationAuthorization = manager.authorizationStatus
        switch locationAuthorization {
        case .authorizedAlways:
            startLocationUpdates()
        case .notDetermined, .authorizedWhenInUse:
            // Only prompt when the requirement is on. The opt-out is a choice
            // to apply *without* background location, not to keep asking for it.
            if requireAlways {
                log("requesting Always location so the apply can continue in the background")
                manager.requestAlwaysAuthorization()
            } else {
                log("location keepalive skipped — opt-out enabled; relying on screen and background task")
            }
        case .denied, .restricted:
            log("location keepalive unavailable (\(Self.locationName(locationAuthorization))) — relying on screen and background task")
        @unknown default:
            break
        }
    }

    private func startLocationUpdates() {
        guard isApplying, !usingLocation else { return }
        let manager = ensureLocationManager()
        guard manager.authorizationStatus == .authorizedAlways else { return }
        locationUpdateCount = 0
        manager.startUpdatingLocation()
        usingLocation = true
        log("background location updates started to keep the run alive")
    }

    private func stopLocationUpdates() {
        guard let locationManager, usingLocation else { return }
        locationManager.stopUpdatingLocation()
        usingLocation = false
    }

    /// Settings binds its toggle to this. Persist first, then publish, so an
    /// apply started from the next tap obeys exactly what the toggle showed.
    func setRequireAlways(_ enabled: Bool) {
        Self.storedRequireAlways = enabled
        requireAlways = enabled
        // Turning the requirement back on during a run is the one moment the
        // keepalive can adopt it without breaking the run already in flight.
        if enabled, isApplying { configureLocationKeepalive() }
    }

    /// The preflight shared by the Apply button and by `start()`.
    ///
    /// Runs before the confirmation sheet so the system prompt is never a
    /// surprise. When the requirement is off this is a no-op; when it is on and
    /// unmet, a still-askable state gets the prompt and *every* unmet state
    /// throws, so no part of a run starts on an authorization we did not agree
    /// to. The user grants access (or opts out in Settings) and taps Apply again.
    func requireAlwaysLocationForApply() throws {
        refresh()
        guard requireAlways else { return }
        guard locationAuthorization != .authorizedAlways else { return }

        let status = locationAuthorization
        if status == .notDetermined || status == .authorizedWhenInUse {
            ensureLocationManager().requestAlwaysAuthorization()
        }
        log("apply requires Always Location; authorization is \(Self.locationName(status))")
        throw ApplyLocationRequirementError.alwaysRequired(status)
    }

    /// Called by Settings.  Requesting outside a run is allowed so the operator
    /// can grant it before the first apply.
    func requestAlwaysLocation() {
        let manager = ensureLocationManager()
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            if isApplying { startLocationUpdates() }
        case .denied, .restricted:
            openAppSettings()
        @unknown default:
            break
        }
    }

    /// Settings uses this when location access is denied or restricted.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Refresh the row when the Settings page appears: iOS Settings may have
    /// changed the permission while the app was in the background.
    func refresh() {
        locationAuthorization = ensureLocationManager().authorizationStatus
    }

    private static func locationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    private func log(_ message: String) {
        GoldenNuggetEngine.shared.log("apply keepalive: \(message)")
    }
}

// MARK: - CLLocationManagerDelegate

extension ApplyKeepAlive: CLLocationManagerDelegate {
    // The delegate methods are nonisolated because UIKit calls them off the
    // main actor; every mutation of the @MainActor state hops back first.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationAuthorization = manager.authorizationStatus
            self.startLocationUpdates()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.isApplying else { return }
            self.locationUpdateCount += 1
            if self.locationUpdateCount == 1 {
                self.log("first background location event received; the run is still executing")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.log("background location error: \(error.localizedDescription)")
        }
    }
}
