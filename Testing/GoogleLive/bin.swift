import Foundation
import Google
import GoogleContacts
import Milieu
import Testing

private enum GoogleLiveFailure: Error {
    case failed
}

/// Read-only checks against Google with a stored profile. Opt in with
/// GOOGLE_LIVE=1; GOOGLE_LIVE_PROFILE names the Keychain profile (default
/// `default`).
@main
struct GoogleLiveMain {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GOOGLE_LIVE"] == "1" else {
            print("t_google_live: skipped; set GOOGLE_LIVE=1 to run against Google.")
            return
        }
        let profile = environment["GOOGLE_LIVE_PROFILE"] ?? "default"
        let reporter = PlainTextTestReporter(
            output: ClosureTestTextOutput { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        )
        let result = await TestRunner.run(suite(profile: profile), sink: reporter)
        if result.isFailure {
            throw GoogleLiveFailure.failed
        }
    }

    static func suite(profile: String) -> TestSuite {
        TestSuite("google-live", title: "Google live (\(profile))") {
            Test("refresh-without-browser") {
                let token = try await authorizer(profile).accessToken(for: [.contactsReadonly])
                try Expect.true(token.expiresAt > Date(), "Fresh access token")
            }
            Test("contact-groups-readable") {
                let client = GoogleContacts.Client(Google.Client(authorizer: try await authorizer(profile)))
                let groups = try await client.groups()
                try Expect.true(groups.contains { $0.name == .myContacts }, "System group present")
            }
        }
    }

    static func authorizer(_ profile: String) async throws -> Google.Authorizer {
        let keychain = KeychainCredentialProvider(service: "google")
        let material = try await keychain.resolve(CredentialReference("\(profile).user"))
        return Google.Authorizer(user: try Google.AuthorizedUser(material.data))
    }
}
