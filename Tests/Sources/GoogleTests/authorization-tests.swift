import Foundation
import Google
import Testing

enum AuthorizationTests {
    static func pkce() throws {
        // RFC 7636 appendix B.
        let pkce = try Google.PKCE("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        try Expect.equal(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge")

        let generated = Google.PKCE.generate()
        try Expect.equal(generated.verifier.raw.count, 43, "Generated verifier length")
        try Expect.throwsError("Too short") { _ = try Google.PKCE("short") }
        try Expect.throwsError("Reserved character") { _ = try Google.PKCE(String(repeating: "a", count: 42) + "+") }
    }

    static func request() throws -> Google.AuthorizationRequest {
        try Google.AuthorizationRequest(
            client: Google.OAuthClient(Data(Fixtures.clientJSON.utf8)),
            scopes: [.contacts],
            redirectURI: URL(string: "http://127.0.0.1:53682")!,
            forceConsent: true,
            state: "fixture-state",
            pkce: Google.PKCE("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        )
    }

    static func urlAndRedirect() throws {
        let request = try request()
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        try Expect.equal(request.url.host, "accounts.google.com", "Host")
        try Expect.equal(value("scope"), "email https://www.googleapis.com/auth/contacts openid", "Scopes with identity")
        try Expect.equal(value("access_type"), "offline", "Offline access")
        try Expect.equal(value("prompt"), "consent", "Consent forced")
        try Expect.equal(value("code_challenge_method"), "S256", "PKCE method")
        try Expect.equal(value("code_challenge"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "Challenge")
        try Expect.isNil(value("code_verifier"), "Verifier never in URL")

        let code = try request.code(fromRedirect: URL(string: "http://127.0.0.1:53682/?state=fixture-state&code=fixture-code")!)
        try Expect.equal(code.raw, "fixture-code", "Code")
        try Expect.throwsError("State mismatch") {
            _ = try request.code(fromRedirect: URL(string: "http://127.0.0.1:53682/?state=other&code=x")!)
        }
        try Expect.throwsError("Denied") {
            _ = try request.code(fromRedirect: URL(string: "http://127.0.0.1:53682/?state=fixture-state&error=access_denied")!)
        }
    }

    static func exchange() async throws {
        // An unsigned ID token whose payload carries the account email.
        let payload = Data(#"{"email":"owner@example.org"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let server = FixtureServer { request, _ in
            let body = Fixtures.body(request)
            guard body.contains("grant_type=authorization_code"),
                  body.contains("code=fixture-code"),
                  body.contains("code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            else {
                return (400, #"{"error":"invalid_request"}"#, [:])
            }
            return (200, """
                {"access_token":"fixture-access","expires_in":3599,"refresh_token":"fixture-refresh","scope":"https://www.googleapis.com/auth/contacts openid email","id_token":"e30.\(payload).sig"}
                """, [:])
        }
        let request = try request()
        let grant = try await Google.OAuth(transport: server.transport).exchange(Google.Secret("fixture-code"), for: request)
        try Expect.equal(grant.user.refreshToken.raw, "fixture-refresh", "Refresh token kept")
        try Expect.equal(grant.user.account, "owner@example.org", "Account from ID token")
        try Expect.true(grant.user.scopes.contains(.contacts), "Granted scopes recorded")

        let noRefresh = FixtureServer { _, _ in (200, Fixtures.token(), [:]) }
        do {
            _ = try await Google.OAuth(transport: noRefresh.transport).exchange(Google.Secret("fixture-code"), for: request)
            throw AuthorizationTestFailure.accepted
        } catch let failure as Google.Failure {
            try Expect.equal(failure, .authorizationRequired(.no_refresh_token), "Missing refresh token")
        }
    }

    static func invalidGrant() async throws {
        let server = FixtureServer { _, _ in
            (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, [:])
        }
        do {
            _ = try await Google.OAuth(transport: server.transport).refresh(Fixtures.user())
            throw AuthorizationTestFailure.accepted
        } catch let failure as Google.Failure {
            try Expect.equal(failure, .authorizationRequired(.revoked_or_expired), "invalid_grant")
            try Expect.false((failure.errorDescription ?? "").contains("fixture"), "No secret in error")
        }
    }
}

enum AuthorizationTestFailure: Error {
    case accepted
}
