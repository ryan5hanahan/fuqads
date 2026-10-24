@preconcurrency import ContentBlockerConverter
import Foundation

/// Per-list conversion stats surfaced in the list manager (FR-7).
public struct ListStats: Codable, Sendable, Equatable {
    public var sourceRules: Int = 0
    /// Safari rules produced (before sharding budget).
    public var converted: Int = 0
    /// Rules the converter could not express (SPEC §5.2 "unsupported").
    public var unsupported: Int = 0
    /// Advanced rules (scriptlets, extended CSS…) — non-goals in v1,
    /// counted so the UI can show what is intentionally not applied.
    public var advanced: Int = 0
    public var updatedAt: Date?
    public var lastError: String?

    public init() {}
}

/// Per-line check of one user rule for the editor (FR-31).
public struct UserRuleDiagnostic: Sendable, Equatable {
    /// 1-based position in the input array (comments/blanks excluded by
    /// `Store.userRuleLines` before the call).
    public var line: Int
    public var text: String
    public var ok: Bool
    /// Empty when `ok`.
    public var message: String

    public init(line: Int, text: String, ok: Bool, message: String) {
        self.line = line
        self.text = text
        self.ok = ok
        self.message = message
    }
}

/// One compiled shard: ready-to-write blockerList.json + bookkeeping.
public struct CompiledShard: Sendable {
    public let shard: Shard
    /// blockerList.json content (compact JSON array).
    public let json: String
    public let ruleCount: Int
    public let withinBudget: Bool
    /// Lists dropped from this shard by the overflow policy (SPEC §5.2).
    public let droppedLists: [String]
    public let stats: [String: ListStats]
    /// Number of trailing allowlist rules in `json` (for base reconstruction).
    public let allowlistCount: Int

    public init(
        shard: Shard,
        json: String,
        ruleCount: Int,
        withinBudget: Bool,
        droppedLists: [String],
        stats: [String: ListStats],
        allowlistCount: Int
    ) {
        self.shard = shard
        self.json = json
        self.ruleCount = ruleCount
        self.withinBudget = withinBudget
        self.droppedLists = droppedLists
        self.stats = stats
        self.allowlistCount = allowlistCount
    }
}

public struct CompileInput: Sendable {
    /// Enabled lists to compile (built-in + custom), any order.
    public var lists: [ListSpec]
    /// listID -> parsed rule lines.
    public var rules: [String: [String]]
    /// eTLD+1 domains to fully allowlist (FR-11); appended to every shard.
    public var allowlist: [String]
    /// User's freeform ABP rules (FR-30); compiled into the user shard only.
    public var userRules: [String]

    public init(
        lists: [ListSpec],
        rules: [String: [String]],
        allowlist: [String] = [],
        userRules: [String] = []
    ) {
        self.lists = lists
        self.rules = rules
        self.allowlist = allowlist
        self.userRules = userRules
    }
}

/// Converts enabled lists into per-shard blockerList.json payloads.
///
/// Design:
/// - Each list is converted independently (per-list stats, FR-7); the shard
///   payload is the concatenation of the per-list Safari rule arrays in
///   `sortOrder`, followed by the allowlist rules. Exception-heavy lists
///   sort last so their `@@` (ignore-previous-rules) rules sit after the
///   blocks they unblock.
/// - Budget: user rules are always included in full. Lists are then added
///   in priority order; a list that does not fit in the remaining budget is
///   included partially (or not at all) and reported in `droppedLists`.
///   Overflow is surfaced, never hidden (SPEC §5.2); `withinBudget` is
///   false when the final shard is over the limit.
public final class Compiler: Sendable {
    public let safariVersion: SafariVersion
    public let budget: Int

    public init(safariVersion: SafariVersion = .autodetect(), budget: Int = 150_000) {
        self.safariVersion = safariVersion
        self.budget = budget
    }

    public func compile(_ input: CompileInput) -> [Shard: CompiledShard] {
        var stats: [String: ListStats] = [:]
        var perListArrays: [String: [[String: Any]]] = [:]

        for spec in input.lists where spec.enabled {
            let lines = input.rules[spec.id] ?? []
            var s = ListStats()
            s.sourceRules = lines.count
            s.updatedAt = Date()
            if lines.isEmpty {
                stats[spec.id] = s
                continue
            }
            let result = ContentBlockerConverter().convertArray(
                rules: lines,
                safariVersion: safariVersion,
                advancedBlocking: true,
                maxJsonSizeBytes: nil,
                progress: nil
            )
            s.converted = result.safariRulesCount
            s.unsupported = result.errorsCount
            s.advanced = result.advancedRulesCount
            if result.discardedSafariRules > 0 {
                s.lastError = "converter hit rule limit: \(result.discardedSafariRules) dropped"
            }
            stats[spec.id] = s
            perListArrays[spec.id] = Self.parseRules(result.safariRulesJSON)
        }

        var output: [Shard: CompiledShard] = [:]
        for shard in Shard.allCases {
            output[shard] = compileShard(
                shard,
                lists: input.lists.filter { $0.shard == shard && $0.enabled },
                perListArrays: perListArrays,
                allowlist: input.allowlist,
                userRules: shard == .user ? input.userRules : nil,
                stats: stats
            )
        }
        return output
    }

