import BlockerCore
import Foundation
import UniformTypeIdentifiers

/// Serves this shard's compiled rules to WebKit.
///
/// Prefers the App Group container copy (written by the host app / web
/// extension handler on every update); falls back to the pinned build-time
/// snapshot in this bundle (FR-4: blocking works before first update).
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    static let shard: Shard = .annoyances

    func beginRequest(with context: NSExtensionContext) {
        let bundleURL = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        let groupURL = RulesWriter.groupFileURL(shard: Self.shard)
        let url: URL?
        if let groupURL, FileManager.default.fileExists(atPath: groupURL.path) {
            url = groupURL
        } else {
            url = bundleURL
        }
        let item = NSExtensionItem()
        if let url {
            item.attachments = [NSItemProvider(contentsOf: url)!]
        } else {
            // Neutral single rule so the blocker loads with nothing blocked.
            let fallback = Data(
                "[{\"action\":{\"type\":\"ignore-previous-rules\"},\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"domain.com\"]}}]"
                    .utf8
            )
            item.attachments = [NSItemProvider(item: fallback as NSSecureCoding, typeIdentifier: UTType.json.identifier)]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
