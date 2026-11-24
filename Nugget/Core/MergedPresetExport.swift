import Foundation

/// Desktop `main`'s write-only `.gnmpreset` compatibility document.
///
/// GoldenNugget 9.7.10 can share a newer-build preset without adopting preset
/// v3 locally: local storage stays v2 JSON and imports still accept only JSON
/// and the portable `.gnpreset` ZIP.  This writer emits one plain-YAML file
/// with a shared `HEADER`, a v3-style YAML block and a complete legacy v2 JSON
/// block.  The note in the file spells out that v2 alone is enough for an older
/// build.
///
/// The desktop counterpart is `src/controllers/preset_merged_export.py` in
/// commit `f136460`.  As there, no YAML dependency is pulled in: JSON scalar
/// syntax is valid YAML flow syntax, so the two blocks can be rendered with
/// Foundation alone.
enum MergedPresetExport {
    static let format = "GoldenNugget merged preset"
    static let fileExtension = "gnmpreset"
    static let currentVersion = 3
    static let legacyVersion = 2

    static let headerKey = "HEADER"
    static let v3Key = "Preset Version 3 (YAML)"
    static let v2Key = "Preset Version 2 (JSON)"
    static let noteKey = "Note"
    static let note = "Preset version 2 contains all needed."
    static let writerVersionKey = SettingsVersionStamp.writerVersionKey

    /// Keys that belong to the merged envelope, never to either preset block.
    /// `GNUGGET_VERSION` is deliberately absent: desktop keeps a writer stamp
    /// already present in the source inside the v2 block.
    private static let envelopeKeys: Set<String> = [
        headerKey, v3Key, v2Key, noteKey,
    ]

    /// The v3 block is a flat document: `metadata` and `tweaks` are rendered
    /// as its first two lines, not repeated as extra keys.
    private static let v3Keys: Set<String> = envelopeKeys.union([writerVersionKey, "metadata", "tweaks"])

