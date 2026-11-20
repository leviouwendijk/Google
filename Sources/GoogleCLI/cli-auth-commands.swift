import Arguments
import Foundation
import Google
import Readers

enum ClientCommand: ArgumentCommand {
    static let name = "client"

    static var children: [ArgumentCommandType] {
        [ClientImportCommand.self]
    }

    static func components() throws -> [CommandComponentLowerable] {
        [about("The Desktop OAuth client a profile authorizes through.")]
    }
}

enum ClientImportCommand: RunnableArgumentCommand {
    static let name = "import"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Store a Desktop client's client_secret_….json in the Keychain. The file can be deleted afterwards."),
            arg("file", as: String.self, help: "The downloaded client JSON."),
        ] + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let profile = try Profile(invocation)
        let path = try invocation.require("file", as: String.self)
        let data = try DataFileReader(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).read().data
        let client = try await profile.storeClient(data)
        print("Stored OAuth client \(client.clientID) for profile '\(profile.name)'.")
    }
}

enum AuthorizeCommand: RunnableArgumentCommand {
    static let name = "authorize"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Authorize the profile in the browser, once. Scopes add to an existing grant unless --replace."),
            opt(
                "scopes",
                as: String.self,
                default: "contacts",
                help: "Comma-separated: contacts, contacts.readonly, business, ads, analytics, searchconsole."
            ),
            flag("replace", negation: .none, help: "Replace the stored grant instead of adding scopes to it."),
            flag("no-browser", negation: .none, help: "Print the URL without opening a browser."),
        ] + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let profile = try Profile(invocation)
        let client = try await profile.client()
        var requested = try scopes([try invocation.value("scopes", as: String.self) ?? "contacts"])
        let existing = try invocation.flag("replace") ? nil : await profile.existingUser()
        if let existing {
            if Google.Scope.missing(requested, from: existing.scopes).isEmpty {
                print("Profile '\(profile.name)' is already authorized for these scopes (\(existing.account ?? "unknown account")).")
                return
            }
            requested.formUnion(existing.scopes)
        }

        let receiver = try LoopbackReceiver()
        let request = Google.AuthorizationRequest(
            client: client,
            scopes: requested,
            redirectURI: receiver.redirectURI,
            forceConsent: true
        )
        print("Open this URL to authorize profile '\(profile.name)':\n\n\(request.url.absoluteString)\n")
        if try !invocation.flag("no-browser") {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [request.url.absoluteString]
            try? open.run()
        }

        let redirect = await Task.detached { receiver.receive(timeoutSeconds: 300) }.value
        guard let redirect else {
            throw CLIFailure.timedOut
        }
        let code = try request.code(fromRedirect: redirect)
        let grant = try await Google.OAuth().exchange(code, for: request)
        try await profile.storeUser(grant.user)

        print("Authorized \(grant.user.account ?? "unknown account") for profile '\(profile.name)':")
        for scope in grant.user.scopes.sorted() {
            print("  \(scope.raw)")
        }
    }
}

enum StatusCommand: RunnableArgumentCommand {
    static let name = "status"

    static func components() throws -> [CommandComponentLowerable] {
        [about("Refresh the profile's access token and show its account and scopes. Never prints tokens.")]
            + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let profile = try Profile(invocation)
        let user = try await profile.user()
        let token = try await profile.authorizer().accessToken(for: [])
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        print("profile   \(profile.name)")
        print("account   \(user.account ?? "unknown")")
        print("source    \(profile.credentialsFile?.path ?? "Keychain (service \(Profile.keychainService))")")
        print("token     valid until \(formatter.string(from: token.expiresAt))")
        print("scopes    \(token.scopes.sorted().map(\.raw).joined(separator: "\n          "))")
    }
}

enum RevokeCommand: RunnableArgumentCommand {
    static let name = "revoke"

    static func components() throws -> [CommandComponentLowerable] {
        [about("Revoke the profile's grant at Google and delete it from the Keychain.")]
            + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let profile = try Profile(invocation)
        let user = try await profile.user()
        do {
            try await Google.OAuth().revoke(user.refreshToken)
        } catch Google.Failure.authorizationRequired, Google.Failure.oauth(error: "invalid_token") {
            // Already revoked or expired at Google.
        }
        if profile.credentialsFile == nil {
            try await profile.removeUser()
        }
        print("Revoked \(user.account ?? "the grant") for profile '\(profile.name)'.")
    }
}
