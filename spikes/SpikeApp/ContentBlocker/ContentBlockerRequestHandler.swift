import Foundation
import UniformTypeIdentifiers
/// Serves the current rules JSON to WebKit (Xcode 27 template pattern).
/// The file is rewritten at runtime by the spike app / web extension
/// handler, then SFContentBlockerManager.reloadContentBlocker fetches it.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let url = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            // Keep WebKit happy with the template rule set.
            let fallback = Data(
                """
                [{"action":{"type":"block"},"trigger":{"url-filter":"webkit.svg"}}]
                """
                .utf8
            )
            let item = NSExtensionItem()
            item.attachments = [NSItemProvider(item: fallback as NSSecureCoding, typeIdentifier: UTType.json.identifier)]
            context.completeRequest(returningItems: [item], completionHandler: nil)
            return
        }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(contentsOf: url)!]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