    /// Render an already-serialized v2 preset document.  `writerVersion` is
    /// injectable so offline checks do not depend on a host Info.plist.
    static func document(from data: Data, writerVersion: String? = nil) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dumps(root, writerVersion: writerVersion)
    }

    /// Atomically write a merged export for the share sheet.
    static func write(_ data: Data, to destination: URL, writerVersion: String? = nil) throws {
        guard let text = document(from: data, writerVersion: writerVersion) else {
            throw CommunityError("Invalid preset.")
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func dumps(_ data: [String: Any], writerVersion: String? = nil) -> String {
        let writer = appVersion(data, writerVersion: writerVersion)
        let header = buildHeader(data, includes: "\(currentVersion),\(legacyVersion)", writerVersion: writer)
        let parts = [
            headerText(header),
            "\(v3Key): |-\n\(indented(v3Document(data, writerVersion: writer)))",
            "\(v2Key): |-\n\(indented(v2Document(data)))",
            "\(noteKey): \(note)",
        ]
        return parts.joined(separator: "\n") + "\n"
    }

    /// The shared header, derived from the preset's own device metadata.
    static func buildHeader(_ data: [String: Any], includes: String, writerVersion: String? = nil) -> [String: Any] {
        let meta = data["metadata"] as? [String: Any] ?? [:]
        let model = nonEmpty(meta["device_model"]) ?? "Unknown"
        let ios = nonEmpty(meta["ios_version"]) ?? "Unknown"
        let family = model.hasPrefix("iPad") ? "iPadOS" : "iPhoneOS"
        return [
            "PresetVersion": currentVersion,
            "GNVersion": appVersion(data, writerVersion: writerVersion),
            "Device": model,
            "OSVersion": "\(family) \(ios)",
            "Includes": includes,
        ]
    }

    /// The complete legacy v2 preset, metadata first as the desktop writes it.
    static func v2Document(_ data: [String: Any]) -> String {
        var root = data.filter { !envelopeKeys.contains($0.key) }
        var meta = (root["metadata"] as? [String: Any]) ?? [:]
        meta["version"] = legacyVersion
        root["metadata"] = meta
        return prettyRoot(root, firstKeys: ["metadata", "tweaks"])
    }

    /// A YAML representation of the same preset: one header plus flow-style
    /// `metadata` and `tweaks` values, then any other top-level keys.
    static func v3Document(_ data: [String: Any], writerVersion: String? = nil) -> String {
        let writer = appVersion(data, writerVersion: writerVersion)
        let header = buildHeader(data, includes: "\(currentVersion)", writerVersion: writer)
        var meta = (data["metadata"] as? [String: Any]) ?? [:]
        meta["version"] = currentVersion
        var lines = [
            headerText(header),
            "metadata: \(compactJSON(meta))",
            "tweaks: \(compactJSON(data["tweaks"] ?? [:]))",
        ]
        for key in data.keys.filter({ !v3Keys.contains($0) }).sorted() {
            lines.append("\(key): \(compactJSON(data[key]!))")
        }
        lines.append("\(writerVersionKey): \(scalar(writer))")
        return lines.joined(separator: "\n")
    }

    /// Indent a complete preset by the two spaces a YAML literal block needs.
    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }
            .joined(separator: "\n")
    }

    /// The indented body of one `key: |-` block, with the shared two spaces
    /// removed.  Public so the offline desktop-sync harness can parse it.
    static func literalBlock(_ text: String, key: String) -> String {
        var lines: [String] = []
        var collecting = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !collecting {
                if line.hasPrefix(key + ":") { collecting = true }
                continue
            }
            if line.hasPrefix("  ") {
                lines.append(String(line.dropFirst(2)))
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering

    private static func appVersion(_ data: [String: Any], writerVersion: String?) -> String {
        if let stamped = data[writerVersionKey] as? String, !stamped.isEmpty { return stamped }
        if let passed = writerVersion, !passed.isEmpty { return passed }
        return SettingsVersionStamp.writerVersion
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func headerText(_ header: [String: Any]) -> String {
        var lines = ["\(headerKey):"]
        for key in ["PresetVersion", "GNVersion", "Device", "OSVersion", "Includes"] {
            let value = header[key] ?? ""
            // These four are plain scalars in block context.  GNVersion stays
            // quoted so a version like "9.7" cannot become a YAML float.
            let rendered = ["Device", "OSVersion", "Includes"].contains(key)
                ? String(describing: value)
                : scalar(value)
            lines.append("  \(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    private static func prettyRoot(_ root: [String: Any], firstKeys: [String]) -> String {
        var keys = firstKeys.filter { root[$0] != nil }
        keys += root.keys.filter { !firstKeys.contains($0) }.sorted()
        guard !keys.isEmpty else { return "{}" }
        let body = keys.map { key in
            String(repeating: " ", count: 2) + scalar(key) + ": " + pretty(root[key]!, level: 1)
        }.joined(separator: ",\n")
        return "{\n\(body)\n}"
    }

    private static func pretty(_ value: Any, level: Int) -> String {
        if let object = value as? [String: Any] {
            guard !object.isEmpty else { return "{}" }
            let pad = String(repeating: " ", count: (level + 1) * 2)
            let close = String(repeating: " ", count: level * 2)
            let body = object.keys.sorted().map { key in
                pad + scalar(key) + ": " + pretty(object[key]!, level: level + 1)
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(close)}"
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let pad = String(repeating: " ", count: (level + 1) * 2)
            let close = String(repeating: " ", count: level * 2)
            let body = array.map { pad + pretty($0, level: level + 1) }.joined(separator: ",\n")
            return "[\n\(body)\n\(close)]"
        }
        return scalar(value)
    }

    /// JSON syntax is valid YAML flow style.  `fragmentsAllowed` lets the same
    /// helper render strings, numbers, booleans and null as top-level values.
    private static func scalar(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\(String(describing: value).replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return text
    }

    private static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
