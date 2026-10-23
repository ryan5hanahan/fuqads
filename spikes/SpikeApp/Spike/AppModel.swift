import Foundation
import SafariServices
import SwiftUI

enum CBMode: String, CaseIterable, Identifiable {
    case s4Block = "s4-block"
    case s4Allow = "s4-allow"
    case s3Trivial = "s3-trivial"
    case s3150k = "s3-150k"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .s4Block: return "S4: block mode (no allowlist)"
        case .s4Allow: return "S4: allow mode (ignore-previous-rules)"
        case .s3Trivial: return "S3: trivial list (1 rule)"
        case .s3150k: return "S3: 150k-rule list"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let groupID = "group.dev.bl0cksh1t"
    static let weIdentifier = "dev.bl0cksh1t.spike.we"
    static let cbIdentifier = "dev.bl0cksh1t.spike.cb"

    private var server: Server!
    var isServerRunning: Bool { server?.isRunning ?? false }

    var cbEnabled: Bool?
    var currentMode: CBMode = .s4Block
    var s3Lines: [String] = []
    var s5Lines: [String] = []
    var s2Lines: [String] = []
    var lastError: String?
    private var pollTimer: Timer?

    var groupDir: URL {
        // Ad-hoc spike build: no app-group entitlement, fixed container path.
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(Self.groupID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var cbAppexURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/SpikeCB.appex")
    }

    var pagesURL: URL { URL(string: "http://127.0.0.1:\(Server.port)")! }

    func start() {
        let newServer = Server(onReport: { [weak self] data in
            Task { @MainActor in self?.ingestReport(data) }
        })
        server = newServer
        newServer.start()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        checkCBState()
        apply(mode: .s4Block, record: false)
    }

    // MARK: S3 — rewrite + reload

    func apply(mode: CBMode, record: Bool = true) {
        guard let src = Bundle.main.url(forResource: mode.rawValue, withExtension: "json", subdirectory: "spike-data") else {
            lastError = "missing bundle resource spike-data/\(mode.rawValue).json"
            return
        }
        let dst = cbAppexURL.appendingPathComponent("blockerList.json")
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            lastError = "copy failed: \(error)"
            return
        }
        let t0 = Date()
        SFContentBlockerManager.reloadContentBlocker(withIdentifier: Self.cbIdentifier) { [weak self] error in
            let ms = Date().timeIntervalSince(t0) * 1000
            Task { @MainActor in
                self?.currentMode = mode
                if record {
                    Self.appendJSONL(
                        file: "s3.jsonl",
                        in: self?.groupDir ?? URL(fileURLWithPath: NSHomeDirectory()),
                        entry: [
                            "ts": ISO8601DateFormatter().string(from: Date()),
                            "event": "s3probe",
                            "ok": error == nil,
                            "via": "app",
                            "size": mode.rawValue,
                            "reloadMs": ((ms * 100).rounded() / 100),
                            "error": error.map { "\($0)" } as Any,
                        ]
                    )
                }
                if let error { self?.lastError = "reload: \(error)" }
            }
        }
    }

    /// App -> web extension (SFSafariApplication.dispatchMessage) -> background
    /// port -> sendNativeMessage s3probe -> handler rewrite + reload.
    func triggerHandlerProbe(size: String) {
        SFSafariApplication.dispatchMessage(
            withName: "s3probe",
            toExtensionWithIdentifier: Self.weIdentifier,
            userInfo: ["size": size]
        ) { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = "dispatchMessage: \(error)" }
            }
        }
    }

    // MARK: state

    func checkCBState() {
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: Self.cbIdentifier) { [weak self] state, error in
            Task { @MainActor in
                self?.cbEnabled = state?.isEnabled
                if let error, state == nil { self?.lastError = "CB state: \(error)" }
            }
        }
    }

    private func poll() {
        checkCBState()
        s3Lines = Self.tail(file: "s3.jsonl", in: groupDir, lines: 60)
        s5Lines = Self.tail(file: "s5.jsonl", in: groupDir, lines: 40)
        s2Lines = Self.tail(file: "s2.jsonl", in: groupDir, lines: 60)
    }

    private func ingestReport(_ data: Data) {
        let line = data + Data([0x0A])
        let path = groupDir.appendingPathComponent("s2.jsonl")
        if let handle = FileHandle(forWritingAtPath: path.path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: path)
        }
        poll()
    }

    // MARK: file helpers

    static func appendJSONL(file: String, in dir: URL, entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: []) else { return }
        let line = data + Data([0x0A])
        let path = dir.appendingPathComponent(file)
        if let handle = FileHandle(forWritingAtPath: path.path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: path)
        }
    }

    static func tail(file: String, in dir: URL, lines: Int) -> [String] {
        let path = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return all.suffix(lines).map {
            if let d = $0.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return Self.prettify(obj)
            }
            return $0
        }
    }

    private static func prettify(_ obj: [String: Any]) -> String {
        let pretty: [String: String] = [
            "ts": "ts", "event": "event", "name": "name", "ok": "ok",
            "size": "size", "via": "via", "reloadMs": "reloadMs", "rewriteMs": "rewriteMs",
            "id": "id", "error": "error", "detail": "detail", "alarms": "alarms",
        ]
        var parts: [String] = []
        for key in pretty.keys.sorted() where obj[key] != nil {
            parts.append("\(key)=\(String(describing: obj[key]))")
        }
        return parts.joined(separator: " ")
    }
}
