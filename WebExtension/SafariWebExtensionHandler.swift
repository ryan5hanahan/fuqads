import BlockerCore
import Foundation
import SafariServices

/// Native side of the bl0cksh1t web extension (SPEC §4).
///
/// Messages arrive as JSON from background.js via
/// `browser.runtime.sendNativeMessage`; Safari delivers them through
/// `beginRequest` (pattern proven by spikes/SpikeApp):
///
///   { "type": "updateLists" }   full list update — download, convert,
///     shard, write, reload. Async (~10-30 s); respond immediately.
///
///   { "type": "setSiteState",
///     "site": "example.com",
///     "state": "trusted" | "default" | "strict" | "untrusted",
///     "allowOrigins": ["cdn.example.net"] }
///     Persist per-site policy (FR-10). The policy is written synchronously
///     so it is durable when this reply returns; the trusted state also
///     re-runs the allowlist recompile so the content blockers pick it up
///     (< 5 s, NFR-3) — that part is async.
///
///   { "type": "etldPlusOne", "host": "www.example.co.uk" }
///     eTLD+1 of a hostname via the shared PublicSuffixList dependency;
///     the raw host is returned for unkeyable hosts (IPs, localhost).
///     The popup uses this to key per-site state (FR-10).
///     Responds synchronously.
///   { "type": "saveUserRule", "host": "example.com",
///     "selector": ".ad-box > img" }
///     Element picker save (FR-22): persists `site##selector` (eTLD+1-
///     scoped) in `userRules` if not already present, then recompiles
///     ONLY the User shard (SPEC §4.3, < 1 s). Async; respond immediately.
///   { "type": "getState" }      policy, list info, and update state;
///     respond synchronously.
///
/// Long work runs in detached `Task`s. The handler process may be reaped
/// after the reply (pending spike S3), so every long operation is
/// self-contained and the App Group files + persisted UpdateState make
/// re-entry safe.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let store = Store()
    private static let listStore = ListStore(directory: SafariWebExtensionHandler.groupContainer.appendingPathComponent("lists"))
    private static let engine = UpdateEngine(
        store: store,
        listStore: listStore,
        fromBundleURL: Bundle.main.bundleURL
    )

    /// `<group>/` — the App Group container this appex is entitled to.
    static var groupContainer: URL {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Bundles.appGroup
        ) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    func beginRequest(with context: NSExtensionContext) {
        let message = Self.message(from: context)
        let type = (message?["type"] as? String) ?? "<nil>"

        switch type {
        case "updateLists":
            Task {
                await Self.engine.updateAll()
            }
            Self.respond(context, ["ok": true, "async": true])

        case "setSiteState":
            guard
                let site = message?["site"] as? String,
                let stateRaw = message?["state"] as? String,
                let state = SiteState(rawValue: stateRaw)
            else {
                Self.respond(context, ["ok": false, "error": "bad setSiteState payload"])
                return
            }
            let allowOrigins = (message?["allowOrigins"] as? [String]) ?? []
            // Synchronous: the policy must be durable when the reply
            // returns (the popup then polls for the optional recompile).
            Self.store.setPolicy(SitePolicy(state: state, allowOrigins: allowOrigins), for: site)
            let recompile = state == .trusted
            if recompile {
                Task {
                    await Self.engine.refreshAllowlist()
                }
            }
            Self.respond(context, ["ok": true, "async": recompile])

        case "etldPlusOne":
            let host = (message?["host"] as? String) ?? ""
            Self.respond(context, ["ok": true, "etldPlusOne": eTLDPlusOne(host) ?? host])

        case "saveUserRule":
            guard
                let host = message?["host"] as? String,
                let selector = (message?["selector"] as? String),
                !selector.isEmpty
            else {
                Self.respond(context, ["ok": false, "error": "bad saveUserRule payload"])
                return
            }
            // `site##selector` scoped to the eTLD+1 (SPEC §4.3, FR-22).
            // Synchronous persist; the User-shard recompile is async.
            let site = eTLDPlusOne(host) ?? host
            let rule = site + "##" + selector
            let added = !Self.store.userRuleLines.contains(rule)
            if added {
                let current = Self.store.userRules
                Self.store.userRules = current.isEmpty ? rule : current + "\n" + rule
                Task {
                    await Self.engine.refreshUserRules()
                }
            }
            Self.respond(context, ["ok": true, "added": added, "async": added])

        case "getState":
            Self.respond(context, Self.statePayload())

        default:
            Self.respond(context, ["ok": false, "error": "unknown type \(type)"])
        }
    }

    // MARK: - payload

    private static func statePayload() -> [String: Any] {
        let state = engine.state
        var lists: [[String: Any]] = []
        for (id, info) in store.lists.sorted(by: { $0.key < $1.key }) {
            lists.append([
                "id": id,
                "name": info.name,
                "enabled": info.enabled,
                "shard": info.shard?.rawValue as Any,
                "ruleCount": info.ruleCount,
                "unsupported": info.unsupported,
                "updatedAt": info.updatedAt?.timeIntervalSince1970 as Any,
            ])
        }
        var sites: [[String: Any]] = []
        for (site, policy) in store.sites.sorted(by: { $0.key < $1.key }) {
            sites.append([
                "site": site,
                "state": policy.state.rawValue,
                "allowOrigins": policy.allowOrigins,
            ])
        }
        return [
            "ok": true,
            "globalDefault": store.globalDefault.rawValue,
            "updateIntervalHours": store.updateIntervalHours,
            "updateInProgress": state.inProgress,
            "lastUpdateFinished": state.lastFinished?.timeIntervalSince1970 as Any,
            "lastUpdateError": state.lastError as Any,
            "shardRuleCounts": state.shardRuleCounts,
            "lists": lists,
            "sites": sites,
        ]
    }

    // MARK: - plumbing

    private static func message(from context: NSExtensionContext) -> [String: Any]? {
        let item = context.inputItems.first as? NSExtensionItem
        return item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
            ?? item?.userInfo?["message"] as? [String: Any]
    }

    private static func respond(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
