import Foundation
@_spi(Testing) import Google
import Testing

enum ClientTests {
    static let base = URL(string: "https://people.googleapis.com/v1")!

    static func client(_ server: FixtureServer) throws -> Google.Client {
        Google.Client(
            authorizer: try Google.Authorizer(user: Fixtures.user(), oauth: Google.OAuth(transport: server.transport)),
            transport: server.transport,
            sleep: { _ in }
        )
    }

    static func refreshOnce() async throws {
        let server = FixtureServer { request, _ in
            if request.url?.path == Fixtures.tokenPath {
                return (200, Fixtures.token("access-\(UUID().uuidString)"), [:])
            }
            return (401, #"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#, [:])
        }
        do {
            try await client(server).send(Google.Request(.get, base: base, path: "/people/me", scopes: [.contacts]))
            throw AuthorizationTestFailure.accepted
        } catch let failure as Google.Failure {
            try Expect.equal(failure, .authorizationRequired(.revoked_or_expired), "Second 401 fails")
        }
        try Expect.equal(await server.count(path: "/v1/people/me"), 2, "Sent twice")
        try Expect.equal(await server.count(path: Fixtures.tokenPath), 2, "Refreshed once in between")

        let sent = await server.requests.first { $0.url?.path == "/v1/people/me" }
        try Expect.true(sent?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer access-") == true, "Bearer header")
    }

    static func retryReadsOnly() async throws {
        let server = FixtureServer { request, _ in
            if request.url?.path == Fixtures.tokenPath {
                return (200, Fixtures.token(), [:])
            }
            return (429, #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#, ["Retry-After": "1"])
        }
        let client = try client(server)
        do {
            try await client.send(Google.Request(.get, base: base, path: "/read", scopes: [.contacts]))
            throw AuthorizationTestFailure.accepted
        } catch let failure as Google.Failure {
            try Expect.equal(failure, .rateLimited(retryAfterSeconds: 1), "Rate limited after retries")
        }
        try Expect.equal(await server.count(path: "/v1/read"), 3, "Read tried three times")

        do {
            try await client.send(Google.Request(.post, base: base, path: "/write", body: Data("{}".utf8), scopes: [.contacts]))
            throw AuthorizationTestFailure.accepted
        } catch is Google.Failure {}
        try Expect.equal(await server.count(path: "/v1/write"), 1, "Write sent once")
    }

    static func errorEnvelope() throws {
        func failure(_ status: Int, _ body: String) -> Google.Failure {
            Google.Client.failure(from: Data(body.utf8), status: status, retryAfter: nil)
        }
        try Expect.equal(
            failure(403, #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#),
            .insufficientScope(missing: []),
            "Scope reason"
        )
        try Expect.equal(failure(404, "not json"), .notFound, "Not found without envelope")
        try Expect.equal(
            failure(400, #"{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"etag mismatch"}}"#),
            .failedPrecondition(reason: "etag mismatch"),
            "Stale etag"
        )
        try Expect.equal(
            failure(400, #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Invalid personFields"}}"#),
            .api(httpStatus: 400, status: "INVALID_ARGUMENT", reason: nil, message: "Invalid personFields"),
            "Other API error"
        )
    }

    static func pagination() async throws {
        let pages: [String?: Google.Page<Int>] = [
            nil: .init(items: [1, 2], nextPageToken: "b"),
            "b": .init(items: [3], nextPageToken: ""),
        ]
        let all = try await Google.all { token in pages[token]! }
        try Expect.equal(all, [1, 2, 3], "All pages, empty token ends")

        try await Expect.throwsError("Repeating token") {
            _ = try await Google.all { _ in Google.Page(items: [1], nextPageToken: "same") }
        }
    }
}
