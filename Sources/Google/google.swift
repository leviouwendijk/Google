import Foundation
import Primitives
import Sensitivity
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Google {}

public extension Google {
    /// Secret text from or for Google: client secrets, refresh and access
    /// tokens, authorization codes. Never printed.
    struct Secret: Invariant, Sendable, Hashable, Sensitivity.Redacted {
        public static let redactedLabel = "Google credential"

        public let raw: String

        public init(_ raw: String) throws(InvarianceFailure) {
            try Invariance([.text.nonblank]).require(raw)
            self.raw = raw
        }

        init(unchecked raw: String) {
            self.raw = raw
        }
    }

    /// Unpadded base64url, as PKCE, state values and JWTs use.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    enum AuthorizationRequiredReason: String, Sendable, Equatable {
        /// No refresh token is stored for the profile.
        case no_grant
        /// Google answered `invalid_grant`: revoked, expired or replaced.
        case revoked_or_expired
        /// Google did not return a refresh token at authorization.
        case no_refresh_token
    }

    enum Failure: Error, Sendable, Equatable, LocalizedError {
        case authorizationRequired(AuthorizationRequiredReason)
        case insufficientScope(missing: [Scope])
        case oauth(error: String)
        case permissionDenied(reason: String?)
        case notFound
        case failedPrecondition(reason: String?)
        case rateLimited(retryAfterSeconds: Int?)
        case api(httpStatus: Int, status: String?, reason: String?, message: String?)
        case incompletePagination
        case invalidResponse
        case invalidTransportResponse

        public var errorDescription: String? {
            switch self {
            case .authorizationRequired(let reason):
                return "Google authorization required (\(reason.rawValue)). Run `google authorize` for this profile."
            case .insufficientScope(let missing):
                return "The Google grant lacks scopes: \(missing.map(\.raw).joined(separator: ", ")). Run `google authorize` with them."
            case .oauth(let error):
                return "Google OAuth error: \(error)."
            case .permissionDenied(let reason):
                return "Google denied permission\(reason.map { " (\($0))" } ?? "")."
            case .notFound:
                return "Google reports the resource does not exist."
            case .failedPrecondition(let reason):
                return "Google rejected the request's precondition\(reason.map { " (\($0))" } ?? ""); the resource may have changed."
            case .rateLimited(let seconds):
                return "Google rate limit reached\(seconds.map { "; retry after \($0) s" } ?? "")."
            case .api(let httpStatus, let status, let reason, let message):
                let detail = [status, reason, message].compactMap { $0 }.joined(separator: ", ")
                return "Google API error: HTTP \(httpStatus)\(detail.isEmpty ? "" : " (\(detail))")."
            case .incompletePagination:
                return "Google pagination did not finish; the result would be incomplete."
            case .invalidResponse:
                return "Google returned a response the SDK cannot use."
            case .invalidTransportResponse:
                return "The transport returned a non-HTTP response."
            }
        }
    }

    /// Sends one request. Tests replace it with fixtures.
    struct Transport: Sendable {
        public let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

        public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
            self.send = send
        }

        public static let live = Self { request in
            let (data, response) = try await VerifiedSession.client.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw Failure.invalidTransportResponse
            }
            return (data, response)
        }
    }

    /// One page of a listing, with the token for the next one.
    struct Page<Element: Sendable>: Sendable {
        public let items: [Element]
        public let nextPageToken: String?

        public init(items: [Element], nextPageToken: String?) {
            self.items = items
            self.nextPageToken = nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Follows page tokens to the end. Throws instead of returning a partial
    /// list when a token repeats or the page limit is reached.
    static func all<Element: Sendable>(
        maximumPages: Int = 1_000,
        isolation: isolated (any Actor)? = #isolation,
        _ fetch: (String?) async throws -> Page<Element>
    ) async throws -> [Element] {
        var items: [Element] = []
        var token: String?
        var seen: Set<String> = []
        for _ in 0..<maximumPages {
            let page = try await fetch(token)
            items += page.items
            guard let next = page.nextPageToken else {
                return items
            }
            guard seen.insert(next).inserted else {
                throw Failure.incompletePagination
            }
            token = next
        }
        throw Failure.incompletePagination
    }
}

extension Google {
    static let userAgent = "GoogleSwiftSDK/0.1"

    /// `application/x-www-form-urlencoded` body, as the OAuth endpoints take.
    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(encoded)"
        }
        .joined(separator: "&")
        return Data(body.utf8)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }
}

private enum VerifiedSession {
    static let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: BlockRedirects(), delegateQueue: nil)
    }()
}

private final class BlockRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
