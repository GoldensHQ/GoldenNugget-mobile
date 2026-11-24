import Foundation

/// Turns Passbook's syslog chatter into card identifiers.
///
/// This used to live in `WalletCardSkin.swift` and took *any* quoted token of
/// 20–64 characters as a card: `cleanIdentifier` only checked the length and
/// rejected UUIDs, and `quoted(in:)` dutifully handed it every quoted string in
/// the device log. Bundle IDs, XPC service names and cache keys all qualified,
/// so one scan added dozens of invented, permanently blank cards — and the
/// Wallet page draws a full-size card mockup for each one, which is what made
/// the app lag.
///
/// The fix is the same one AirCard uses: only the message shapes Passbook and
/// `nfcd` actually emit are recognised, known placeholder hashes are dropped,
/// and the loose 28-character token is accepted only on a line that is really
/// about Wallet and only when no high-confidence match was found. Nothing here
/// touches UIKit so the parser can be exercised by a host-side Swift check.
enum WalletCardIDs {
    /// Hashes Passbook logs for card-like bookkeeping but that are not cards.
    /// The same denylist AirCard ships; keeping it here also purges them from
    /// stores written by older builds.
    static let placeholders: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    /// Character set of a real pass identifier: base64-ish, with `-`, `_` and
    /// `+` instead of whitespace, and usually a trailing `=`.
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-=")

    /// Anchored log forms. A bare quoted token is deliberately not one of them.
    private static let cardReferences: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s"'),]|$)"#),
        try! NSRegularExpression(
            pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s"'),]|$)"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s"'),]|$)"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s"'),]|$)"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s"'),]|$)"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,80})(?=[,\s"')]|$)"#,
            options: .caseInsensitive),
        try! NSRegularExpression(
            pattern: #"Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,80})\s+-"#,
            options: .caseInsensitive),
    ]

    /// `nfcd` prints the pass IDs of an interaction as a parenthesised list.
    private static let inSessionList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*[:=]\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive)
    private static let cardID = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#)

    /// Last-resort form: the 27-character hash ending in `=` that iOS 27's
    /// dashboard logs. Used only with a Wallet context and only if nothing
    /// above matched, or it would fire on unrelated base64 in the syslog.
    private static let fallbackToken = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9+/=])([A-Za-z0-9+/_-]{27}=)(?![-A-Za-z0-9+/=])"#)
    private static let walletProcesses = [
        "passd", "passbook", "passkit", "stockholm", "nanopassd", "wallet", "/cards/"]
    private static let cardContext = [
        "card", "pass", "payment", "pkpass", "uniqueid", "identifier", "face",
        "cache", "stockholm", "/cards/"]

    /// Clean an identifier out of a log line, a filename or a paste.
    ///
    /// A port of `CardItem.cleanCardId`, with the strict shape and denylist
    /// applied at the end: a bare UUID is still rejected because it would make
    /// a plausible-looking write to a path that does not exist.
    static func cleanIdentifier(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if value.contains("/") {
            value = (value as NSString).lastPathComponent
        }
        for ext in [".pkpass", ".cache", ".pkcache"] where value.hasSuffix(ext) {
            value = String(value.dropLast(ext.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard isValidIdentifier(value) else { return nil }
        return value
    }

    /// Whether a stored identifier can still be a real card.
    ///
    /// Used when loading `wallet-cards.json` as well as by the parser: a store
    /// written by an older build is full of the quoted-token junk, and those
    /// cards have to disappear on launch rather than waiting for the user to
    /// delete them one by one.
    static func isValidIdentifier(_ value: String) -> Bool {
        guard (20...64).contains(value.count), !value.contains("/"),
              value.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
        if value.count == 36, value.filter({ $0 == "-" }).count == 4 { return false }
        return !placeholders.contains(value)
    }

    /// Every real card identifier in one log line, without duplicates.
    static func identifiers(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen: Set<String> = []
        var result: [String] = []

        func add(_ raw: String) {
            guard let clean = cleanIdentifier(raw), seen.insert(clean).inserted else { return }
            result.append(clean)
        }

        for pattern in cardReferences {
            for match in pattern.matches(in: line, range: lineRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                add(String(line[range]))
            }
        }

        for match in inSessionList.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let list = String(line[range])
            let listRange = NSRange(list.startIndex..., in: list)
            for token in cardID.matches(in: list, range: listRange) {
                guard let tokenRange = Range(token.range, in: list) else { continue }
                add(String(list[tokenRange]))
            }
        }

        if result.isEmpty, isWalletLine(line) {
            for match in fallbackToken.matches(in: line, range: lineRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                add(String(line[range]))
            }
        }
        return result
    }

    private static func isWalletLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return walletProcesses.contains { lower.contains($0) }
            && cardContext.contains { lower.contains($0) }
    }
}
