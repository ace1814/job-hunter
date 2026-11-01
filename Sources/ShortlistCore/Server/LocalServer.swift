import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Reads a whole request, or nil if `data` doesn't hold one yet.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: String(parts[1])) else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data[split.upperBound...]
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }

        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: url.path, query: query, headers: headers, body: Data(body))
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    var bytes: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict", 413: "Too Large", 500: "Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A very small HTTP server. It listens only on the addresses it's given, one request per
/// connection, and hands each request to `handler`.
public final class LocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private static let maxRequestSize = 1_000_000
    private var handler: Handler
    private let queue = DispatchQueue(label: "shortlist.server")
    private var listeners: [String: NWListener] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replaces what answers requests, leaving the listeners up.
    public func setHandler(_ handler: @escaping Handler) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.handler = handler
                continuation.resume()
            }
        }
    }

    /// Listens on `hosts`, stopping any address that's no longer in the list. Returns the hosts
    /// that couldn't be opened.
    public func listen(on hosts: [String], port: UInt16) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                for (host, listener) in self.listeners where !hosts.contains(host) {
                    listener.cancel()
                    self.listeners[host] = nil
                }
                var failed: [String] = []
                for host in hosts where self.listeners[host] == nil {
                    do {
                        self.listeners[host] = try self.startListener(host: host, port: port)
                    } catch {
                        failed.append(host)
                    }
                }
                continuation.resume(returning: failed)
            }
        }
    }

    private func startListener(host: String, port: UInt16) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        return listener
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var data = buffer
            if let chunk { data.append(chunk) }
            if data.count > Self.maxRequestSize {
                return self.send(HTTPResponse(status: 413), on: connection)
            }
            if let request = HTTPRequest.parse(data) {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: data)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension LocalServer {
    /// This Mac's Tailscale address, if it's on a tailnet. Tailscale hands out addresses from
    /// 100.64.0.0/10, a range nothing else on a normal network uses.
    public static func tailscaleAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            let parts = text.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return text }
        }
        return nil
    }
}