    /// Fast path (SPEC §4.3, PLAN Phase 3.2): compile ONLY the user rules
    /// into the User shard with the allowlist appended. No list fetch or
    /// conversion — the picker/editor path must stay well under a second.
    public func compileUserShard(userRules: [String], allowlist: [String]) -> CompiledShard {
        compileShard(
            .user,
            lists: [],
            perListArrays: [:],
            allowlist: allowlist,
            userRules: userRules.isEmpty ? nil : userRules,
            stats: [:]
        )
    }

    /// Per-line conversion check for the user-rules editor (FR-31): each
    /// line is converted on its own so the UI can report the offending
    /// line number instead of a bulk unsupported count.
    public func userRuleDiagnostics(_ lines: [String]) -> [UserRuleDiagnostic] {
        lines.enumerated().map { index, line in
            let result = ContentBlockerConverter().convertArray(
                rules: [line],
                safariVersion: safariVersion,
                advancedBlocking: true,
                maxJsonSizeBytes: nil,
                progress: nil
            )
            if result.safariRulesCount > 0 {
                return UserRuleDiagnostic(line: index + 1, text: line, ok: true, message: "")
            }
            if result.advancedRulesCount > 0 {
                // Scriptlets / extended CSS: interpreted by the web
                // extension upstream, not applied by v1 (SPEC §3).
                return UserRuleDiagnostic(
                    line: index + 1, text: line, ok: false,
                    message: "advanced rule (scriptlet/extended CSS) — not applied in v1"
                )
            }
            if result.errorsCount > 0 {
                return UserRuleDiagnostic(line: index + 1, text: line, ok: false,
                                           message: "could not be converted")
            }
            return UserRuleDiagnostic(line: index + 1, text: line, ok: false,
                                       message: "produced no rule")
        }
    }

    private func compileShard(
        _ shard: Shard,
        lists: [ListSpec],
        perListArrays: [String: [[String: Any]]],
        allowlist: [String],
        userRules: [String]?,
        stats: [String: ListStats]
    ) -> CompiledShard {
        var stats = stats
        // Most important first; overflow drops from the tail.
        let ordered = lists.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.overflowPriority < rhs.overflowPriority
        }

        var dropped: [String] = []
        var rules: [[String: Any]] = []

        if let userRules, !userRules.isEmpty {
            let result = ContentBlockerConverter().convertArray(
                rules: userRules,
                safariVersion: safariVersion,
                advancedBlocking: true,
                maxJsonSizeBytes: nil,
                progress: nil
            )
            let userArray = Self.parseRules(result.safariRulesJSON)
            var s = stats["user"] ?? ListStats()
            s.sourceRules = userRules.count
            s.converted = result.safariRulesCount
            s.unsupported = result.errorsCount
            s.advanced = result.advancedRulesCount
            s.updatedAt = Date()
            stats["user"] = s
            rules.append(contentsOf: userArray)
        }

        for spec in ordered {
            let array = perListArrays[spec.id] ?? []
            let room = budget - Self.allowlistRuleCount(allowlist) - rules.count
            if room <= 0 {
                dropped.append(spec.id)
            } else if array.count <= room {
                rules.append(contentsOf: array)
            } else {
                // This list alone exceeds the remaining budget: keep what
                // fits so higher-priority coverage is not lost wholesale,
                // and report the loss.
                rules.append(contentsOf: array.prefix(room))
                dropped.append(spec.id)
            }
        }

        // Allowlist rules last: ignore-previous-rules only applies to rules
        // earlier in the file (SPEC §4.1 step 4).
        let allowRules = Self.allowlistRules(allowlist)
        rules.append(contentsOf: allowRules)

        let json = Self.toJson(rules)
        let count = rules.count
        return CompiledShard(
            shard: shard,
            json: json,
            ruleCount: count,
            withinBudget: count <= budget,
            droppedLists: dropped,
            stats: stats,
            allowlistCount: allowRules.count
        )
    }

    // MARK: - helpers

    static func allowlistRuleCount(_ allowlist: [String]) -> Int {
        allowlist.count
    }

    /// `ignore-previous-rules` for every allowlisted eTLD+1, matching the
    /// domain and any subdomain over http/https (with optional port/path).
    static func allowlistRules(_ allowlist: [String]) -> [[String: Any]] {
        allowlist
            .sorted()
            .map { domain in
                let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
                let pattern = "^https?://([a-z0-9-]+\\.)*\(escaped)(:[0-9]+)?(/.*)?$"
                return [
                    "trigger": ["if-top-url": pattern],
                    "action": ["type": "ignore-previous-rules"],
                ] as [String: Any]
            }
    }

    static func parseRules(_ json: String) -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    static func toJson(_ rules: [[String: Any]]) -> String {
        if rules.isEmpty {
            // WebKit needs at least one rule; keep the converter's neutral
            // placeholder.
            return ConversionResult.EMPTY_RESULT_JSON
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
