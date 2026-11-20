import Foundation
import Google
import Testing

enum AuthorizerTests {
    static func cacheAndCoalesce() async throws {
        let clock = FixtureClock()
        let server = FixtureServer { _, count in
            (200, Fixtures.token("access-\(count)"), [:])
        }
        let authorizer = try Google.Authorizer(
            user: Fixtures.user(),
            oauth: Google.OAuth(transport: server.transport, now: { clock.now }),
            now: { clock.now }
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await authorizer.accessToken(for: [.contacts]).value.raw }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        try Expect.equal(Set(tokens), ["access-1"], "Concurrent callers share one refresh")
        try Expect.equal(await server.requests.count, 1, "One token request")

        clock.advance(3600 - 61)
        try Expect.equal(try await authorizer.accessToken(for: [.contacts]).value.raw, "access-1", "Reused before skew")
        clock.advance(2)
        try Expect.equal(try await authorizer.accessToken(for: [.contacts]).value.raw, "access-2", "Refreshed inside skew")
    }

    static func scopesBeforeNetwork() async throws {
        let server = FixtureServer { _, _ in (200, Fixtures.token(), [:]) }
        let authorizer = try Google.Authorizer(user: Fixtures.user(), oauth: Google.OAuth(transport: server.transport))
        do {
            _ = try await authorizer.accessToken(for: [.adwords])
            throw AuthorizationTestFailure.accepted
        } catch let failure as Google.Failure {
            try Expect.equal(failure, .insufficientScope(missing: [.adwords]), "Ads not granted")
        }
        try Expect.equal(await server.requests.count, 0, "Rejected before any request")
        _ = try await authorizer.accessToken(for: [.contactsReadonly])
        try Expect.equal(await server.requests.count, 1, "Covered read scope allowed")
    }

    static func rotation() async throws {
        let server = FixtureServer { _, _ in
            (200, #"{"access_token":"a","expires_in":3600,"refresh_token":"rotated-refresh"}"#, [:])
        }
        let stored = StoredUser()
        let authorizer = try Google.Authorizer(
            user: Fixtures.user(),
            oauth: Google.OAuth(transport: server.transport),
            onRotation: { user in await stored.set(user) }
        )
        _ = try await authorizer.accessToken(for: [.contacts])
        try Expect.equal(await stored.user?.refreshToken.raw, "rotated-refresh", "Rotated token handed over")
        try Expect.equal(await stored.user?.scopes, [.contacts], "Recorded scopes kept")
    }
}

actor StoredUser {
    private(set) var user: Google.AuthorizedUser?

    func set(_ user: Google.AuthorizedUser) {
        self.user = user
    }
}
