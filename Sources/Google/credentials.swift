import Foundation
import Primitives
import Sensitivity

public extension Google {
    enum CredentialFailure: Error, Sendable, Equatable, LocalizedError {
        case malformedJSON
        case missingField(String)
        case unsupportedKind(String)
        case notDesktopClient
        case invalidScope(String)

        public var errorDescription: String? {
            switch self {
            case .malformedJSON:
                return "The Google credential is not valid JSON."
            case .missingField(let field):
                return "The Google credential has no usable `\(field)`."
            case .unsupportedKind(let kind):
                return "Google credential kind `\(kind)` is not supported."
            case .notDesktopClient:
                return "The OAuth client is not a Desktop (`installed`) client; create one of type Desktop app in the Cloud console."
            case .invalidScope(let scope):
                return "The Google credential records an invalid scope `\(scope)`."
            }
        }
    }

    /// A Desktop OAuth client, from the `client_secret_….json` the Cloud
    /// console downloads (`{"installed": {…}}`).
    struct OAuthClient: Invariant, Sendable, Hashable, Sensitivity.Redacted {
        public static let redactedLabel = "Google OAuth client"

        public let clientID: String
        public let clientSecret: Secret

        public init(_ raw: Data) throws(CredentialFailure) {
            let document: Document
            do {
                document = try JSONDecoder().decode(Document.self, from: raw)
            } catch {
                throw .malformedJSON
            }
            guard let installed = document.installed else {
                throw document.web == nil ? .missingField("installed") : .notDesktopClient
            }
            try self.init(clientID: installed.client_id, clientSecret: installed.client_secret)
        }

        public init(clientID: String?, clientSecret: String?) throws(CredentialFailure) {
            guard let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clientID.isEmpty
            else {
                throw .missingField("client_id")
            }
            guard let secret = clientSecret, let clientSecret = try? Secret(secret) else {
                throw .missingField("client_secret")
            }
            self.clientID = clientID
            self.clientSecret = clientSecret
        }

        private struct Document: Decodable {
            struct Client: Decodable {
                let client_id: String?
                let client_secret: String?
            }

            let installed: Client?
            let web: Client?
        }
    }

    /// A user's grant: the `authorized_user` JSON that gcloud and Application
    /// Default Credentials use, plus the scopes granted and the account
    /// email, recorded at authorization. One per profile.
    struct AuthorizedUser: Invariant, Sendable, Hashable, Sensitivity.Redacted {
        public static let redactedLabel = "Google authorized user"

        public let client: OAuthClient
        public let refreshToken: Secret
        /// Empty for a credential from elsewhere (gcloud); then scopes are
        /// learned from the first refresh.
        public let scopes: Set<Scope>
        public let account: String?

        public init(_ raw: Data) throws(CredentialFailure) {
            let document: Document
            do {
                document = try JSONDecoder().decode(Document.self, from: raw)
            } catch {
                throw .malformedJSON
            }
            guard let kind = document.type else {
                throw .missingField("type")
            }
            guard kind == "authorized_user" else {
                throw .unsupportedKind(kind)
            }
            guard let token = document.refresh_token, let refreshToken = try? Secret(token) else {
                throw .missingField("refresh_token")
            }
            var scopes: Set<Scope> = []
            for text in document.scopes ?? [] {
                guard let scope = try? Scope(text) else {
                    throw .invalidScope(text)
                }
                scopes.insert(scope)
            }
            self.init(
                client: try OAuthClient(clientID: document.client_id, clientSecret: document.client_secret),
                refreshToken: refreshToken,
                scopes: scopes,
                account: document.account
            )
        }

        public init(client: OAuthClient, refreshToken: Secret, scopes: Set<Scope>, account: String?) {
            self.client = client
            self.refreshToken = refreshToken
            self.scopes = scopes
            self.account = account
        }

        /// The JSON to store; parses back through `init(_:)`.
        public func encoded() -> Data {
            let document = Document(
                type: "authorized_user",
                client_id: client.clientID,
                client_secret: client.clientSecret.raw,
                refresh_token: refreshToken.raw,
                scopes: scopes.sorted().map(\.raw),
                account: account
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(document)) ?? Data()
        }

        private struct Document: Codable {
            let type: String?
            let client_id: String?
            let client_secret: String?
            let refresh_token: String?
            let scopes: [String]?
            let account: String?
        }
    }
}
