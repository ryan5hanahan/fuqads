import Foundation

/// Content-blocker shard targets. Each compiles to one appex with its own
/// blockerList.json (≤150k rules, NFR-2).
public enum Shard: String, CaseIterable, Codable, Sendable, Identifiable {
    case ads
    case privacy
    case annoyances
    case user

    public var id: String { rawValue }

    /// App-ex bundle identifier (xcodegen project must match).
    public var bundleID: String {
        Bundles.contentBlocker(self)
    }
}

/// Central place for bundle identifiers / App Group id.
public enum Bundles {
    public static let appPrefix = "dev.bl0cksh1t"
    public static let appGroup = "group.dev.bl0cksh1t"

    public static var app: String { appPrefix }
    public static var webExtension: String { appPrefix + ".WebExtension" }

    public static func contentBlocker(_ shard: Shard) -> String {
        appPrefix + "." + shard.rawValue.capitalized
    }
}

/// A filter list (built-in or user-added URL).
public struct ListSpec: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    /// Shard this list compiles into.
    public var shard: Shard
    public var enabled: Bool
    /// Drop order when a shard overflows the 150k budget (SPEC §5.2):
    /// higher value is dropped first. Lower = more essential.
    public var overflowPriority: Int
    /// Intra-shard compile order: index within the shard. Exception-heavy
    /// lists (unbreak/quick-fixes) sort LAST so their @@ rules sit after the
    /// blocks they unblock (Safari's positional ignore-previous-rules).
    public var sortOrder: Int

    public init(
        id: String,
        name: String,
        url: String,
        shard: Shard,
        enabled: Bool,
        overflowPriority: Int = 0,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.shard = shard
        self.enabled = enabled
        self.overflowPriority = overflowPriority
        self.sortOrder = sortOrder
    }
}

/// Default list set (FR-3). URLs are the canonical upstream mirrors.
public enum BuiltInLists {
    public static let all: [ListSpec] = [
        // ads shard
        ListSpec(id: "easylist", name: "EasyList",
                 url: "https://easylist.to/easylist/easylist.txt",
                 shard: .ads, enabled: true, overflowPriority: 0, sortOrder: 0),
        ListSpec(id: "ubo-filters", name: "uBO filters",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
                 shard: .ads, enabled: true, overflowPriority: 0, sortOrder: 1),
        ListSpec(id: "ubo-unbreak", name: "uBO unbreak",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt",
                 shard: .ads, enabled: true, overflowPriority: 1, sortOrder: 2),
        ListSpec(id: "ubo-quick-fixes", name: "uBO quick-fixes",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
                 shard: .ads, enabled: true, overflowPriority: 1, sortOrder: 3),
        // privacy shard
        ListSpec(id: "easyprivacy", name: "EasyPrivacy",
                 url: "https://easylist.to/easylist/easyprivacy.txt",
                 shard: .privacy, enabled: true, overflowPriority: 0, sortOrder: 0),
        ListSpec(id: "ubo-privacy", name: "uBO privacy",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt",
                 shard: .privacy, enabled: true, overflowPriority: 0, sortOrder: 1),
        ListSpec(id: "pgl", name: "Peter Lowe's list",
                 url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=txt&showintro=0&mimetype=plaintext",
                 shard: .privacy, enabled: true, overflowPriority: 1, sortOrder: 2),
        ListSpec(id: "ubo-badware", name: "uBO badware",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt",
                 shard: .privacy, enabled: true, overflowPriority: 2, sortOrder: 3),
        // annoyances shard (off by default, FR-3)
        ListSpec(id: "ubo-annoyances", name: "uBO annoyances",
                 url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-others.txt",
                 shard: .annoyances, enabled: false, overflowPriority: 0, sortOrder: 0),
    ]

    public static func spec(id: String) -> ListSpec? {
        all.first { $0.id == id }
    }
}
