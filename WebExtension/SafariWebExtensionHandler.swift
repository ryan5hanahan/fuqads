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
///     Persist per-site policy (FR-10). The trusted state also re-runs the
///     allowlist recompile so the content blockers pick it up (< 5 s,
///     NFR-3); async; respond immediately.
///
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
            let recompile = state == .trusted
            Task {
                Self.store.setPolicy(SitePolicy(state: state, allowOrigins: allowOrigins), for: site)
                if recompile {
                    await Self.engine.refreshAllowlist()
                }
            }
            Self.respond(context, ["ok": true, "async": recompile])

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
