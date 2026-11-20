import Foundation
import Primitives

public extension Google {
    /// An OAuth scope: a `https://www.googleapis.com/auth/…` URL, or one of
    /// the OpenID scopes `openid`, `email`, `profile`.
    struct Scope: CodableInvariant, Sendable, Hashable, Comparable {
        public let raw: String

        public init(_ raw: String) throws(InvarianceFailure) {
            try Invariance([
                .predicate(
                    where: { value in
                        Self.openID.contains(value)
                            || (value.hasPrefix(Self.prefix) && value.count > Self.prefix.count && !value.contains(" "))
                    },
                    on_failure: { _ in InvarianceViolation(ScopeFormatViolation()) }
                ),
            ]).require(raw)
            self.raw = raw
        }

        private init(unchecked: String) { raw = unchecked }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }

        private static let prefix = "https://www.googleapis.com/auth/"
        private static let openID: Set<String> = ["openid", "email", "profile"]

        public static let openid = Self(unchecked: "openid")
        public static let email = Self(unchecked: "email")
        public static let contacts = Self(unchecked: prefix + "contacts")
        public static let contactsReadonly = Self(unchecked: prefix + "contacts.readonly")
        public static let businessManage = Self(unchecked: prefix + "business.manage")
        public static let adwords = Self(unchecked: prefix + "adwords")
        public static let analyticsReadonly = Self(unchecked: prefix + "analytics.readonly")
        public static let analyticsEdit = Self(unchecked: prefix + "analytics.edit")
        public static let webmastersReadonly = Self(unchecked: prefix + "webmasters.readonly")

        /// Short names for the CLI: `contacts`, `business`, `ads`, …
        public static let named: [String: Self] = [
            "contacts": .contacts,
            "contacts.readonly": .contactsReadonly,
            "business": .businessManage,
            "ads": .adwords,
            "analytics": .analyticsReadonly,
            "analytics.edit": .analyticsEdit,
            "searchconsole": .webmastersReadonly,
        ]

        /// Whether a grant of this scope also allows `other`: a write scope
        /// covers its read-only variant.
        public func covers(_ other: Self) -> Bool {
            self == other || Self.implied[self]?.contains(other) == true
        }

        private static let implied: [Self: Set<Self>] = [
            .contacts: [.contactsReadonly],
            .analyticsEdit: [.analyticsReadonly],
        ]

        /// The required scopes no granted scope covers.
        public static func missing(_ required: Set<Self>, from granted: Set<Self>) -> [Self] {
            required
                .filter { needed in !granted.contains { $0.covers(needed) } }
                .sorted()
        }
    }
}

private struct ScopeFormatViolation: InvarianceReason {
    let code: InvarianceCode = .custom("google.invalid_scope")
    let message = "Expected an https://www.googleapis.com/auth/… scope or openid, email, profile."
}
