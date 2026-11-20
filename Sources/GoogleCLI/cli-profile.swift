import Arguments
import Foundation
import Google
import Milieu
import Readers

enum CLIFailure: Error, LocalizedError {
    case noClient(String)
    case noUser(String)
    case unknownScope(String)
    case invalidExternalID(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noClient(let profile):
            return "No OAuth client for profile '\(profile)'. Download a Desktop client JSON from the Cloud console and run `google client import <file> --profile \(profile)`."
        case .noUser(let profile):
            return "Profile '\(profile)' is not authorized. Run `google authorize --profile \(profile)`."
        case .unknownScope(let name):
            let known = Google.Scope.named.keys.sorted().joined(separator: ", ")
            return "Unknown scope '\(name)'. Known: \(known), or a full https://www.googleapis.com/auth/… URL."
        case .invalidExternalID(let value):
            return "Invalid external id '\(value)'. Expected type=value, e.g. sysid=1234."
        case .timedOut:
            return "No authorization arrived from the browser in time."
        }
    }
}

enum CLIOptions {
    static func profile() -> [CommandComponentLowerable] {
        [
            opt("profile", as: String.self, default: "default", help: "Credential profile; one Google account each."),
            opt(
                "credentials",
                as: String.self,
                help: "Read the authorized user from this authorized_user JSON file instead of the Keychain."
            ),
        ]
    }
}

/// A profile's credentials in the Keychain: the OAuth client and the
/// authorized user, each as the JSON the SDK parses.
struct Profile: Sendable {
    static let keychainService = "google"

    let name: String
    let credentialsFile: URL?
    private let keychain = KeychainCredentialProvider(service: Profile.keychainService)

    init(_ invocation: ParsedInvocation) throws {
        name = try invocation.value("profile", as: String.self) ?? "default"
        credentialsFile = try invocation.value("credentials", as: String.self).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    private var clientReference: CredentialReference { .init("\(name).client") }
    private var userReference: CredentialReference { .init("\(name).user") }

    func client() async throws -> Google.OAuthClient {
        do {
            return try Google.OAuthClient(try await keychain.resolve(clientReference).data)
        } catch CredentialError.missing {
            throw CLIFailure.noClient(name)
        }
    }

    func storeClient(_ json: Data) async throws -> Google.OAuthClient {
        let client = try Google.OAuthClient(json)
        try await keychain.store(CredentialMaterial(json), for: clientReference)
        return client
    }

    func user() async throws -> Google.AuthorizedUser {
        if let credentialsFile {
            return try Google.AuthorizedUser(DataFileReader(credentialsFile).read().data)
        }
        do {
            return try Google.AuthorizedUser(try await keychain.resolve(userReference).data)
        } catch CredentialError.missing {
            throw CLIFailure.noUser(name)
        }
    }

    func existingUser() async -> Google.AuthorizedUser? {
        try? await user()
    }

    func storeUser(_ user: Google.AuthorizedUser) async throws {
        try await keychain.store(CredentialMaterial(user.encoded()), for: userReference)
    }

    func removeUser() async throws {
        try await keychain.remove(userReference)
    }

    /// An authorizer that writes a rotated refresh token back to the Keychain.
    func authorizer() async throws -> Google.Authorizer {
        let user = try await user()
        let fromFile = credentialsFile != nil
        return Google.Authorizer(user: user, onRotation: { rotated in
            guard !fromFile else { return }
            try? await self.storeUser(rotated)
        })
    }

    func client(_ authorizer: Google.Authorizer) -> Google.Client {
        Google.Client(authorizer: authorizer)
    }
}

func scopes(_ names: [String]) throws -> Set<Google.Scope> {
    try Set(names.flatMap { $0.split(separator: ",") }.map { raw in
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let scope = Google.Scope.named[name] {
            return scope
        }
        guard let scope = try? Google.Scope(name) else {
            throw CLIFailure.unknownScope(name)
        }
        return scope
    })
}

/// Prints rows as left-aligned, space-padded columns.
func printTable(_ header: [String], _ rows: [[String]]) {
    let all = [header] + rows
    let widths = header.indices.map { column in
        all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
    }
    for row in all {
        let cells = row.enumerated().map { index, cell in
            index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }
        print(cells.joined(separator: "  "))
    }
}
