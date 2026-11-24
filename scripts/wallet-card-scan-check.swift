// Host check for Wallet card discovery: only real Passbook log messages may
// become cards. The old parser accepted every quoted 20-64 character token in
// the syslog stream, so a scan invented dozens of blank cards; those were then
// persisted and rendered eagerly, which is the lag in issue #17.
//
// The parser is Foundation-only, so this runs on Linux with no device or UIKit:
//
//   mkdir -p /tmp/wallet-scan-check \
//     && cat Nugget/Core/WalletCardIDs.swift scripts/wallet-card-scan-check.swift \
//        > /tmp/wallet-scan-check/main.swift \
//     && swiftc -O /tmp/wallet-scan-check/main.swift -o /tmp/wallet-scan-check/check \
//     && /tmp/wallet-scan-check/check
//
// Identifiers below are synthetic; no device log or real card ID is used.

import Foundation

let card = "ABCDEFGHIJKLMNOPQRSTUVWXY12="          // 27 chars + "="
let second = "ZYXWVUTSRQPONMLKJIHGFEDCBA12="       // 27 chars + "="

var failures = 0
func check(_ label: String, _ actual: [String], _ expected: [String]) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label) — expected \(expected), got \(actual)")
    }
}
func check(_ label: String, _ condition: Bool) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

// The messages Passbook/nfcd actually emit.
check("pkpass path with a cache leaf after it",
      WalletCardIDs.identifiers(in: "/var/mobile/Library/Passes/Cards/\(card).pkpass/preview.png"),
      [card])
check("Cards directory spelling",
      WalletCardIDs.identifiers(in: "Passes/Cards/\(card).cache"),
      [card])
check("Dashboard loading",
      WalletCardIDs.identifiers(in: "PassKitUI: Dashboard loading primary card: for \(card), next"),
      [card])
check("nfcd session list",
      WalletCardIDs.identifiers(in: #"nfcd[12]: passIDs[InSession]: ( "\#(card)", "\#(second)" )"#),
      [card, second])
check("global pass list",
      WalletCardIDs.identifiers(in: #"nfcd[12]: passIDs[global] = ( "\#(card)" )"#),
      [card])
check("PDCardFileManager write",
      WalletCardIDs.identifiers(in: "PDCardFileManager: writing card \(card) to disk"),
      [card])
check("per-line dedup",
      WalletCardIDs.identifiers(in: "/Passes/Cards/\(card).pkpass /Passes/Cards/\(card).cache"),
      [card])

// The bug: arbitrary quoted tokens in an unrelated syslog line.
check("unrelated quoted service name is not a card",
      WalletCardIDs.identifiers(in: #"launchd[1]:Service "com.apple.PassKit.SomeVeryLongServiceName" failed"#),
      [])
check("quoted cache key is not a card",
      WalletCardIDs.identifiers(in: #"securityd: key "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklm" missing"#),
      [])
check("placeholder hashes are not cards",
      WalletCardIDs.identifiers(in: "Dashboard loading for OM6NYhwXMZrAw0sRUjR62wmF4ZQ= and hwAtAmHKYwsQrJbT5cTNDsaxVME="),
      [])
check("fallback token only with Wallet context",
      WalletCardIDs.identifiers(in: "wallet: pass cache token \(card)"),
      [card])
check("fallback token ignored outside Wallet",
      WalletCardIDs.identifiers(in: "launchd: cached asset \(card) for com.apple.foo"),
      [])

// Same validation is used to purge stores written by older builds.
check("UUID is not a card", WalletCardIDs.cleanIdentifier("12345678-1234-1234-1234-123456789012") == nil)
check("dotted service name is not a card",
      WalletCardIDs.isValidIdentifier("com.apple.PassKit.SomeVeryLongServiceName") == false)
check("placeholder is not a valid stored ID",
      WalletCardIDs.isValidIdentifier("M6nDwZrkYbFlsodLgCbvyFZQ1cc=") == false)
check("quoted path cleans to the identifier",
      WalletCardIDs.cleanIdentifier("\"'/var/mobile/Library/Passes/Cards/\(card).pkpass'\"") == card)
check("cleaning is idempotent", WalletCardIDs.cleanIdentifier(card) == card)

print(failures == 0 ? "wallet card scan: all checks passed" : "wallet card scan: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
