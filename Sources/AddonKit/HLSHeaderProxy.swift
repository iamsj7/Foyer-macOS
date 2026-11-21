import Foundation
import Network

/// AVPlayer sends custom headers (Referer, Origin…) only on the first playlist request, not on
/// segment, init-map or key requests, so hosts that check them answer 404/403 mid-stream.
/// This loopback proxy serves AVPlayer and adds the add-on's headers to every upstream request.
/// Playlists are rewritten so every URI they reference comes back through the proxy.
///
/// URLs are never logged (they can carry add-on tokens). Bound to 127.0.0.1 only.
public final class HLSHeaderProxy: @unchecked Sendable {
    public static let shared = HLSHeaderProxy()

    private let queue = DispatchQueue(label: "hls.header-proxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var readyWaiters: [CheckedContinuation<UInt16?, Never>] = []
    private var sessions: [String: [String: String]] = [:]   // session id → headers
    private var upstream: URLSession!
    private let relay = Relay()

    public init() {
        let config = URLSessionConfiguration.ephemeral   // nothing tokenized lands in a disk cache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        // Delegate callbacks run on `queue`, so every piece of proxy state is confined to it.
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        upstream = URLSession(configuration: config, delegate: relay, delegateQueue: ops)
        relay.proxy = self
    }

    /// Does this stream need the proxy? HLS whose add-on sends headers beyond User-Agent.
    public static func isNeeded(url: URL, headers: [String: String]) -> Bool {
        url.path.lowercased().hasSuffix(".m3u8")
            && headers.keys.contains { $0.caseInsensitiveCompare("User-Agent") != .orderedSame }
    }

    /// A loopback URL that plays `url` with `headers` on every request, or nil if the proxy can't start.
    public func localURL(for url: URL, headers: [String: String]) async -> URL? {
        guard let port = await start() else { return nil }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        queue.sync { sessions[String(id)] = headers }
        return Self.proxied(url, session: String(id), port: port)
    }

    /// Forgets a session's headers once its player closes; its loopback URLs stop working.
    public func endSession(for localURL: URL) {
        guard let id = localURL.pathComponents.dropFirst().first else { return }
        queue.async { self.sessions[id] = nil }
    }

    // MARK: Listener

    private func start() async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            queue.async { [self] in
                if port != 0 { cont.resume(returning: port); return }
                readyWaiters.append(cont)
                guard listener == nil else { return }
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                params.allowLocalEndpointReuse = true
                guard let l = try? NWListener(using: params) else { finishStart(nil); return }
                listener = l
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self, weak l] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.finishStart(l?.port?.rawValue)
                    case .failed, .cancelled:
                        self.listener = nil
                        self.port = 0
                        self.finishStart(nil)
                    default: break
                    }
                }
                l.start(queue: queue)
            }
        }
    }

    /// On `queue`.
    private func finishStart(_ p: UInt16?) {
        if let p { port = p }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(returning: p) }
    }

    // MARK: Connections (one request per connection; AVPlayer opens more as it needs)

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receiveHeader(c, buffer: Data())
    }

    private func receiveHeader(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.receiveHeader(c, buffer: buf)
            }
        }
    }

    private func handle(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return reply(c, status: 405) }
        let isHead = parts[0] == "HEAD"
        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            clientHeaders[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let (session, target) = Self.decode(path: String(parts[1])),
              let headers = sessions[session] else { return reply(c, status: 404) }

        var req = URLRequest(url: target)
        req.httpMethod = isHead ? "HEAD" : "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil, let ua = clientHeaders["user-agent"] {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        if let range = clientHeaders["range"] { req.setValue(range, forHTTPHeaderField: "Range") }

        let task = upstream.dataTask(with: req)
        relay.transfers[task.taskIdentifier] = Transfer(connection: c, session: session, target: target, headOnly: isHead)
        // AVPlayer drops requests on seeks and quality switches: stop the download with it.
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: task.cancel()
            default: break
            }
        }
        task.resume()
    }

    private func reply(_ c: NWConnection, status: Int, type: String = "text/plain", body: Data = Data(),
                       extra: [String: String] = [:], headOnly: Bool = false) {
        var out = Self.head(status: status, type: type, length: body.count, extra: extra)
        if !headOnly { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    static func head(status: Int, type: String, length: Int?, extra: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        head += "Content-Type: \(type)\r\nConnection: close\r\n"
        if let length { head += "Content-Length: \(length)\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    // MARK: Upstream relay

    /// One AVPlayer request in flight.
    final class Transfer {
        let connection: NWConnection
        let session: String
        let target: URL
        let headOnly: Bool
        var playlist: Data?          // set when the response is a playlist (buffered, then rewritten)
        var failed = false
        init(connection: NWConnection, session: String, target: URL, headOnly: Bool) {
            self.connection = connection; self.session = session; self.target = target; self.headOnly = headOnly
        }
    }

    /// Streams media bytes to AVPlayer as they arrive; buffers and rewrites playlists (they're small).
    /// All callbacks run on the proxy's queue.
    final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var proxy: HLSHeaderProxy?
        var transfers: [Int: Transfer] = [:]

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let t = transfers[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); return
            }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let base = http.url ?? t.target
            if (200..<300).contains(http.statusCode), !t.headOnly, HLSHeaderProxy.isPlaylist(type: type, url: base, body: Data()) {
                t.playlist = Data()
            } else {
                var extra: [String: String] = [:]
                for k in ["Content-Range", "Accept-Ranges"] {
                    if let v = http.value(forHTTPHeaderField: k) { extra[k] = v }
                }
                let length = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
                t.connection.send(content: HLSHeaderProxy.head(status: http.statusCode, type: type, length: length, extra: extra),
                                  completion: .contentProcessed { _ in })
                if t.headOnly { completionHandler(.cancel); return }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let t = transfers[dataTask.taskIdentifier] else { return }
            if t.playlist != nil { t.playlist!.append(data) }
            else { t.connection.send(content: data, completion: .contentProcessed { _ in }) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let t = transfers.removeValue(forKey: task.taskIdentifier) else { return }
            let c = t.connection
            if let body = t.playlist, error == nil, let proxy {
                let base = task.response?.url ?? t.target
                let text = HLSHeaderProxy.rewrite(String(decoding: body, as: UTF8.self), base: base,
                                                  session: t.session, port: proxy.port)
                proxy.reply(c, status: 200, type: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            } else if task.response == nil {
                proxy?.reply(c, status: 502)   // nothing sent yet
            } else {
                // Headers and bytes already went out; closing ends the body.
                c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { _ in c.cancel() })
            }
        }

        /// Hosts often redirect segments to a CDN on another host that checks Origin/Referer too.
        /// URLSession drops custom headers on cross-host redirects, so put the add-on's back.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            for (k, v) in task.originalRequest?.allHTTPHeaderFields ?? [:] where next.value(forHTTPHeaderField: k) == nil {
                next.setValue(v, forHTTPHeaderField: k)
            }
            completionHandler(next)
        }
    }

    // MARK: URL mapping and playlist rewriting

    static func proxied(_ url: URL, session: String, port: UInt16) -> URL? {
        let token = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // Keep the original file name last so AVFoundation still sees ".m3u8", ".ts", ".mp4"…
        let name = url.lastPathComponent.isEmpty ? "index" : url.lastPathComponent
        let safeName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        return URL(string: "http://127.0.0.1:\(port)/\(session)/\(token)/\(safeName)")
    }

    static func decode(path: String) -> (String, URL)? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return nil }
        var b64 = comps[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let url = URL(string: String(decoding: data, as: UTF8.self)),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return (String(comps[0]), url)
    }

    static func isPlaylist(type: String, url: URL, body: Data) -> Bool {
        type.lowercased().contains("mpegurl") || url.path.lowercased().hasSuffix(".m3u8")
            || body.prefix(7) == Data("#EXTM3U".utf8)
    }

    /// Points every URI line and every URI="…" attribute (keys, maps, media, i-frames) at the proxy.
    static func rewrite(_ playlist: String, base: URL, session: String, port: UInt16) -> String {
        func map(_ ref: String) -> String {
            guard let abs = URL(string: ref, relativeTo: base)?.absoluteURL,
                  abs.scheme == "http" || abs.scheme == "https",
                  let p = proxied(abs, session: session, port: port) else { return ref }
            return p.absoluteString
        }
        return playlist.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return line }
            if !t.hasPrefix("#") { return map(t) }
            guard t.contains("URI=\"") else { return line }
            var out = ""
            var rest = Substring(line)
            while let r = rest.range(of: "URI=\"") {
                out += rest[..<r.upperBound]
                rest = rest[r.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                out += map(String(rest[..<close]))
                rest = rest[close...]
            }
            return out + rest
        }.joined(separator: "\n")
    }
}
