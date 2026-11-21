import Foundation

/// Finds the best source that actually answers, before a player opens. Add-ons list links that
/// are dead, expired or blocked (404/403/502, HTML error pages), and a player only finds out after
/// a long spinner. This checks a few bytes of each candidate instead, in the caller's order.
public enum SourceCheck {
    public struct Candidate: Sendable {
        public let id: String
        public let url: URL
        public let headers: [String: String]
        public init(id: String, url: URL, headers: [String: String]) {
            self.id = id; self.url = url; self.headers = headers
        }
    }

    /// The first candidate (in order) that responds, checking `batch` at a time so a dead
    /// top pick doesn't cost a full timeout per source. `progress` gets the number checked so far.
    public static func firstAvailable(_ candidates: [Candidate], batch: Int = 4, timeout: TimeInterval = 20,
                                      progress: (@Sendable (Int) async -> Void)? = nil) async -> String? {
        var checked = 0
        for start in stride(from: 0, to: candidates.count, by: batch) {
            if Task.isCancelled { return nil }
            let slice = Array(candidates[start..<min(start + batch, candidates.count)])
            let winner = await withTaskGroup(of: (Int, Bool).self) { group -> Int? in
                for (i, c) in slice.enumerated() {
                    group.addTask { (i, await isAvailable(c, timeout: timeout)) }
                }
                // Return as soon as the best-ranked source that works is known: everything ranked
                // above it has failed. Slow add-on servers (10 s+ to resolve) then cost only themselves.
                var results = [Bool?](repeating: nil, count: slice.count)
                for await (i, ok) in group {
                    results[i] = ok
                    checked += 1
                    await progress?(checked)
                    for k in results.indices {
                        guard let r = results[k] else { break }
                        if r { group.cancelAll(); return k }
                    }
                }
                return nil
            }
            if let w = winner { return slice[w].id }
        }
        return nil
    }

    /// HLS: master playlist, first variant playlist and its first segment must all answer.
    /// Anything else: the first KB must come back as media, not an error page.
    public static func isAvailable(_ c: Candidate, timeout: TimeInterval = 20) async -> Bool {
        if c.url.path.lowercased().hasSuffix(".m3u8") {
            guard let (master, base) = await text(c.url, c.headers, timeout), master.hasPrefix("#EXTM3U") else { return false }
            guard let variant = firstURI(master, base: base) else { return false }
            if master.contains("#EXTINF") { return await bytes(variant, c.headers, timeout) }   // media playlist given directly
            // Media playlists can be megabytes (thousands of segments): stop at the first one.
            guard let segment = await firstSegment(variant, c.headers, timeout) else { return false }
            return await bytes(segment, c.headers, timeout)
        }
        return await bytes(c.url, c.headers, timeout)
    }

    // MARK: Requests

    private static func request(_ url: URL, _ headers: [String: String], _ timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "User-Agent") == nil {
            r.setValue("AppleCoreMedia/1.0.0 (Macintosh; U; Mac OS X)", forHTTPHeaderField: "User-Agent")
        }
        return r
    }

    private static func text(_ url: URL, _ headers: [String: String], _ timeout: TimeInterval) async -> (String, URL)? {
        guard let (data, resp) = try? await session.data(for: request(url, headers, timeout)),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (String(decoding: data.prefix(2_000_000), as: UTF8.self), http.url ?? url)
    }

    private static func bytes(_ url: URL, _ headers: [String: String], _ timeout: TimeInterval) async -> Bool {
        var r = request(url, headers, timeout)
        r.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (data, resp) = try? await session.data(for: r),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return false }
        // Error pages often come back as 200 text/html.
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return !type.contains("text/html") && !type.contains("application/json")
    }

    private static func firstSegment(_ url: URL, _ headers: [String: String], _ timeout: TimeInterval) async -> URL? {
        guard let (stream, resp) = try? await session.bytes(for: request(url, headers, timeout)),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let base = http.url ?? url
        var sawHeader = false
        do {
            for try await raw in stream.lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !sawHeader { guard line == "#EXTM3U" else { return nil }; sawHeader = true; continue }
                if !line.isEmpty && !line.hasPrefix("#") { return URL(string: line, relativeTo: base)?.absoluteURL }
            }
        } catch { return nil }
        return nil
    }

    private static func firstURI(_ playlist: String, base: URL) -> URL? {
        playlist.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    // MARK: Session

    /// Ephemeral (nothing tokenized on disk), and keeps the add-on's headers across cross-host
    /// redirects, the same way the players need them.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg, delegate: KeepHeaders(), delegateQueue: nil)
    }()

    private final class KeepHeaders: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var next = request
            for (k, v) in task.originalRequest?.allHTTPHeaderFields ?? [:] where next.value(forHTTPHeaderField: k) == nil {
                next.setValue(v, forHTTPHeaderField: k)
            }
            completionHandler(next)
        }
    }
}
