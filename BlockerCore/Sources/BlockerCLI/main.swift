import BlockerCore
import Foundation

// blocker-cli — build-time helper for FR-4 (bundled pre-converted rules).
//
// Subcommands:
//   blocker-cli snapshot [--dir DIR]
//       Download every built-in list into DIR (default: lists-snapshots).
//       The snapshot files are pinned inputs: commit them so builds are
//       reproducible offline.
//
//   blocker-cli bundle [--snapshots DIR] [--out AppRoot]
//       Compile the factory-enabled built-in lists from DIR into
//       <AppRoot>/App/bundled-blockers/<shard>.json (host app resource) and
//       <AppRoot>/Blockers/<Shard>/blockerList.json (per-appex fallback).
//
// Exit code 0 on success; prints per-list + per-shard stats.

struct Args {
    var subcommand: String = ""
    var snapshotsDir: String = "lists-snapshots"
    var outDir: String = "."
    /// update: reuse cached raw lists when possible (no downloads).
    var cached: Bool = false
}

var args = Args()
var pending: String?
for arg in CommandLine.arguments.dropFirst() {
    switch (pending, arg) {
    case ("--dir", let v): args.snapshotsDir = v; pending = nil
    case ("--snapshots", let v): args.snapshotsDir = v; pending = nil
    case ("--out", let v): args.outDir = v; pending = nil
    case (let p?, _):
        if p.hasPrefix("--") { pending = p } else if args.subcommand.isEmpty { args.subcommand = p }
    default:
        if arg == "--cached" {
            args.cached = true
        } else if arg.hasPrefix("--") {
            pending = arg
        } else if args.subcommand.isEmpty {
            args.subcommand = arg
        }
    }
}

guard !args.subcommand.isEmpty else {
    FileHandle.standardError.write(Data("usage: blocker-cli snapshot | bundle [--snapshots DIR] [--out DIR] | update [--cached]\n".utf8))
    exit(2)
}

let repoRoot = URL(fileURLWithPath: args.outDir)
let snapshots = repoRoot.appendingPathComponent(args.snapshotsDir)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printStats(_ stats: [String: ListStats]) {
    for (id, s) in stats.sorted(by: { $0.key < $1.key }) {
        let dropped = s.converted < s.sourceRules - s.unsupported - s.advanced
        FileHandle.standardError.write(Data(String(
            format: "  %-16@ source %6d  converted %6d  advanced %6d  unsupported %5d%@%@\n",
            id as NSString, s.sourceRules, s.converted, s.advanced, s.unsupported,
            dropped ? "  (truncated)" : "", "\n"
        ).utf8))
    }
}

switch args.subcommand {
case "snapshot":
    do {
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        var failures: [String] = []
        try await withThrowingTaskGroup(of: String?.self) { group in
            for spec in BuiltInLists.all {
                group.addTask {
                    do {
                        var request = URLRequest(url: URL(string: spec.url)!)
                        request.timeoutInterval = 120
                        request.setValue("bl0cksh1t (filter list snapshot)", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        guard (200..<300).contains(code), !data.isEmpty else {
                            throw NSError(domain: "snapshot", code: code,
                                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) for \(spec.url)"])
                        }
                        try data.write(to: snapshots.appendingPathComponent("\(spec.id).txt"), options: .atomic)
                        FileHandle.standardError.write(Data("  \(spec.id): \(data.count / 1024) KB\n".utf8))
                        return nil
                    } catch {
                        return "\(spec.id): \(error)"
                    }
                }
            }
            for try await failure in group {
                if let failure { failures.append(failure) }
            }
        }
        if !failures.isEmpty { fail(failures.joined(separator: "\n")) }
        print("snapshots written to \(snapshots.path)")
    } catch {
        fail("\(error)")
    }

case "bundle":
    var missing: [String] = []
    var rules: [String: [String]] = [:]
    for spec in BuiltInLists.all {
        let file = snapshots.appendingPathComponent("\(spec.id).txt")
        if let data = try? Data(contentsOf: file) {
            rules[spec.id] = parseRuleLines(data)
        } else {
            missing.append(spec.id)
        }
    }
    if !missing.isEmpty {
        fail("missing snapshots: \(missing.joined(separator: ", ")); run 'blocker-cli snapshot' first")
    }

    let compiled = Compiler().compile(CompileInput(
        lists: BuiltInLists.all,
        rules: rules,
        allowlist: [],
        userRules: []
    ))

    var overBudget: [String] = []
    for shard in Shard.allCases {
        guard let result = compiled[shard] else { continue }
        printStats(result.stats.filter { id, _ in
            BuiltInLists.spec(id: id).map { $0.shard == shard } ?? false
        })
        if !result.withinBudget { overBudget.append(shard.rawValue) }

        let appDir = repoRoot.appendingPathComponent("App/bundled-blockers")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let appFile = appDir.appendingPathComponent("\(shard.rawValue).json")
        do {
            try result.json.write(to: appFile, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write \(appFile.path): \(error)")
        }
        let appexFile = repoRoot
            .appendingPathComponent("Blockers/\(shard.rawValue.capitalized)")
            .appendingPathComponent("blockerList.json")
        do {
            try result.json.write(to: appexFile, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write \(appexFile.path): \(error)")
        }
        FileHandle.standardError.write(Data(String(
            format: "  [%@] %d rules -> %@, %@\n",
            shard.rawValue, result.ruleCount, appFile.lastPathComponent, appexFile.lastPathComponent
        ).utf8))
    }
    if !overBudget.isEmpty {
        fail("shards over budget: \(overBudget.joined(separator: ", "))")
    }
    print("bundled pre-converted rules for \(Shard.allCases.map(\.rawValue).joined(separator: ", "))")

case "update":
    // Headless run of the full update pipeline (SPEC §4.1): fetch ->
    // convert -> shard -> allowlist -> write -> reload. Operates on the
    // same App Group files as the app and the web extension handler;
    // used for automation and pipeline validation without the GUI.
    let store = Store()
    let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Bundles.appGroup
    ) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let listStore = ListStore(directory: container.appendingPathComponent("lists"))
    let engine = UpdateEngine(
        store: store,
        listStore: listStore,
        fromBundleURL: Bundle.main.bundleURL
    )
    let started = Date()
    await engine.updateAll(refetch: !args.cached)
    let elapsed = Date().timeIntervalSince(started)
    let state = engine.state
    print(String(format: "update finished in %.1f s", elapsed))
    for (shard, count) in state.shardRuleCounts.sorted(by: { $0.key < $1.key }) {
        print("  shard \(shard): \(count) rules")
    }
    if let error = state.lastError {
        print("  lastError: \(error)")
    }
    let iso = ISO8601DateFormatter()
    for (id, info) in store.lists.sorted(by: { $0.key < $1.key }) {
        let updated = info.updatedAt.map { iso.string(from: $0) } ?? "never"
        print(String(
            format: "  list %-16@ enabled=%@ rules=%@ unsupported=%@ updated=%@\n",
            id as NSString, info.enabled ? "yes" : "no",
            info.ruleCount > 0 ? "\(info.ruleCount)" : "-",
            info.unsupported > 0 ? "\(info.unsupported)" : "-", updated
        ))
    }


default:
    fail("unknown subcommand '\(args.subcommand)'")
}
