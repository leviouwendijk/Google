import Foundation
import Google
import Primitives

public enum GoogleContacts {}

public extension GoogleContacts {
    /// `people/c…`: a contact in the user's address book.
    struct ContactName: CodableInvariant, Sendable, Hashable {
        public let raw: String

        public init(_ raw: String) throws(InvarianceFailure) {
            try Invariance([GoogleContacts.resourceRule(prefix: "people/")]).require(raw)
            self.raw = raw
        }
    }

    /// `contactGroups/…`: a label, including system groups such as
    /// `contactGroups/myContacts`.
    struct GroupName: CodableInvariant, Sendable, Hashable {
        public let raw: String

        public init(_ raw: String) throws(InvarianceFailure) {
            try Invariance([GoogleContacts.resourceRule(prefix: "contactGroups/")]).require(raw)
            self.raw = raw
        }

        private init(unchecked: String) { raw = unchecked }

        public static let myContacts = Self(unchecked: "contactGroups/myContacts")
    }

    /// An email address or phone number with Google's type ("home", "work",
    /// "mobile", or a custom label).
    struct LabeledValue: Codable, Sendable, Hashable {
        public let label: String?
        public let value: String

        public init(label: String? = nil, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// An identifier from another system, such as a sysid. Google keeps it
    /// on the contact but does not search by it.
    struct ExternalID: Codable, Sendable, Hashable {
        public let type: String
        public let value: String

        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    struct Contact: Sendable, Hashable {
        public let name: ContactName
        /// Required by updates; a stale etag fails with `failedPrecondition`.
        public let etag: String?
        public let givenName: String?
        public let familyName: String?
        public let displayName: String?
        public let emails: [LabeledValue]
        public let phones: [LabeledValue]
        public let organization: String?
        public let externalIDs: [ExternalID]
        public let groups: [GroupName]
    }

    /// The fields this SDK writes. An update replaces each of these fields
    /// as a whole and leaves every other field (notes, addresses, photos) as
    /// it is.
    struct ContactDraft: Codable, Sendable, Hashable {
        public let givenName: String
        public let familyName: String?
        public let emails: [LabeledValue]
        public let phones: [LabeledValue]
        public let organization: String?
        public let externalIDs: [ExternalID]

        public init(
            givenName: String,
            familyName: String? = nil,
            emails: [LabeledValue] = [],
            phones: [LabeledValue] = [],
            organization: String? = nil,
            externalIDs: [ExternalID] = []
        ) {
            self.givenName = givenName
            self.familyName = familyName
            self.emails = emails
            self.phones = phones
            self.organization = organization
            self.externalIDs = externalIDs
        }

        /// Whether `contact` already holds exactly these values.
        public func matches(_ contact: Contact) -> Bool {
            contact.givenName == givenName
                && contact.familyName == familyName
                && contact.emails.map(\.value) == emails.map(\.value)
                && contact.phones.map(\.value) == phones.map(\.value)
                && contact.organization == organization
                && Set(contact.externalIDs) == Set(externalIDs)
        }
    }

    struct Group: Sendable, Hashable {
        public let name: GroupName
        public let title: String
        public let isSystem: Bool
        public let memberCount: Int
    }

    enum UpsertAction: String, Sendable {
        case created
        case updated
        case unchanged
    }

    struct UpsertResult: Sendable {
        public let contact: Contact
        public let action: UpsertAction
    }
}

extension GoogleContacts {
    static func resourceRule(prefix: String) -> InvarianceRule<String> {
        .predicate(
            where: { value in
                let id = value.dropFirst(prefix.count)
                return value.hasPrefix(prefix)
                    && !id.isEmpty
                    && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            },
            on_failure: { _ in InvarianceViolation(ResourceNameViolation(prefix: prefix)) }
        )
    }
}

private struct ResourceNameViolation: InvarianceReason {
    let prefix: String
    var code: InvarianceCode { .custom("google.contacts.invalid_resource_name") }
    var message: String { "Expected \(prefix) followed by letters and digits." }
}

/// People API `Person`, limited to the fields read and written here.
struct Person: Codable, Sendable {
    struct Name: Codable, Sendable {
        var givenName: String?
        var familyName: String?
        var displayName: String?
    }

    struct Typed: Codable, Sendable {
        var value: String?
        var type: String?
    }

    struct Organization: Codable, Sendable {
        var name: String?
    }

    struct Membership: Codable, Sendable {
        struct Group: Codable, Sendable {
            var contactGroupResourceName: String?
        }

        var contactGroupMembership: Group?
    }

    var resourceName: String?
    var etag: String?
    var names: [Name]?
    var emailAddresses: [Typed]?
    var phoneNumbers: [Typed]?
    var organizations: [Organization]?
    var externalIds: [Typed]?
    var memberships: [Membership]?

    static let readFields = "names,emailAddresses,phoneNumbers,organizations,externalIds,memberships"
    static let writtenFields = "names,emailAddresses,phoneNumbers,organizations,externalIds"

    init(_ draft: GoogleContacts.ContactDraft, name: GoogleContacts.ContactName? = nil, etag: String? = nil) {
        resourceName = name?.raw
        self.etag = etag
        names = [Name(givenName: draft.givenName, familyName: draft.familyName, displayName: nil)]
        emailAddresses = draft.emails.map { Typed(value: $0.value, type: $0.label) }
        phoneNumbers = draft.phones.map { Typed(value: $0.value, type: $0.label) }
        organizations = draft.organization.map { [Organization(name: $0)] } ?? []
        externalIds = draft.externalIDs.map { Typed(value: $0.value, type: $0.type) }
    }

    func contact() throws -> GoogleContacts.Contact {
        guard let resourceName, let name = try? GoogleContacts.ContactName(resourceName) else {
            throw Google.Failure.invalidResponse
        }
        let primary = names?.first
        return .init(
            name: name,
            etag: etag,
            givenName: primary?.givenName,
            familyName: primary?.familyName,
            displayName: primary?.displayName,
            emails: (emailAddresses ?? []).compactMap { item in
                item.value.map { GoogleContacts.LabeledValue(label: item.type, value: $0) }
            },
            phones: (phoneNumbers ?? []).compactMap { item in
                item.value.map { GoogleContacts.LabeledValue(label: item.type, value: $0) }
            },
            organization: organizations?.first?.name,
            externalIDs: (externalIds ?? []).compactMap { item in
                guard let value = item.value else { return nil }
                return GoogleContacts.ExternalID(type: item.type ?? "", value: value)
            },
            groups: (memberships ?? []).compactMap { membership in
                membership.contactGroupMembership?.contactGroupResourceName.flatMap { try? GoogleContacts.GroupName($0) }
            }
        )
    }
}
