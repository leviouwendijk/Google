import Foundation
import Testing

private enum GoogleTestingFailure: Error {
    case failed
}

@main
struct GoogleTestingMain {
    static func main() async throws {
        let reporter = PlainTextTestReporter(
            output: ClosureTestTextOutput { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        )
        let result = await TestRunner.run(
            GoogleTestSuite.suite,
            sink: reporter
        )
        if result.isFailure {
            throw GoogleTestingFailure.failed
        }
    }
}

enum GoogleTestSuite {
    static let suite = TestSuite(
        "google",
        title: "Google"
    ) {
        Test("credentials-parse-client-and-user") {
            try CredentialTests.parse()
        }
        Test("credentials-reject-malformed") {
            try CredentialTests.reject()
        }
        Test("credentials-round-trip-and-redact") {
            try CredentialTests.roundTripAndRedact()
        }
        Test("scopes-validate-and-cover") {
            try ScopeTests.validateAndCover()
        }
        Test("pkce-matches-rfc-7636") {
            try AuthorizationTests.pkce()
        }
        Test("authorization-url-and-redirect") {
            try AuthorizationTests.urlAndRedirect()
        }
        Test("exchange-records-grant") {
            try await AuthorizationTests.exchange()
        }
        Test("refresh-invalid-grant-requires-authorization") {
            try await AuthorizationTests.invalidGrant()
        }
        Test("authorizer-caches-coalesces-and-skews") {
            try await AuthorizerTests.cacheAndCoalesce()
        }
        Test("authorizer-checks-scopes-before-network") {
            try await AuthorizerTests.scopesBeforeNetwork()
        }
        Test("authorizer-stores-rotated-token") {
            try await AuthorizerTests.rotation()
        }
        Test("client-refreshes-once-on-401") {
            try await ClientTests.refreshOnce()
        }
        Test("client-retries-reads-not-writes") {
            try await ClientTests.retryReadsOnly()
        }
        Test("client-maps-error-envelope") {
            try ClientTests.errorEnvelope()
        }
        Test("pagination-follows-and-detects-loops") {
            try await ClientTests.pagination()
        }
        Test("contacts-parse-and-names") {
            try ContactsTests.parse()
        }
        Test("contacts-upsert-creates-updates-keeps") {
            try await ContactsTests.upsert()
        }
    }
}
