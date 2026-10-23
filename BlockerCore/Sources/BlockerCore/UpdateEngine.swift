import Foundation

/// Result of one full update run, persisted for the UI (FR-7) and the
/// web extension's popup.
public struct UpdateState: Codable, Sendable, Equatable {
    public var inProgress: Bool = false
    public var lastFinished: Date?
    public var lastError: String?
    /// shard -> rule count of the last written JSON.
    public var shardRuleCounts: [String: Int] = [:]

    public init(
        inProgress: Bool = false,
        lastFinished: Date? = nil,
        lastError: String? = nil,
        shardRuleCounts: [String: Int] = [:]
    ) {
        self.inProgress = inProgress
        self.lastFinished = lastFinished
        self.lastError = lastError
        self.shardRuleCounts = shardRuleCounts
    }
}

/// Orchestrates the static-blocking update pipeline (SPEC §4.1):
/// fetch enabled lists → convert → shard → append allowlist → write → reload.
///
/// Used by both the host app ("Update now") and the web extension's native
/// handler (scheduled updates while the app is closed, FR-5). Both operate
/// on the same App Group files, so they can run without coordination; a
/// stale `inProgress` flag is cleared on start.
public final class UpdateEngine: @unchecked Sendable {
    public let store: Store
    public let listStore: ListStore
    public let compiler: Compiler
    /// Bundle.main.bundleURL of the caller (app bundle or appex bundle).
    public let fromBundleURL: URL

    private let stateFile: URL
    private let lock = NSLock()
    private var _state = UpdateState()

