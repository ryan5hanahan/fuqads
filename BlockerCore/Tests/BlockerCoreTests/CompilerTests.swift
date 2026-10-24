import XCTest
@testable import BlockerCore

/// Fixture list (PLAN Phase 1 step 7): one network rule, one cosmetic rule,
/// one exception — enough to exercise conversion, sharding, and allowlist.
let fixtureLines = [
    "||ads.example^$third-party",
    "##.banner",
    "@@||keep.example^",
]

final class CompilerTests: XCTestCase {
    func input(lists: [ListSpec], rules: [String: [String]], allowlist: [String] = []) -> CompileInput {
        CompileInput(lists: lists, rules: rules, allowlist: allowlist)
    }

    private func parsedRules(_ shard: CompiledShard) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(shard.json.utf8))) as? [[String: Any]] ?? []
    }

    // MARK: basic compilation

    func testFixtureCompilesIntoCorrectShard() {
        let spec = ListSpec(id: "fixture", name: "Fixture", url: "https://example.com/f.txt",
                            shard: .ads, enabled: true)
        let out = Compiler().compile(input(lists: [spec], rules: ["fixture": fixtureLines]))
        let ads = out[.ads]!
        let rules = parsedRules(ads)

        XCTAssert(ads.withinBudget)
        XCTAssertFalse(rules.isEmpty)
        // Cosmetic rule survived conversion.
        XCTAssertTrue(rules.contains {
            (($0["action"] as? [String: Any])?["type"] as? String) == "css-display-none"
        })
        // Cosmetic rules never leak into other shards — they hold only the
        // neutral placeholder.
        for other in [Shard.privacy, .annoyances, .user] {
            XCTAssertEqual(parsedRules(out[other]!).count, 1, "\(other) must hold only the placeholder")
        }
    }

    func testEmptyShardGetsNeutralPlaceholder() {
        let out = Compiler().compile(input(lists: [], rules: [:]))
        for shard in Shard.allCases {
            let rules = parsedRules(out[shard]!)
            XCTAssertEqual(rules.count, 1, "\([shard]) should hold the single neutral rule")
            XCTAssertEqual((rules[0]["action"] as? [String: Any])?["type"] as? String,
                           "ignore-previous-rules")
        }
    }

    // MARK: allowlist

    func testAllowlistAppendedLastToEveryShard() {
        let spec = ListSpec(id: "fixture", name: "Fixture", url: "https://example.com/f.txt",
                            shard: .ads, enabled: true)
        let out = Compiler().compile(
            input(lists: [spec], rules: ["fixture": fixtureLines], allowlist: ["trusted.com"])
        )
        let rules = parsedRules(out[.ads]!)
        XCTAssertGreaterThanOrEqual(rules.count, 1)
        let last = rules.last!
        XCTAssertEqual((last["action"] as? [String: Any])?["type"] as? String,
                       "ignore-previous-rules")
        let pattern = (last["trigger"] as? [String: Any])?["if-top-url"] as? String ?? ""
        XCTAssertTrue(pattern.contains("trusted\\.com"), pattern)
        // The pattern must NOT allowlist nottrusted.com.
        XCTAssertFalse(matches(pattern, "https://nottrusted.com/x"))
        // And it must allowlist the bare domain, a subdomain, a port, and a path.
        for url in [
            "https://trusted.com",
            "https://trusted.com/path?q=1",
            "https://a.b.trusted.com:8443/deep",
            "http://trusted.com",
        ] {
            XCTAssertTrue(matches(pattern, url), url)
        }
    }

    // MARK: overflow policy (SPEC §5.2)

    func testOverflowDropsLowestPriorityListsFirst() throws {
        let important = ListSpec(id: "important", name: "Important", url: "https://e.com/a",
                                 shard: .privacy, enabled: true, overflowPriority: 0, sortOrder: 0)
        let disposable = ListSpec(id: "disposable", name: "Disposable", url: "https://e.com/b",
                                  shard: .privacy, enabled: true, overflowPriority: 5, sortOrder: 1)
        // A list that converts to more rules than the budget.
        let bigRules = (1...30).map { "||host\($0).example^" }
        let out = Compiler(budget: 10).compile(
            input(lists: [important, disposable],
                  rules: ["important": bigRules, "disposable": ["||one.example^"]])
        )
        let shard = out[.privacy]!
        XCTAssertLessThanOrEqual(shard.ruleCount, 10)
        XCTAssertFalse(shard.withinBudget == false && shard.droppedLists.isEmpty)
        // The high-priority list's rules are present.
        let rules = parsedRules(shard)
        XCTAssertTrue(rules.contains {
            ((($0["trigger"] as? [String: Any])?["url-filter"] as? String) ?? "").contains("host")
        })
        // The disposable list was dropped (or fully excluded), never silently
        // mixed in when the budget is tight.
        let disposablePresent = rules.contains {
            ((($0["trigger"] as? [String: Any])?["url-filter"] as? String) ?? "").contains("one.example")
        }
        if disposablePresent {
            XCTAssertFalse(shard.droppedLists.contains("disposable"))
        } else {
            XCTAssertTrue(shard.droppedLists.contains("disposable"))
        }
    }

    func testUserRulesNeverSilentlyDropped() {
        // Network rules are not merged by the converter (one Safari rule
        // each), so the budget pressure is real.
        let userRules = (1...30).map { "||user\($0).example^" }
        let out = Compiler(budget: 10).compile(
            CompileInput(lists: [], rules: [:], userRules: userRules)
        )
        let shard = out[.user]!
        XCTAssertFalse(shard.withinBudget, "30 user rules must exceed the 10-rule budget and be reported")
        let rules = parsedRules(shard)
        // All user rules are still in the JSON — overflow is surfaced, not hidden.
        XCTAssertTrue(rules.count >= 30, "got \(rules.count)")
        XCTAssertTrue(shard.droppedLists.isEmpty)
    }

    // MARK: user-shard fast path + diagnostics (Phase 3)

    func testCompileUserShardIsUserRulesPlusAllowlist() {
        let shard = Compiler().compileUserShard(
            userRules: ["example.com##.ad-box", "||tracker.example^"],
            allowlist: ["trusted.com"]
        )
        XCTAssertEqual(shard.shard, .user)
        let rules = parsedRules(shard)
        // 1 ignore-previous-rules per allowlisted site, appended last.
        XCTAssertEqual(rules.count, 3)
        let last = rules.last!
        XCTAssertEqual((last["action"] as? [String: Any])?["type"] as? String,
                       "ignore-previous-rules")
        XCTAssertTrue(rules.contains {
            (($0["action"] as? [String: Any])?["type"] as? String) == "css-display-none"
        })
    }

    func testCompileUserShardEmptyYieldsPlaceholder() {
        let shard = Compiler().compileUserShard(userRules: [], allowlist: [])
        let rules = parsedRules(shard)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual((rules[0]["action"] as? [String: Any])?["type"] as? String,
                       "ignore-previous-rules")
    }

    func testUserRuleDiagnosticsReportsPerLine() {
        let lines = [
            "example.com##.ad-box",       // ok: css-display-none
            "||tracker.example^",          // ok: network block
            "##+js(abort-current)",        // advanced — not applied in v1
            "##",                          // unconvertible (empty selector)
        ]
        let diags = Compiler().userRuleDiagnostics(lines)
        XCTAssertEqual(diags.count, 4)
        XCTAssertEqual(diags.map(\.line), [1, 2, 3, 4])
        XCTAssertTrue(diags[0].ok)
        XCTAssertTrue(diags[1].ok)
        XCTAssertFalse(diags[2].ok)
        XCTAssertTrue(diags[2].message.contains("advanced"), diags[2].message)
        XCTAssertFalse(diags[3].ok)
        XCTAssertFalse(diags[3].message.contains("advanced"), diags[3].message)
        XCTAssertTrue(diags[0].message.isEmpty)
    }

    // MARK: helpers

    func testParseRuleLinesDropsCommentsAndBlanks() {
        let raw = """
        ! title comment
        # hash comment
        ||a.example^

        ##.x
        """.data(using: .utf8)!
        XCTAssertEqual(parseRuleLines(raw), ["||a.example^", "##.x"])
    }

    func testETLDPlusOne() {
        XCTAssertEqual(eTLDPlusOne("www.example.com"), "example.com")
        XCTAssertEqual(eTLDPlusOne("sub.domain.example.co.uk"), "example.co.uk")
        XCTAssertNil(eTLDPlusOne("192.168.1.1"))
        XCTAssertNil(eTLDPlusOne("localhost"))
        XCTAssertEqual(eTLDPlusOne("EXAMPLE.com"), "example.com")
    }

    func testStoreRoundTripsPolicyAndLists() {
        // Fresh suite name so tests are isolated.
        let suite = "bl0cksh1t.tests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let store = Store(appGroup: suite)

        store.globalDefault = .strict
        store.setPolicy(SitePolicy(state: .trusted), for: "trusted.com")
        store.setPolicy(SitePolicy(state: .strict, allowOrigins: ["cdn.example.net"]), for: "example.com")
        store.userRules = "||a.example^\n##.box"
        store.updateIntervalHours = 6

        let reloaded = Store(appGroup: suite)
        XCTAssertEqual(reloaded.globalDefault, .strict)
        XCTAssertEqual(reloaded.sites["trusted.com"]?.state, .trusted)
        XCTAssertEqual(reloaded.sites["example.com"]?.allowOrigins, ["cdn.example.net"])
        XCTAssertEqual(reloaded.policy(for: "other.org").state, .strict)
        XCTAssertEqual(reloaded.userRuleLines, ["||a.example^", "##.box"])
        XCTAssertEqual(reloaded.updateIntervalHours, 6)

        // Disabling a site policy that equals the global default removes the
        // key entirely (keeps the store small).
        store.globalDefault = .strict
        store.setPolicy(SitePolicy(state: .strict), for: "example.com")
        XCTAssertNil(store.sites["example.com"])

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

extension NSRegularExpression {
    convenience init(regex: String) throws {
        try self.init(pattern: regex)
    }
}

func matches(_ pattern: String, _ string: String) -> Bool {
    guard let re = try? NSRegularExpression(regex: pattern) else { return false }
    let range = NSRange(location: 0, length: (string as NSString).length)
    return re.firstMatch(in: string, options: [], range: range) != nil
}
