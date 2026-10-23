import Foundation
import SafariServices

/// Native handler for the spike web extension.
///
/// Messages (from background.js via browser.runtime.sendNativeMessage):
///   { type: "log",   file: "s2.jsonl" | "s5.jsonl", entry: {...} }
///   { type: "s3probe", size: "150k" | "trivial" }  -> rewrite CB JSON + reload,
///     measures and appends to <group>/s3.jsonl (async; responds immediately)
///
/// Logs live in the App Group container (~/Library/Group Containers/
/// group.dev.bl0cksh1t/).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let groupID = "group.dev.bl0cksh1t"
    static let cbIdentifier = "dev.bl0cksh1t.spike.cb"
    private static let queue = DispatchQueue(label: "spike.handler.io")
    /// Ad-hoc spike: no app-group entitlement, use the fixed container path.
    static var groupDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = (request?.userInfo?[SFExtensionMessageKey] as? [String: Any])
            ?? (request?.userInfo?["message"] as? [String: Any])
        let type = (message?["type"] as? String) ?? "<nil>"

        switch type {
        case "log":
            let file = (message?["file"] as? String) ?? "s2.jsonl"
            Self.appendJSONL(file: file, entry: message ?? [:])
            Self.respond(context, ["ok": true])
        case "s3probe":
            let size = (message?["size"] as? String) ?? "150k"
            Self.queue.async { Self.s3Probe(size: size) }
            Self.respond(context, ["ok": true, "async": true])
        default:
            Self.respond(context, ["ok": false, "error": "unknown type \(type)"])
        }
    }

    private static func respond(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    /// S3 core test: the *web extension's native handler process* (not the app)
    /// rewrites the content blocker's blockerList.json and reloads it.
    private static func s3Probe(size: String) {
        var entry: [String: Any]
        do {
            // We run inside SpikeWE.appex; the app bundle is two levels up.
            let appexBundle = Bundle.main.bundleURL
            let appBundle = appexBundle
                .deletingLastPathComponent()   // .../PlugIns
                .deletingLastPathComponent()   // .../Spike.app
            let cbAppex = appBundle
                .appendingPathComponent("Contents/PlugIns/SpikeCB.appex")
            let dst = cbAppex.appendingPathComponent("blockerList.json")

            let fileBase = size == "150k" ? "s3-150k" : "s3-trivial"
            let src = appBundle
                .appendingPathComponent("Contents/Resources/spike-data/\(fileBase).json")
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw NSError(domain: "spike", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "missing \(src.path)"])
            }

            let t0 = Date()
            try FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            let rewriteMs = Date().timeIntervalSince(t0) * 1000

            let t1 = Date()
            let semaphore = DispatchSemaphore(value: 0)
            var reloadError: String?
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: cbIdentifier) { error in
                reloadError = error.map { "\($0)" }
                semaphore.signal()
            }
            let waited = semaphore.wait(timeout: .now() + 120) == .success
            let reloadMs = Date().timeIntervalSince(t1) * 1000

            entry = [
                "ok": reloadError == nil,
                "via": "handler",
                "size": size,
                "rewriteMs": (rewriteMs * 100).rounded() / 100,
                "reloadMs": (reloadMs * 100).rounded() / 100,
                "reloadTimedOut": !waited,
                "reloadError": reloadError as Any,
            ]
        } catch {
            entry = ["ok": false, "via": "handler", "size": size, "error": "\(error)"]
        }
        entry["ts"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = "s3probe"
        Self.appendJSONL(file: "s3.jsonl", entry: entry)
    }

    static func appendJSONL(file: String, entry: [String: Any]) {
        let path = groupDir.appendingPathComponent(file).path
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: []) else { return }
        queue.async {
            let line = data + Data([0x0A])
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
