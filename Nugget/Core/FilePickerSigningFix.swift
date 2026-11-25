import Darwin
import Foundation
import Security
import UIKit
import UniformTypeIdentifiers

/// Makes the system document picker usable when the installed app's bundle ID does
/// not match the application ID in the signature.
///
/// Paid-cert sideloaders (Esign, Ksign, Feather, and the same class of re-signing
/// tools) often sign an IPA whose `CFBundleIdentifier` is still GoldenNugget's,
/// while the provisioning profile's `application-identifier` is a different ID or
/// a wildcard. `UIDocumentPickerViewController` builds its file-provider host
/// identity from that entitlement and asks iOS for documents on behalf of it; the
/// mismatch makes the sheet open with nothing selectable even though every
/// `.fileImporter` call site is present and the URL handlers are correct. The
/// same mismatch also makes "open in place" reject files whose types the signed
/// identity is not registered to open.
///
/// This is fixed at the UIKit boundary, once at launch, instead of at the twelve
/// SwiftUI call sites. `.fileImporter` is a wrapper around
/// `UIDocumentPickerViewController`, so one hook covers every importer on every
/// page (Files upload, pairing, templates, presets, PosterBoard, autosave,
/// themes, catalog) without changing their handlers.
///
/// Two changes are installed, and only on a mismatched install:
///
///   1. `UIDocumentPickerViewController.initForOpeningContentTypes:asCopy:` is
///      exchanged with a local implementation that uses the broad file/folder
///      types and asks for a copy. That is the in-app equivalent of the
///      long-standing "file picker fix" dylib: the picker stops filtering on
///      declarations the signed identity cannot see, and the selected file is
///      delivered into this app's container rather than opened in place.
///   2. `DOCConfiguration.setHostIdentifier:` is exchanged with an implementation
///      that passes the application ID from the real code signature, minus its
///      team prefix, instead of the bundle ID UIKit would otherwise use. This is
///      the part that actually addresses the entitlement mismatch; the broad
///      types alone only make the files visible.
///
/// On a correctly signed install (bundle ID == application ID) neither method is
/// touched, so the platform picker keeps its normal filtering and behaviour.
/// The entitlement lookup uses the two private Security symbols that
/// `SecTaskCopyValueForEntitlement` is implemented by; iOS does not expose them
/// in its public SDK headers, so they are resolved with `dlsym` at launch. If a
/// future OS renames or removes them, the lookup returns nil and the app keeps
/// the stock picker instead of failing to launch on an undefined symbol.
final class FilePickerSigningFix {
    /// Called from `GoldenNuggetApp.init()` before any view can present a picker.
    static func install() { shared.install() }

    static let shared = FilePickerSigningFix()

    private let lock = NSLock()
    private var installed = false
    private var hostIdentifierHookInstalled = false

    /// The signed application ID without its `TEAMID.` prefix. Read once at
    /// launch and used by the `DOCConfiguration` hook below.
    fileprivate private(set) var correctedHostIdentifier: String?

    private init() {}

    private static let entitlementKey = "application-identifier" as CFString
    private static let pickerInitSelector = NSSelectorFromString("initForOpeningContentTypes:asCopy:")
    private static let pickerFixSelector = NSSelectorFromString("gn_filePickerFix_initForOpeningContentTypes:asCopy:")
    private static let hostSelector = NSSelectorFromString("setHostIdentifier:")
    private static let hostFixSelector = NSSelectorFromString("gn_filePickerFix_setHostIdentifier:")

    private func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        guard let signed = Self.signedApplicationIdentifier(),
              let applicationID = Self.applicationIDWithoutTeam(signed) else { return }
        let bundleID = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
        guard Self.needsFix(applicationID: applicationID, bundleID: bundleID) else { return }

