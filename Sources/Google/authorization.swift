import CryptoKit
import Foundation
import Primitives

public extension Google {
    enum AuthorizationFailure: Error, Sendable, Equatable, LocalizedError {
        case stateMismatch
        case denied(String)
        case missingCode

        public var errorDescription: String? {
            switch self {
            case .stateMismatch:
                return "The authorization redirect's state does not match this request; ignored."
            case .denied(let error):
                return "Google authorization was not granted (\(error))."
            case .missingCode:
                return "The authorization redirect carries no code."
            }
        }
    }

    /// RFC 7636 proof key: a random verifier and its S256 challenge.
    struct PKCE: Invariant, Sendable {
        public let verifier: Secret
        public let challenge: String

        /// A verifier of 43–128 unreserved characters.
        public init(_ raw: String) throws(InvarianceFailure) {
            try Invariance([
                .length.min(43),
                .length.max(128),
                .predicate(
                    where: { value in
                        value.unicodeScalars.allSatisfy { Self.unreserved.contains($0) }
                    },
                    on_failure: { _ in InvarianceViolation(VerifierFormatViolation()) }
                ),
            ]).require(raw)
            self.init(unchecked: raw)
        }

        private init(unchecked raw: String) {
            verifier = Secret(unchecked: raw)
            challenge = Google.base64URL(Data(SHA256.hash(data: Data(raw.utf8))))
        }

        /// 32 random bytes, which encode to 43 unreserved characters.
        public static func generate() -> Self {
            Self(unchecked: Google.base64URL(Google.randomBytes(32)))
        }

        private static let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
    }

    /// One browser authorization: the URL to open, and the check of the
    /// redirect that comes back to `redirectURI`.
    struct AuthorizationRequest: Sendable {
        public let client: OAuthClient
        public let scopes: Set<Scope>
        public let redirectURI: URL
        public let state: String
        public let pkce: PKCE
        public let forceConsent: Bool

        /// `forceConsent` asks Google to show consent and issue a new refresh
        /// token; needed when none is stored or scopes are added. State and
        /// PKCE are generated unless given (tests).
        public init(
            client: OAuthClient,
            scopes: Set<Scope>,
            redirectURI: URL,
            forceConsent: Bool,
            state: String? = nil,
            pkce: PKCE? = nil
        ) {
            self.client = client
            self.scopes = scopes.union([.openid, .email])
            self.redirectURI = redirectURI
            self.forceConsent = forceConsent
            self.state = state ?? Google.base64URL(Google.randomBytes(24))
            self.pkce = pkce ?? .generate()
        }

        public var url: URL {
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            var items: [URLQueryItem] = [
                .init(name: "client_id", value: client.clientID),
                .init(name: "redirect_uri", value: redirectURI.absoluteString),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scopes.sorted().map(\.raw).joined(separator: " ")),
                .init(name: "access_type", value: "offline"),
                .init(name: "include_granted_scopes", value: "true"),
                .init(name: "state", value: state),
                .init(name: "code_challenge", value: pkce.challenge),
                .init(name: "code_challenge_method", value: "S256"),
            ]
            if forceConsent {
                items.append(.init(name: "prompt", value: "consent"))
            }
            components.queryItems = items
            return components.url!
        }

