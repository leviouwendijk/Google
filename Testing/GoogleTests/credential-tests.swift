import Foundation
import Google
import Testing

enum CredentialTests {
    static func parse() throws {
        let client = try Google.OAuthClient(Data(Fixtures.clientJSON.utf8))
        try Expect.equal(client.clientID, "fixture-client.apps.googleusercontent.com", "Client id")
        try Expect.equal(client.clientSecret.raw, "fixture-client-secret", "Client secret")

        let user = try Fixtures.user()
        try Expect.equal(user.refreshToken.raw, "fixture-refresh-token", "Refresh token")
        try Expect.equal(user.scopes, [.contacts], "Scopes")
        try Expect.equal(user.account, "owner@example.org", "Account")

        let gcloud = """
            {"type":"authorized_user","client_id":"a","client_secret":"b","refresh_token":"c","quota_project_id":"p"}
            """
        try Expect.true(try Google.AuthorizedUser(Data(gcloud.utf8)).scopes.isEmpty, "gcloud file without scopes")
    }

    static func reject() throws {
        func user(_ json: String) -> Google.CredentialFailure? {
            do {
                _ = try Google.AuthorizedUser(Data(json.utf8))
                return nil
            } catch {
                return error
            }
        }
        try Expect.equal(user("{"), .malformedJSON, "Malformed JSON")
        try Expect.equal(user(#"{"client_id":"a"}"#), .missingField("type"), "No type")
        try Expect.equal(
            user(#"{"type":"service_account","client_email":"x"}"#),
            .unsupportedKind("service_account"),
            "Service account not yet supported"
        )
        try Expect.equal(
            user(#"{"type":"authorized_user","client_id":"a","client_secret":"b","refresh_token":"  "}"#),
            .missingField("refresh_token"),
            "Blank refresh token"
        )
        try Expect.equal(
            user(#"{"type":"authorized_user","client_id":"a","client_secret":"b","refresh_token":"c","scopes":["contacts"]}"#),
            .invalidScope("contacts"),
            "Short scope name stored"
        )

        do {
            _ = try Google.OAuthClient(Data(#"{"web":{"client_id":"a","client_secret":"b"}}"#.utf8))
            throw CredentialTestFailure.accepted
        } catch let failure as Google.CredentialFailure {
            try Expect.equal(failure, .notDesktopClient, "Web client rejected")
        }
    }

    static func roundTripAndRedact() throws {
        let user = try Fixtures.user()
        let again = try Google.AuthorizedUser(user.encoded())
        try Expect.equal(again, user, "Encoded user parses back")

        let texts = [
            String(describing: user),
            String(reflecting: user),
            String(describing: user.client),
            String(describing: user.refreshToken),
            "\(user.client.clientSecret)",
        ]
        for text in texts {
            try Expect.false(text.contains("fixture-refresh-token"), "No refresh token in \(text)")
            try Expect.false(text.contains("fixture-client-secret"), "No client secret in \(text)")
        }
    }
}

private enum CredentialTestFailure: Error {
    case accepted
}

enum ScopeTests {
    static func validateAndCover() throws {
        try Expect.equal(try Google.Scope("https://www.googleapis.com/auth/contacts"), .contacts, "Full scope")
        try Expect.equal(try Google.Scope("openid"), .openid, "OpenID scope")
        try Expect.throwsError("Bare word") { _ = try Google.Scope("contacts") }
        try Expect.throwsError("Other host") { _ = try Google.Scope("https://example.org/auth/contacts") }
        try Expect.throwsError("Prefix only") { _ = try Google.Scope("https://www.googleapis.com/auth/") }

        try Expect.true(Google.Scope.contacts.covers(.contactsReadonly), "Write covers read")
        try Expect.false(Google.Scope.contactsReadonly.covers(.contacts), "Read does not cover write")
        try Expect.equal(Google.Scope.missing([.contactsReadonly], from: [.contacts]), [], "Covered")
        try Expect.equal(Google.Scope.missing([.contacts, .adwords], from: [.contacts]), [.adwords], "Missing ads")
    }
}