        correctedHostIdentifier = applicationID
        Self.hookDocumentPicker()
        AppLog.write("FilePickerFix: enabled for \(applicationID) (bundle \(bundleID ?? "unknown"))")
        // The DOCConfiguration hook is installed from the picker hook below:
        // that private class may not be realised until the first picker exists.
        // Calling it here would also re-enter the lock this method holds.
    }

    /// `DOCConfiguration` is a private UIKit class that may not be realised until
    /// the first picker is built, so the hook is attempted from the picker hook.
    /// `NSLock` makes repeated attempts harmless.
    fileprivate func installHostIdentifierHookIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hostIdentifierHookInstalled else { return }
        guard self.correctedHostIdentifier != nil else { return }
        guard let configurationClass = NSClassFromString("DOCConfiguration"),
              let original = class_getInstanceMethod(configurationClass, Self.hostSelector) else {
            return
        }
        // The replacement IMP lives on NSObject so Swift can compile it, but it
        // must be *added* to DOCConfiguration before swapping: exchanging a
        // method inherited from NSObject would change every object in the
        // process, not just the file picker's configuration.
        guard let replacement = class_getInstanceMethod(NSObject.self, Self.hostFixSelector),
              class_addMethod(configurationClass, Self.hostFixSelector,
                              method_getImplementation(replacement),
                              method_getTypeEncoding(replacement)),
              let added = class_getInstanceMethod(configurationClass, Self.hostFixSelector) else {
            return
        }
        method_exchangeImplementations(original, added)
        hostIdentifierHookInstalled = true
    }

    private static func hookDocumentPicker() {
        guard let original = class_getInstanceMethod(UIDocumentPickerViewController.self, pickerInitSelector),
              let replacement = class_getInstanceMethod(UIDocumentPickerViewController.self, pickerFixSelector) else {
            AppLog.write("FilePickerFix: UIKit hook unavailable")
            return
        }
        method_exchangeImplementations(original, replacement)
    }

    private static func needsFix(applicationID: String, bundleID: String?) -> Bool {
        if applicationID.contains("*") { return true }
        guard let bundleID else { return true }
        return applicationID.caseInsensitiveCompare(bundleID) != .orderedSame
    }

    /// `TEAMID.com.example.app` -> `com.example.app`. A wildcard profile yields
    /// `TEAMID.*`, which is passed through as `*`; UIKit expects the signed
    /// identity, not the bundle ID, in exactly that case too.
    private static func applicationIDWithoutTeam(_ identifier: String) -> String? {
        guard let dot = identifier.firstIndex(of: ".") else { return identifier }
        let start = identifier.index(after: dot)
        guard start < identifier.endIndex else { return nil }
        return String(identifier[start...])
    }

    private static func signedApplicationIdentifier() -> String? {
        // dlsym, not a direct @_silgen_name reference: a future OS without the
        // private symbols would otherwise turn into a dyld launch failure.
        guard let create: SecTaskCreate = loadedSymbol("SecTaskCreateFromSelf"),
              let copy: SecTaskCopy = loadedSymbol("SecTaskCopyValueForEntitlement"),
              let release: ReleaseCFObject = loadedSymbol("CFRelease") else {
            return nil
        }
        guard let task = create(nil) else { return nil }
        defer { release(task) }
        guard let value = copy(task, entitlementKey, nil) else { return nil }
        defer { value.release() }
        return value.takeUnretainedValue() as? String
    }

    private static func loadedSymbol<T>(_ name: String) -> T? {
        // dlfcn.h defines RTLD_DEFAULT as ((void *) -2); Swift does not import
        // that macro on iOS, so spell the value out here.
        let defaultSearch = UnsafeMutableRawPointer(bitPattern: -2)!
        guard let address = name.withCString({ dlsym(defaultSearch, $0) }) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}

// MARK: - Private Security entry points

// The C signatures from LiveContainer's FoundationPrivate.h. `SecTaskCreateFromSelf`
// returns an opaque handle, and `SecTaskCopyValueForEntitlement` returns a
// +1-retained CFTypeRef; Swift's own CFRelease overload only accepts
// class-constrained CFTypeRef values, so the opaque handle is released through
// the C symbol as well.
private typealias SecTaskCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias SecTaskCopy = @convention(c) (
    UnsafeMutableRawPointer?, CFString?, UnsafeMutableRawPointer?
) -> Unmanaged<CFTypeRef>?
private typealias ReleaseCFObject = @convention(c) (UnsafeMutableRawPointer?) -> Void

// MARK: - Objective-C hooks

private extension UIDocumentPickerViewController {
    /// Installed in place of UIKit's modern document-picker initialiser. Calling
    /// the same selector here reaches the *original* implementation after the
    /// exchange, so there is no recursion and no second alloc/init cycle.
    @objc(gn_filePickerFix_initForOpeningContentTypes:asCopy:)
    dynamic func gn_filePickerFix_initForOpeningContentTypes(
        _ contentTypes: [UTType],
        asCopy: Bool
    ) -> UIDocumentPickerViewController {
        FilePickerSigningFix.shared.installHostIdentifierHookIfNeeded()
        return gn_filePickerFix_initForOpeningContentTypes([.item, .folder], asCopy: true)
    }
}

private extension NSObject {
    /// Copied onto the private `DOCConfiguration` class at hook time. After the
    /// exchange this selector is the original `setHostIdentifier:`, so passing
    /// the signature-derived ID calls UIKit's real setter with the right value.
    @objc(gn_filePickerFix_setHostIdentifier:)
    dynamic func gn_filePickerFix_setHostIdentifier(_ hostIdentifier: String) {
        let corrected = FilePickerSigningFix.shared.correctedHostIdentifier ?? hostIdentifier
        gn_filePickerFix_setHostIdentifier(corrected)
    }
}