        /// The authorization code from the redirect, once its state matches.
        public func code(fromRedirect url: URL) throws(AuthorizationFailure) -> Secret {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            guard value("state") == state else {
                throw .stateMismatch
            }
            if let error = value("error") {
                throw .denied(error)
            }
            guard let code = value("code"), let secret = try? Secret(code) else {
                throw .missingCode
            }
            return secret
        }
    }

    /// A short-lived bearer token. Kept in memory only.
    struct AccessToken: Sendable {
        public let value: Secret
        public let expiresAt: Date
        public let scopes: Set<Scope>

        public init(value: Secret, expiresAt: Date, scopes: Set<Scope>) {
            self.value = value
            self.expiresAt = expiresAt
            self.scopes = scopes
        }
    }

    /// What a completed browser authorization yields.
    struct Grant: Sendable {
        public let user: AuthorizedUser
        public let accessToken: AccessToken
    }

    /// Google's OAuth 2.0 token and revocation endpoints.
    struct OAuth: Sendable {
        public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

        private let transport: Transport
        private let now: @Sendable () -> Date

        public init(transport: Transport = .live, now: @escaping @Sendable () -> Date = Date.init) {
            self.transport = transport
            self.now = now
        }

        /// Exchanges the redirect's code. Fails with `authorizationRequired
        /// (.no_refresh_token)` when Google returns no refresh token, which
        /// happens when consent was not forced for an existing grant.
        public func exchange(_ code: Secret, for request: AuthorizationRequest) async throws -> Grant {
            let response = try await token([
                ("grant_type", "authorization_code"),
                ("code", code.raw),
                ("client_id", request.client.clientID),
                ("client_secret", request.client.clientSecret.raw),
                ("redirect_uri", request.redirectURI.absoluteString),
                ("code_verifier", request.pkce.verifier.raw),
            ])
            guard let refresh = response.refresh_token, let refreshToken = try? Secret(refresh) else {
                throw Failure.authorizationRequired(.no_refresh_token)
            }
            let accessToken = try response.accessToken(issued: now(), fallbackScopes: request.scopes)
            let user = AuthorizedUser(
                client: request.client,
                refreshToken: refreshToken,
                scopes: accessToken.scopes,
                account: response.id_token.flatMap(Self.email)
            )
            return Grant(user: user, accessToken: accessToken)
        }

        /// A new access token from the refresh token. `rotated` is set when
        /// Google issued a replacement refresh token, which must be stored.
        public func refresh(_ user: AuthorizedUser) async throws -> (accessToken: AccessToken, rotated: AuthorizedUser?) {
            let response = try await token([
                ("grant_type", "refresh_token"),
                ("refresh_token", user.refreshToken.raw),
                ("client_id", user.client.clientID),
                ("client_secret", user.client.clientSecret.raw),
            ])
            let accessToken = try response.accessToken(issued: now(), fallbackScopes: user.scopes)
            var rotated: AuthorizedUser?
            if let replacement = response.refresh_token.flatMap({ try? Secret($0) }),
               replacement != user.refreshToken
            {
                rotated = AuthorizedUser(
                    client: user.client,
                    refreshToken: replacement,
                    scopes: user.scopes.isEmpty ? accessToken.scopes : user.scopes,
                    account: user.account
                )
            }
            return (accessToken, rotated)
        }

        /// Revokes the grant behind a refresh (or access) token.
        public func revoke(_ token: Secret) async throws {
            var request = URLRequest(url: Self.revokeURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(Google.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = Google.form([("token", token.raw)])
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.failure(from: data, status: response.statusCode)
            }
        }

        private func token(_ fields: [(String, String)]) async throws -> TokenResponse {
            var request = URLRequest(url: Self.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Google.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = Google.form(fields)
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.failure(from: data, status: response.statusCode)
            }
            do {
                return try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw Failure.invalidResponse
            }
        }

        static func failure(from data: Data, status: Int) -> Failure {
            struct OAuthError: Decodable {
                let error: String?
            }
            guard let error = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error else {
                return .api(httpStatus: status, status: nil, reason: nil, message: nil)
            }
            if error == "invalid_grant" {
                return .authorizationRequired(.revoked_or_expired)
            }
            return .oauth(error: error)
        }

        /// The `email` claim of an ID token received straight from Google's
        /// token endpoint over TLS, so its signature is not checked here.
        static func email(_ idToken: String) -> String? {
            struct Claims: Decodable {
                let email: String?
            }
            let parts = idToken.split(separator: ".")
            guard parts.count == 3, let payload = Google.base64URLDecoded(String(parts[1])) else {
                return nil
            }
            return (try? JSONDecoder().decode(Claims.self, from: payload))?.email
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String?
    let expires_in: Int?
    let refresh_token: String?
    let scope: String?
    let id_token: String?

    func accessToken(issued: Date, fallbackScopes: Set<Google.Scope>) throws -> Google.AccessToken {
        guard let token = access_token, let value = try? Google.Secret(token), let seconds = expires_in, seconds > 0 else {
            throw Google.Failure.invalidResponse
        }
        let granted = (scope ?? "")
            .split(separator: " ")
            .compactMap { try? Google.Scope(String($0)) }
        return .init(
            value: value,
            expiresAt: issued.addingTimeInterval(TimeInterval(seconds)),
            scopes: granted.isEmpty ? fallbackScopes : Set(granted)
        )
    }
}

private struct VerifierFormatViolation: InvarianceReason {
    let code: InvarianceCode = .custom("google.invalid_pkce_verifier")
    let message = "A PKCE verifier holds only ASCII letters, digits and - . _ ~."
}