    public var state: UpdateState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public init(
        store: Store,
        listStore: ListStore,
        compiler: Compiler = Compiler(),
        fromBundleURL: URL
    ) {
        self.store = store
        self.listStore = listStore
        self.compiler = compiler
        self.fromBundleURL = fromBundleURL
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Bundles.appGroup
        ) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = container.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateFile = dir.appendingPathComponent("update.json")
        if let data = try? Data(contentsOf: stateFile),
           let saved = try? JSONDecoder().decode(UpdateState.self, from: data),
           let finished = saved.lastFinished {
            // An update that was in progress when the process died.
            _state = UpdateState(
                inProgress: false,
                lastFinished: finished,
                lastError: saved.inProgress ? "interrupted" : saved.lastError,
                shardRuleCounts: saved.shardRuleCounts
            )
        }
    }

    /// Full update: download + convert + write + reload (NFR-3: < 30 s).
    /// With `refetch: false` the cached raw lists are reused (fast path for
    /// list toggles / user-rule edits); a list with no cache is downloaded.
    public func updateAll(refetch: Bool = true) async {
        setInProgress(true, error: nil)
        var shardCounts: [String: Int] = [:]
        do {
            let lists = store.effectiveLists().filter(\.enabled)
            var rules: [String: [String]] = [:]
            var listsInfo = store.lists
            var failures: [String] = []

            for spec in lists {
                let raw: Data
                let fresh: Bool
                if refetch {
                    do {
                        raw = try await listStore.fetch(spec)
                        fresh = true
                    } catch {
                        // Keep blocking with the last known copy (SPEC:
                        // updates must not regress protection), record it.
                        guard let cached = listStore.cachedRaw(spec.id) else {
                            failures.append("\(spec.name): \(error)")
                            continue
                        }
                        raw = cached
                        fresh = false
                    }
                } else if let cached = listStore.cachedRaw(spec.id) {
                    raw = cached
                    fresh = false
                } else if let downloaded = try? await listStore.fetch(spec) {
                    raw = downloaded
                    fresh = true
                } else {
                    failures.append("\(spec.name): no cached copy, download failed")
                    continue
                }
                rules[spec.id] = parseRuleLines(raw)
                if fresh {
                    listsInfo[spec.id]?.updatedAt = Date()
                }
            }

            let allowlist = Self.trustedSites(store: store)
            let compiled = compiler.compile(
                CompileInput(
                    lists: lists,
                    rules: rules,
                    allowlist: allowlist,
                    userRules: store.userRuleLines
                )
            )

            for shard in Shard.allCases {
                guard let result = compiled[shard] else { continue }
                let locations = RulesWriter.write(
                    shard: shard,
                    json: result.json,
                    fromBundleURL: fromBundleURL
                )
                if locations == 0 {
                    throw UpdateEngineError.writeFailed(shard)
                }
                // Cache the converted base (without allowlist) for fast
                // allowlist-only recompiles (SPEC §4.1 step 5).
                let base = Self.baseJsonWithoutAllowlist(result)
                try? base.write(to: Self.baseFileURL(shard: shard), atomically: true, encoding: .utf8)
                shardCounts[shard.rawValue] = result.ruleCount
                for (id, stats) in result.stats where listsInfo[id] != nil {
                    listsInfo[id]?.ruleCount = stats.converted
                    listsInfo[id]?.unsupported = stats.unsupported
                }
                if !result.droppedLists.isEmpty {
                    failures.append("\(shard.rawValue): dropped \(result.droppedLists.joined(separator: ", ")) to fit budget")
                }
            }

            store.lists = listsInfo
            mergeShardCounts(shardCounts)
            Reloader.reload(Shard.allCases, completion: { _ in })
            persistState()
            setInProgress(false, error: failures.isEmpty ? nil : failures.joined(separator: "; "))
        } catch {
            setInProgress(false, error: "\(error)")
        }
    }

    /// Allowlist-only recompile (SPEC §4.1: reuse cached base, redo steps 4-5).
    /// No downloads, no list conversion — comfortably within 5 s (NFR-3).
    public func refreshAllowlist() async {
        setInProgress(true, error: nil)
        let allowlist = Self.trustedSites(store: store)
        var shardCounts: [String: Int] = [:]
        for shard in Shard.allCases {
            let base: String
            if let data = try? Data(contentsOf: Self.baseFileURL(shard: shard)) {
                base = String(decoding: data, as: UTF8.self)
            } else if let bundled = Self.bundledBaseJSON(shard: shard, appBundle: fromBundleURL) {
                base = bundled
            } else {
                continue
            }
            let json = Compiler.appendAllowlist(baseJson: base, allowlist: allowlist)
            let locations = RulesWriter.write(shard: shard, json: json, fromBundleURL: fromBundleURL)
            guard locations > 0 else { continue }
            let count = (json.data(using: .utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
                .map(\.count) ?? 0
            shardCounts[shard.rawValue] = count
        }
        Reloader.reload(Shard.allCases, completion: { _ in })
        mergeShardCounts(shardCounts)
        setInProgress(false, error: nil)
    }

    // MARK: - helpers

    /// Trusted sites (state == .trusted) become allowlist entries (FR-11).
    public static func trustedSites(store: Store) -> [String] {
        store.sites.filter { $0.value.state == .trusted }.map(\.key)
    }

    public static func baseFileURL(shard: Shard) -> URL {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Bundles.appGroup
        ) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = container.appendingPathComponent("blockers-base")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(shard.rawValue).json")
    }

    /// The pinned build-time snapshot (App bundle `bundled-blockers/<Shard>.json`
    /// or the shard appex's `blockerList.json`) — last resort base.
    static func bundledBaseJSON(shard: Shard, appBundle: URL) -> String? {
        if appBundle.pathExtension == "appex" {
            let appex = appBundle.deletingLastPathComponent()
                .appendingPathComponent("\(shard.rawValue.capitalized).appex")
                .appendingPathComponent("blockerList.json")
            return (try? String(contentsOf: appex, encoding: .utf8))
        }
        let bundled = appBundle.appendingPathComponent("bundled-blockers/\(shard.rawValue).json")
        return (try? String(contentsOf: bundled, encoding: .utf8))
    }

    /// Rebuilds the base JSON by stripping the trailing allowlist rules
    /// (exactly `allowlistCount` of them; the compiler appends them last).
    private static func baseJsonWithoutAllowlist(_ compiled: CompiledShard) -> String {
        let rules = Compiler.parseRules(compiled.json)
        let baseCount = max(0, rules.count - compiled.allowlistCount)
        return Compiler.toJson(Array(rules.prefix(baseCount)))
    }

    private func setInProgress(_ inProgress: Bool, error: String?) {
        lock.lock()
        _state.inProgress = inProgress
        if inProgress {
            _state.lastError = nil
        } else {
            _state.lastError = error
            _state.lastFinished = Date()
        }
        lock.unlock()
        persistState()
    }

    private func mergeShardCounts(_ counts: [String: Int]) {
        guard !counts.isEmpty else { return }
        lock.lock()
        _state.shardRuleCounts.merge(counts) { _, new in new }
        lock.unlock()
    }

    private func persistState() {
        let snapshot = state
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: stateFile)
        }
    }

    public enum UpdateEngineError: Error, CustomStringConvertible {
        case writeFailed(Shard)

        public var description: String {
            switch self {
            case let .writeFailed(shard):
                return "could not write rules for shard \(shard.rawValue)"
            }
        }
    }
}
