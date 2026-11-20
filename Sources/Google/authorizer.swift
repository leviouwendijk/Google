import Foundation

public extension Google {
    /// Access tokens for one authorized user, refreshed on demand.
    ///
    /// A token is reused until a minute before it expires; concurrent callers
    /// share one refresh. Required scopes are checked against the recorded
    /// grant before any request. A rotated refresh token is handed to
    /// `onRotation` to store.
    actor Authorizer {
        public static let expirySkew: TimeInterval = 60

        private var user: AuthorizedUser
        private let oauth: OAuth
        private let now: @Sendable () -> Date
        private let onRotation: (@Sendable (AuthorizedUser) async -> Void)?

        private var current: AccessToken?
        private var refreshing: Task<AccessToken, any Error>?

        public init(
            user: AuthorizedUser,
            oauth: OAuth = .init(),
            now: @escaping @Sendable () -> Date = Date.init,
            onRotation: (@Sendable (AuthorizedUser) async -> Void)? = nil
        ) {
            self.user = user
            self.oauth = oauth
            self.now = now
            self.onRotation = onRotation
        }

        public var account: String? { user.account }

        public func accessToken(for scopes: Set<Scope>) async throws -> AccessToken {
            if !user.scopes.isEmpty {
                let missing = Scope.missing(scopes, from: user.scopes)
                guard missing.isEmpty else {
                    throw Failure.insufficientScope(missing: missing)
                }
            }
            let token = try await validToken()
            let missing = Scope.missing(scopes, from: token.scopes)
            guard missing.isEmpty else {
                throw Failure.insufficientScope(missing: missing)
            }
            return token
        }

        /// Drops a token Google rejected, so the next call refreshes.
        public func invalidate(_ token: AccessToken) {
            if current?.value == token.value {
                current = nil
            }
        }

        private func validToken() async throws -> AccessToken {
            if let current, current.expiresAt.timeIntervalSince(now()) > Self.expirySkew {
                return current
            }
            if let refreshing {
                return try await refreshing.value
            }
            let task = Task { [oauth, user] in
                try await oauth.refresh(user)
            }
            let shared = Task {
                try await task.value.accessToken
            }
            refreshing = shared
            defer { refreshing = nil }
            let (token, rotated) = try await task.value
            if let rotated {
                user = rotated
                await onRotation?(rotated)
            }
            current = token
            return token
        }
    }
}
