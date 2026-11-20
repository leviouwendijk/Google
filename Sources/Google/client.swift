import Foundation
import HTTP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension Google {
    /// One API call, as a product target describes it.
    struct Request: Sendable {
        public let method: HTTPMethod
        public let url: URL
        public let body: Data?
        public let scopes: Set<Scope>
        /// Safe to send again after a rate limit or outage. Reads are;
        /// writes are not unless the product says so.
        public let idempotent: Bool

        public init(
            _ method: HTTPMethod,
            base: URL,
            path: String,
            query: [URLQueryItem] = [],
            body: Data? = nil,
            scopes: Set<Scope>,
            idempotent: Bool? = nil
        ) throws {
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw Failure.invalidResponse
            }
            let basePath = components.percentEncodedPath
            components.percentEncodedPath = basePath + path
            if !query.isEmpty {
                components.queryItems = query
            }
            guard let url = components.url else {
                throw Failure.invalidResponse
            }
            self.method = method
            self.url = url
            self.body = body
            self.scopes = scopes
            self.idempotent = idempotent ?? (method == .get)
        }
    }

    struct RetryPolicy: Sendable {
        public let attempts: Int
        public let baseDelay: Duration

        public init(attempts: Int = 3, baseDelay: Duration = .milliseconds(500)) {
            self.attempts = max(attempts, 1)
            self.baseDelay = baseDelay
        }
    }

    /// Sends product requests with a bearer token from the authorizer.
    struct Client: Sendable {
        public let authorizer: Authorizer
        private let transport: Transport
        private let retry: RetryPolicy
        private let sleep: @Sendable (Duration) async throws -> Void

        public init(
            authorizer: Authorizer,
            transport: Transport = .live,
            retry: RetryPolicy = .init(),
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.authorizer = authorizer
            self.transport = transport
            self.retry = retry
            self.sleep = sleep
        }

        public func send<T: Decodable & Sendable>(_ request: Request, as type: T.Type) async throws -> T {
            let data = try await send(request)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw Failure.invalidResponse
            }
        }

        /// Refreshes once on 401. Retries 429 and 5xx with backoff, honouring
        /// `Retry-After`, only for idempotent requests.
        @discardableResult
        public func send(_ request: Request) async throws -> Data {
            var refreshed = false
            var attempt = 1
            while true {
                let token = try await authorizer.accessToken(for: request.scopes)
                let (data, response) = try await transport.send(urlRequest(request, token: token))
                let status = response.statusCode
                if (200..<300).contains(status) {
                    return data
                }
                if status == 401, !refreshed {
                    refreshed = true
                    await authorizer.invalidate(token)
                    continue
                }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                if request.idempotent, status == 429 || status == 503 || status == 500, attempt < retry.attempts {
                    let backoff = retry.baseDelay * (1 << (attempt - 1))
                    let jitter = Duration.milliseconds(Int.random(in: 0...250))
                    try await sleep(retryAfter.map { .seconds($0) } ?? backoff + jitter)
                    attempt += 1
                    continue
                }
                throw Self.failure(from: data, status: status, retryAfter: retryAfter)
            }
        }

        private func urlRequest(_ request: Request, token: AccessToken) -> URLRequest {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.setValue("Bearer \(token.value.raw)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.setValue(Google.userAgent, forHTTPHeaderField: "User-Agent")
            if let body = request.body {
                urlRequest.httpBody = body
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return urlRequest
        }

        /// Maps Google's error envelope (`error.code`, `error.status`,
        /// `error.details[].reason`) to a failure.
        package static func failure(from data: Data, status: Int, retryAfter: Int?) -> Failure {
            let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
            let reason = error?.details?.lazy.compactMap(\.reason).first
            let message = error?.message.map { String($0.prefix(300)) }
            if reason == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" {
                return .insufficientScope(missing: [])
            }
            switch status {
            case 401:
                return .authorizationRequired(.revoked_or_expired)
            case 403:
                return .permissionDenied(reason: reason ?? message)
            case 404:
                return .notFound
            case 409, 412:
                return .failedPrecondition(reason: reason ?? message)
            case 429:
                return .rateLimited(retryAfterSeconds: retryAfter)
            default:
                if error?.status == "FAILED_PRECONDITION" {
                    return .failedPrecondition(reason: reason ?? message)
                }
                return .api(httpStatus: status, status: error?.status, reason: reason, message: message)
            }
        }

        private struct Envelope: Decodable {
            struct Body: Decodable {
                struct Detail: Decodable {
                    let reason: String?
                }

                let status: String?
                let message: String?
                let details: [Detail]?
            }

            let error: Body?
        }
    }
}
