import Foundation
import XCTest
@testable import ShortlistCore

/// Serves saved responses by URL; anything else is a 404. Records what was asked for.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Data, Int)] = [:]
    private var requested: [String] = []

    func serve(_ url: String, fixture name: String, status: Int = 200) throws {
        let parts = name.split(separator: ".")
        let file = try XCTUnwrap(Bundle.module.url(
            forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Fixtures"))
        serve(url, data: try Data(contentsOf: file), status: status)
    }

    func serve(_ url: String, json: String, status: Int = 200) {
        serve(url, data: Data(json.utf8), status: status)
    }

    func serve(_ url: String, data: Data, status: Int = 200) {
        lock.withLock { responses[url] = (data, status) }
    }

    var requests: [String] { lock.withLock { requested } }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        lock.withLock {
            requested.append(url.absoluteString)
            return responses[url.absoluteString] ?? (Data("Not Found".utf8), 404)
        }
    }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".")
        let file = try XCTUnwrap(Bundle.module.url(
            forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }
}
