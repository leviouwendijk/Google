import Foundation
import Google
import Primitives

/// A fake Google: answers each request from a handler and records it.
actor FixtureServer {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> (Int, String, [String: String])

    private(set) var requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body, headers) = try await handler(request, requests.count)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            throw Google.Failure.invalidTransportResponse
        }
        return (Data(body.utf8), response)
    }

    nonisolated var transport: Google.Transport {
        Google.Transport { request in try await self.send(request) }
    }

    func count(path: String) -> Int {
        requests.filter { $0.url?.path == path }.count
    }
}

enum Fixtures {
    static let clientJSON = """
        {"installed":{"client_id":"fixture-client.apps.googleusercontent.com","client_secret":"fixture-client-secret","redirect_uris":["http://localhost"]}}
        """

    static func userJSON(scopes: [String] = ["https://www.googleapis.com/auth/contacts"]) -> String {
        let list = scopes.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"type":"authorized_user","client_id":"fixture-client.apps.googleusercontent.com","client_secret":"fixture-client-secret","refresh_token":"fixture-refresh-token","scopes":[\(list)],"account":"owner@example.org"}
            """
    }

    static func user(scopes: [String] = ["https://www.googleapis.com/auth/contacts"]) throws -> Google.AuthorizedUser {
        try Google.AuthorizedUser(Data(userJSON(scopes: scopes).utf8))
    }

    static func token(_ value: String = "fixture-access", expiresIn: Int = 3600, scope: String = "https://www.googleapis.com/auth/contacts") -> String {
        """
        {"access_token":"\(value)","expires_in":\(expiresIn),"scope":"\(scope)","token_type":"Bearer"}
        """
    }

    static let tokenPath = "/token"

    static func body(_ request: URLRequest) -> String {
        request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Time tests can move, read through `clock`.
final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.withLock { current }
    }

    var clock: WallClock {
        WallClock { WallClock.Instant(self.now) }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
