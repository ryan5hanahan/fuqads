import Foundation

/// Per-list metadata persisted in the App Group (SPEC §6 `lists`).
public struct ListInfo: Codable, Sendable, Equatable {
    /// Dictionary key in SPEC §6 `lists`; backfilled by `Store.lists`.
    public var id: String = ""
    public var name: String
    public var url: String
    public var enabled: Bool
    public var updatedAt: Date?
    public var ruleCount: Int
    public var unsupported: Int
    /// Built-in lists keep their spec; custom lists carry their shard here.
    public var shard: Shard?

    public init(
        id: String = "",
        name: String,
        url: String,
        enabled: Bool,
        updatedAt: Date? = nil,
        ruleCount: Int = 0,
        unsupported: Int = 0,
        shard: Shard? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.ruleCount = ruleCount
        self.unsupported = unsupported
        self.shard = shard
    }
}

/// Persistent settings in the App Group UserDefaults (SPEC §6).
///
/// All state the app, the web extension's native handler, and the content
/// blockers share lives here: `globalDefault`, `sites`, `lists`,
/// `userRules`, `updateIntervalHours`.
/// `@unchecked`: no stored mutable state of its own — all reads/writes go
/// through the thread-safe `UserDefaults`.
public final class Store: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let globalDefault = "globalDefault"
        static let sites = "sites"
        static let lists = "lists"
        static let userRules = "userRules"
        static let updateIntervalHours = "updateIntervalHours"
    }

    public init(appGroup: String = Bundles.appGroup) {
        self.defaults = UserDefaults(suiteName: appGroup)
            ?? UserDefaults.standard
    }

    // MARK: global

    public var globalDefault: GlobalDefaultState {
        get {
            GlobalDefaultState(rawValue: defaults.string(forKey: Key.globalDefault) ?? "") ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.globalDefault) }
    }

    /// eTLD+1 -> policy (SPEC §6 `sites`).
    public var sites: [String: SitePolicy] {
        get { Self.decode(defaults.data(forKey: Key.sites)) ?? [:] }
        set { defaults.set(Self.encode(newValue), forKey: Key.sites) }
    }

    public func policy(for site: String) -> SitePolicy {
        sites[site] ?? SitePolicy(state: SiteState(rawValue: globalDefault.rawValue) ?? .default)
    }

    public func setPolicy(_ policy: SitePolicy, for site: String) {
        var all = sites
        // A policy identical to the global default carries no information —
        // remove the key so the store stays small.
        let isGlobalDefault = policy.allowOrigins.isEmpty
            && policy.state == SiteState(rawValue: globalDefault.rawValue)
        if isGlobalDefault {
            all[site] = nil
        } else {
            all[site] = policy
        }
        sites = all
    }

    // MARK: lists

    /// listID -> info. Built-in lists get a default entry on first access.
    public var lists: [String: ListInfo] {
        get {
            var stored: [String: ListInfo] = Self.decode(defaults.data(forKey: Key.lists)) ?? [:]
            for spec in BuiltInLists.all where stored[spec.id] == nil {
                stored[spec.id] = ListInfo(
                    id: spec.id,
                    name: spec.name,
                    url: spec.url,
                    enabled: spec.enabled,
                    shard: spec.shard
                )
            }
            for key in stored.keys { stored[key]?.id = key }
            return stored
        }
        set { defaults.set(Self.encode(newValue), forKey: Key.lists) }
    }

    public func setEnabled(_ enabled: Bool, for listID: String) {
        var all = lists
        all[listID]?.enabled = enabled
        lists = all
    }

    /// Resolves the effective list set: built-ins from specs + custom lists
    /// from storage (FR-6).
    public func effectiveLists() -> [ListSpec] {
        var result: [ListSpec] = []
        let stored = lists
        for spec in BuiltInLists.all {
            var s = spec
            s.enabled = stored[spec.id]?.enabled ?? spec.enabled
            result.append(s)
        }
        for (id, info) in stored where BuiltInLists.spec(id: id) == nil {
            result.append(
                ListSpec(
                    id: id,
                    name: info.name,
                    url: info.url,
                    shard: info.shard ?? .privacy,
                    enabled: info.enabled,
                    overflowPriority: 3,
                    sortOrder: 9
                )
            )
        }
        return result
    }

    // MARK: user rules

    /// Freeform ABP rules, newline-separated (SPEC §6 `userRules`).
    public var userRules: String {
        get { defaults.string(forKey: Key.userRules) ?? "" }
        set { defaults.set(newValue, forKey: Key.userRules) }
    }

    public var userRuleLines: [String] {
        userRules
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
    }

    // MARK: schedule

    public var updateIntervalHours: Double {
        get {
            let v = defaults.double(forKey: Key.updateIntervalHours)
            return v > 0 ? v : 24
        }
        set { defaults.set(newValue, forKey: Key.updateIntervalHours) }
    }

    // MARK: compiled-rule cache metadata

    /// SHA-free freshness marker: listID -> raw text byte count of the last
    /// successful compile input. Lets the app skip re-downloading when the
    /// schedule fires but nothing changed is NOT the goal; this records what
    /// the bundled/compiled JSON was built from (shown in the UI).
    public var compiledFrom: [String: Int] {
        get { Self.decode(defaults.data(forKey: "compiledFrom")) ?? [:] }
        set { defaults.set(Self.encode(newValue), forKey: "compiledFrom") }
    }

    // MARK: coding helpers

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
