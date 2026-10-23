import ContentBlockerConverter
import Foundation

// S1 spike (PLAN Phase 0): does SafariConverterLib convert EasyList +
// EasyPrivacy + uBO filters within the 150k rules/shard budget and < 30 s?
//
// Usage:
//   swift run [--version autodetect|16.4|26] [--offline] [--dump]
//   --offline  reuse lists/*.txt from a previous run
//   --dump     write combined shard JSON to out/<shard>.json

// MARK: - Default lists (SPEC §2, FR-3)

enum Shard: String, CaseIterable {
    case ads, privacy, annoyances
}

struct ListDef {
    let id: String
    let name: String
    let url: String
    let shard: Shard
    let enabledByDefault: Bool
}

let lists: [ListDef] = [
    ListDef(id: "easylist", name: "EasyList",
            url: "https://easylist.to/easylist/easylist.txt",
            shard: .ads, enabledByDefault: true),
    ListDef(id: "easyprivacy", name: "EasyPrivacy",
            url: "https://easylist.to/easylist/easyprivacy.txt",
            shard: .privacy, enabledByDefault: true),
    ListDef(id: "ubo-filters", name: "uBO filters",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
            shard: .ads, enabledByDefault: true),
    ListDef(id: "ubo-privacy", name: "uBO privacy",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt",
            shard: .privacy, enabledByDefault: true),
    ListDef(id: "ubo-badware", name: "uBO badware",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt",
            shard: .privacy, enabledByDefault: true),
    ListDef(id: "ubo-unbreak", name: "uBO unbreak",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt",
            shard: .ads, enabledByDefault: true),
    ListDef(id: "ubo-quick-fixes", name: "uBO quick-fixes",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
            shard: .ads, enabledByDefault: true),
    ListDef(id: "pgl", name: "Peter Lowe",
            url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=txt&showintro=0&mimetype=plaintext",
            shard: .privacy, enabledByDefault: true),
    ListDef(id: "ubo-annoyances", name: "uBO annoyances",
            url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-others.txt",
            shard: .annoyances, enabledByDefault: false),
]

let budget = 150_000
let timeBudget: Double = 30

// MARK: - CLI

var versionArg = "autodetect"
var offline = false
var dump = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--version":
        guard !args.isEmpty else { exit(2) }
        versionArg = args.removeFirst()
    case "--offline": offline = true
    case "--dump": dump = true
    default:
        FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
        exit(2)
    }
}

let safariVersion: SafariVersion
if versionArg == "autodetect" {
    safariVersion = .autodetect()
} else {
    safariVersion = SafariVersion(Double(versionArg) ?? 26)
}

// MARK: - Helpers

func parseRules(_ raw: Data) -> [String] {
    guard var text = String(data: raw, encoding: .utf8) else { return [] }
    text.makeContiguousUTF8()
    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("!") }
}

struct Row {
    let label: String
    let source: Int
    let advanced: Int
    let safari: Int
    let errors: Int
    let discarded: Int
    let jsonBytes: Int
    let seconds: Double

    var fitsBudget: Bool { safari + discarded < budget }
    var fitsTime: Bool { seconds < timeBudget }
}

@discardableResult
func convert(_ rules: [String], label: String, version: SafariVersion) -> Row {
    let start = Date()
    let result = ContentBlockerConverter().convertArray(
        rules: rules,
        safariVersion: version,
        advancedBlocking: true,
        maxJsonSizeBytes: nil,
        progress: nil
    )
    let secs = Date().timeIntervalSince(start)
    let row = Row(
        label: label,
        source: result.sourceRulesCount,
        advanced: result.advancedRulesCount,
        safari: result.safariRulesCount,
        errors: result.errorsCount,
        discarded: result.discardedSafariRules,
        jsonBytes: result.safariRulesJSON.utf8.count,
        seconds: secs
    )
    print("[convert] \(label): source=\(row.source) safari=\(row.safari) advanced=\(row.advanced) errors=\(row.errors) discarded=\(row.discarded) json=\(row.jsonBytes / 1024)KB \(String(format: "%.2f", secs))s")
    return row
}

// MARK: - Main

let listsDir = URL(fileURLWithPath: "lists")
try? FileManager.default.createDirectory(at: listsDir, withIntermediateDirectories: true)

