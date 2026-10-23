import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1:8642 serving the spike test pages.
/// No keep-alive: every connection is answered once and closed.
final class Server: @unchecked Sendable {
    static let port: UInt16 = 8642

    private let queue = DispatchQueue(label: "spike.server")
    private var listener: NWListener?
    private var onReport: ((Data) -> Void)?

    var isRunning: Bool { listener?.state == .ready }

    init(onReport: @escaping @Sendable (Data) -> Void) {
        self.onReport = onReport
    }

    func start() {
        queue.async {
            let params = NWParameters.tcp
            let endpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = NWListener(using: params, on: endpoint)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    private func handle(_ connection: NWConnection) {
        let conn = Connection(connection, queue: queue, onReport: onReport)
        conn.start()
    }

    private final class Connection: @unchecked Sendable {
        let conn: NWConnection
        let queue: DispatchQueue
        let onReport: ((Data) -> Void)?
        var headerData = Data()
        var bodyData = Data()
        var bodyNeeded = 0
        var request = ""
        var done = false

        init(_ conn: NWConnection, queue: DispatchQueue, onReport: ((Data) -> Void)?) {
            self.conn = conn
            self.queue = queue
            self.onReport = onReport
        }

        func start() {
            conn.start(queue: queue)
            receiveMore()
        }

        private func receiveMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                self?.step(data ?? Data())
            }
        }

        private func step(_ data: Data) {
            guard !done else { return }
            if data.isEmpty { finish(); return }
            headerData.append(data)
            if bodyNeeded == 0 {
                guard let range = headerData.range(of: Data("\r\n\r\n".utf8)) else {
                    if headerData.count > 65536 { finish() } else { receiveMore() }
                    return
                }
                let head = String(decoding: headerData[..<range.lowerBound], as: UTF8.self)
                request = head.components(separatedBy: "\r\n").first ?? ""
                let lower = head.lowercased()
                if let line = lower.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
                    let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
                    bodyNeeded = Int(value ?? "") ?? 0
                }
                bodyData = headerData.subdata(in: range.upperBound..<headerData.count)
                headerData.removeAll()
                bodyNeeded -= bodyData.count
                if bodyNeeded <= 0 { respond() ; return }
            }
            bodyData.append(data)
            bodyNeeded -= data.count
            if bodyNeeded <= 0 { respond() } else { receiveMore() }
        }

        private func respond() {
            let parts = request.split(separator: " ", omittingEmptySubsequences: true)
            let method = parts.first.map(String.init) ?? "GET"
            let rawTarget = parts.count > 1 ? String(parts[1]) : "/"
            let path = rawTarget.split(separator: "?").first.map(String.init) ?? rawTarget
            let cleanPath = String(path.drop(while: { $0 == "/" }))

            var status = "200 OK"
            var contentType = "text/plain"
            var body: Data

            if method == "POST", path == "/report" {
                onReport?(bodyData)
                body = Data("ok".utf8)
            } else if method == "GET" {
                switch cleanPath {
                case "", "index.html":
                    contentType = "text/html"
                    body = Self.page("index.html") ?? Data("missing index.html".utf8)
                case let p where p.hasSuffix(".txt"):
                    body = Self.page(p) ?? Data("ok\n".utf8)
                case let p where p.hasSuffix(".png"):
                    contentType = "image/png"
                    body = Self.page(p) ?? Data()
                case let p where p.hasSuffix(".html"):
                    contentType = "text/html"
                    body = Self.page(p) ?? Data("missing \(p)".utf8)
                default:
                    status = "404 Not Found"
                    body = Data("not found".utf8)
                }
            } else {
                status = "404 Not Found"
                body = Data("not found".utf8)
            }

            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(header.utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }

        private static func page(_ name: String) -> Data? {
            guard let url = Bundle.main.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "pages"
            ) else { return nil }
            return try? Data(contentsOf: url)
        }

        private func finish() {
            guard !done else { return }
            done = true
            conn.cancel()
        }
    }
}
