import Foundation

/// Where compiled rules live and how they reach WebKit.
///
/// Both content-blocker models are supported:
/// - Modern (Safari 26-era templates): WebKit invokes the appex's
///   NSExtensionRequestHandling principal class, which serves the rules file
///   from the App Group container.
/// - Classic (Safari 14-17): WebKit reads `blockerList.json` directly from
///   the appex bundle.
///
/// Therefore every update writes BOTH locations, then reloads.
public enum RulesWriter {
    /// `<group>/blockers/<shard>/blockerList.json`
    public static func groupFileURL(shard: Shard, groupID: String = Bundles.appGroup) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return nil }
        return container
            .appendingPathComponent("blockers")
            .appendingPathComponent(shard.rawValue)
            .appendingPathComponent("blockerList.json")
    }

    /// `<appex bundle>/blockerList.json` for a shard's appex.
    /// - Parameter fromAppexBundle: the caller's Bundle.main.bundleURL —
    ///   the app bundle from the host app, or any appex bundle from inside
    ///   a sibling appex (both resolve to `.../<App>.app/Contents/PlugIns/`).
    public static func appexFileURL(
        shard: Shard,
        fromBundleURL: URL
    ) -> URL {
        // App bundle: .../App.app -> Contents/PlugIns/<Shard>.appex
        // Appex bundle: .../PlugIns/We.appex -> .../PlugIns/<Shard>.appex
        let plugins: URL
        if fromBundleURL.pathExtension == "appex" {
            plugins = fromBundleURL.deletingLastPathComponent()
        } else {
            plugins = fromBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("PlugIns")
        }
        return plugins
            .appendingPathComponent("\(shard.rawValue.capitalized).appex")
            .appendingPathComponent("blockerList.json")
    }

    /// Writes the compiled JSON to the App Group container and (best effort)
    /// the shard's appex bundle. Returns the count of locations written.
    @discardableResult
    public static func write(
        shard: Shard,
        json: String,
        fromBundleURL: URL,
        groupID: String = Bundles.appGroup
    ) -> Int {
        var written = 0
        if let groupURL = groupFileURL(shard: shard, groupID: groupID) {
            try? FileManager.default.createDirectory(
                at: groupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if (try? json.data(using: .utf8)?.write(to: groupURL, options: .atomic)) != nil {
                written += 1
            }
        }
        let appexURL = appexFileURL(shard: shard, fromBundleURL: fromBundleURL)
        if let data = json.data(using: .utf8),
           FileManager.default.fileExists(atPath: appexURL.deletingLastPathComponent().path) {
            // Rewriting the appex bundle is only possible when we have write
            // access (Developer ID / local dev); skip quietly otherwise.
            if (try? data.write(to: appexURL, options: .atomic)) != nil {
                written += 1
            }
        }
        return written
    }
}

public extension Compiler {
    /// Allowlist-only recompile (SPEC §4.1: reuse the cached converted base,
    /// only redo the allowlist append + reload). No list conversion happens
    /// here, so this stays well under the 5 s budget (NFR-3).
    static func appendAllowlist(baseJson: String, allowlist: [String]) -> String {
        guard !allowlist.isEmpty else { return baseJson }
        var rules = parseRules(baseJson)
        // The converter's neutral placeholder is not a real rule to ignore
        // over; keep it but never let it count as content.
        rules.append(contentsOf: allowlistRules(allowlist))
        return toJson(rules)
    }
}
