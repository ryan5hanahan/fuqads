import Foundation
import SafariServices

/// WebKit recompiles content-blocker rules on reload (seconds; SPEC §5.3).
/// Call after writing new blockerList.json payloads for the targets.
public enum Reloader {
    /// Reloads each shard's content blocker; completes on the main queue
    /// with per-shard results (nil = success).
    public static func reload(
        _ shards: [Shard],
        completion: @escaping @Sendable ([Shard: Error?]) -> Void
    ) {
        guard !shards.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }
        let box = ResultBox()
        let group = DispatchGroup()

        for shard in shards {
            group.enter()
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: shard.bundleID) { error in
                box.set(error, for: shard)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(box.results)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _results: [Shard: Error?] = [:]

        var results: [Shard: Error?] {
            lock.lock(); defer { lock.unlock() }
            return _results
        }

        func set(_ error: Error?, for shard: Shard) {
            lock.lock()
            _results[shard] = error
            lock.unlock()
        }
    }
}