var raws: [String: Data] = [:]
for list in lists {
    let file = listsDir.appendingPathComponent(list.id + ".txt")
    if offline, FileManager.default.fileExists(atPath: file.path) {
        raws[list.id] = try Data(contentsOf: file)
        print("[download] \(list.id): cached")
    } else {
        let start = Date()
        let (data, response) = try await URLSession.shared.data(from: URL(string: list.url)!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            FileHandle.standardError.write(Data("HTTP \(code) for \(list.url)\n".utf8))
            exit(1)
        }
        try data.write(to: file)
        raws[list.id] = data
        print("[download] \(list.id): \(data.count / 1024)KB in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }
}

let parsed: [String: [String]] = raws.mapValues { parseRules($0) }

// Per-list conversion.
var listRows: [Row] = []
for list in lists {
    guard let rules = parsed[list.id] else { continue }
    listRows.append(convert(rules, label: list.name, version: safariVersion))
}

// Combined conversion per shard (enabled lists only) — the numbers that
// actually matter for the 150k budget.
var shardRows: [(row: Row, members: [String])] = []
for shard in Shard.allCases {
    let memberLists = lists.filter { $0.shard == shard && $0.enabledByDefault }
    var combined: [String] = []
    for m in memberLists { combined.append(contentsOf: parsed[m.id] ?? []) }
    let row = convert(combined, label: shard.rawValue, version: safariVersion)
    shardRows.append((row, memberLists.map(\.name)))
    if dump {
        let outDir = URL(fileURLWithPath: "out")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let start = Date()
        let result = ContentBlockerConverter().convertArray(
            rules: combined,
            safariVersion: safariVersion,
            advancedBlocking: true,
            maxJsonSizeBytes: nil,
            progress: nil
        )
        try Data(result.safariRulesJSON.utf8).write(to: outDir.appendingPathComponent("\(shard.rawValue).json"))
        print("[dump] out/\(shard.rawValue).json in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }
}

// MARK: - Report

var report = """
# S1 — Converter spike report

- Date: \(ISO8601DateFormatter().string(from: Date()))
- Machine: \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores
- SafariConverterLib: 4.3.1, target version: \(safariVersion.debugDescription)
- Budget: < \(budget.formatted()) rules/shard, < \(Int(timeBudget)) s (NFR-3)

## Per-list conversion

| list | shard | source | safari | advanced | errors | discarded | json KB | s |
|---|---|---|---|---|---|---|---|---|
"""
for (i, row) in listRows.enumerated() {
    report += "| \(row.label) | \(lists[i].shard.rawValue) | \(row.source) | \(row.safari) | \(row.advanced) | \(row.errors) | \(row.discarded) | \(row.jsonBytes / 1024) | \(String(format: "%.2f", row.seconds)) |\n"
}

report += """

## Shards (combined, default-enabled lists)

| shard | lists | source | safari | advanced | errors | s | 150k budget | < 30 s |
|---|---|---|---|---|---|---|---|---|
"""
for (row, members) in shardRows {
    report += "| \(row.label) | \(members.joined(separator: ", ")) | \(row.source) | \(row.safari) | \(row.advanced) | \(row.errors) | \(String(format: "%.2f", row.seconds)) | \(row.fitsBudget ? "PASS" : "FAIL") | \(row.fitsTime ? "PASS" : "FAIL") |\n"
}

let budgetFail = shardRows.map(\.row).filter { !$0.fitsBudget }
let timeFail = shardRows.map(\.row).filter { !$0.fitsTime }
report += """

## Verdict

- 150k/shard budget: \(budgetFail.isEmpty ? "PASS — all shards fit" : "FAIL — \(budgetFail.map(\.label).joined(separator: ", "))")
- < 30 s conversion: \(timeFail.isEmpty ? "PASS — all shards under \(Int(timeBudget)) s" : "FAIL — \(timeFail.map(\.label).joined(separator: ", "))")
- Shard layout decision: \(budgetFail.isEmpty ? "keep 4-target layout (ads/privacy/annoyances/user) unchanged" : "rebalance shards or add a target")

"""
print("\nS1 report:\n")
print(report)
try? report.write(to: URL(fileURLWithPath: "report.md"), atomically: true, encoding: .utf8)
