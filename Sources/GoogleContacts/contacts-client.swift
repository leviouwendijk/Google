import Foundation
import Google

public extension GoogleContacts {
    /// The People API over one user's address book. Contacts written here
    /// appear in Gmail and in every app syncing that account, including
    /// Apple Contacts.
    actor Client {
        public static let base = URL(string: "https://people.googleapis.com/v1")!

        private let google: Google.Client
        private var searchWarmed = false

        public init(_ google: Google.Client) {
            self.google = google
        }

        // MARK: Reading

        public func connections(pageToken: String? = nil, pageSize: Int = 1_000) async throws -> Google.Page<Contact> {
            var query: [URLQueryItem] = [
                .init(name: "personFields", value: Person.readFields),
                .init(name: "pageSize", value: String(min(max(pageSize, 1), 1_000))),
            ]
            if let pageToken {
                query.append(.init(name: "pageToken", value: pageToken))
            }
            let response = try await google.send(
                Google.Request(.get, base: Self.base, path: "/people/me/connections", query: query, scopes: [.contactsReadonly]),
                as: ConnectionsResponse.self
            )
            return .init(items: try (response.connections ?? []).map { try $0.contact() }, nextPageToken: response.nextPageToken)
        }

        /// Every contact, following all pages.
        public func allConnections() async throws -> [Contact] {
            try await Google.all { token in
                try await self.connections(pageToken: token)
            }
        }

        /// Matches names, nicknames, emails, phones and organizations by
        /// prefix. Google answers from a cache, so recent writes may be missing.
        public func search(_ text: String, limit: Int = 30) async throws -> [Contact] {
            if !searchWarmed {
                // Google asks for one empty query first to fill its cache.
                _ = try await searchRequest("", limit: 1)
                searchWarmed = true
            }
            return try await searchRequest(text, limit: limit)
        }

        public func contact(_ name: ContactName) async throws -> Contact {
            try await google.send(
                Google.Request(
                    .get,
                    base: Self.base,
                    path: "/\(name.raw)",
                    query: [.init(name: "personFields", value: Person.readFields)],
                    scopes: [.contactsReadonly]
                ),
                as: Person.self
            )
            .contact()
        }

        /// The contact carrying `id`, scanning the address book.
        public func contact(withExternalID id: ExternalID) async throws -> Contact? {
            try await allConnections().first { $0.externalIDs.contains(id) }
        }

        // MARK: Writing

        public func create(_ draft: ContactDraft) async throws -> Contact {
            try await google.send(
                Google.Request(
                    .post,
                    base: Self.base,
                    path: "/people:createContact",
                    query: [.init(name: "personFields", value: Person.readFields)],
                    body: try JSONEncoder().encode(Person(draft)),
                    scopes: [.contacts]
                ),
                as: Person.self
            )
            .contact()
        }

        /// Replaces the draft's fields on `contact`; other fields stay. Fails
        /// with `failedPrecondition` when the contact changed since it was read.
        public func update(_ contact: Contact, with draft: ContactDraft) async throws -> Contact {
            try await google.send(
                Google.Request(
                    .patch,
                    base: Self.base,
                    path: "/\(contact.name.raw):updateContact",
                    query: [
                        .init(name: "updatePersonFields", value: Person.writtenFields),
                        .init(name: "personFields", value: Person.readFields),
                    ],
                    body: try JSONEncoder().encode(Person(draft, name: contact.name, etag: contact.etag)),
                    scopes: [.contacts]
                ),
                as: Person.self
            )
            .contact()
        }

        /// Creates the contact for `id`, or brings the existing one up to
        /// date. `known` skips the scan when the caller stored the name; new
        /// contacts can take a moment to show up in the scan, so callers
        /// should keep the returned name. With `group`, the contact is also
        /// added to that group.
        public func upsert(
            _ draft: ContactDraft,
            matching id: ExternalID,
            known: ContactName? = nil,
            group: GroupName? = nil
        ) async throws -> UpsertResult {
            var draft = draft
            if !draft.externalIDs.contains(id) {
                draft = ContactDraft(
                    givenName: draft.givenName,
                    familyName: draft.familyName,
                    emails: draft.emails,
                    phones: draft.phones,
                    organization: draft.organization,
                    externalIDs: draft.externalIDs + [id]
                )
            }

            var existing: Contact?
            if let known {
                do {
                    existing = try await contact(known)
                } catch Google.Failure.notFound {
                    existing = nil
                }
            }
            if existing == nil {
                existing = try await contact(withExternalID: id)
            }

            var result: UpsertResult
            if let existing {
                result = draft.matches(existing)
                    ? .init(contact: existing, action: .unchanged)
                    : .init(contact: try await update(existing, with: draft), action: .updated)
            } else {
                result = .init(contact: try await create(draft), action: .created)
            }

            if let group, !result.contact.groups.contains(group) {
                try await add([result.contact.name], to: group)
                result = .init(contact: try await contact(result.contact.name), action: result.action)
            }
            return result
        }

        // MARK: Groups

        public func groups() async throws -> [Group] {
            try await Google.all { token in
                var query: [URLQueryItem] = [.init(name: "pageSize", value: "1000")]
                if let token {
                    query.append(.init(name: "pageToken", value: token))
                }
                let response = try await self.google.send(
                    Google.Request(.get, base: Self.base, path: "/contactGroups", query: query, scopes: [.contactsReadonly]),
                    as: GroupsResponse.self
                )
                return Google.Page(items: try (response.contactGroups ?? []).map { try $0.group() }, nextPageToken: response.nextPageToken)
            }
        }

        /// The user group titled `title`, created when missing.
        public func group(titled title: String) async throws -> Group {
            if let existing = try await groups().first(where: { !$0.isSystem && $0.title == title }) {
                return existing
            }
            struct Body: Encodable {
                struct Inner: Encodable {
                    let name: String
                }

                let contactGroup: Inner
            }
            return try await google.send(
                Google.Request(
                    .post,
                    base: Self.base,
                    path: "/contactGroups",
                    body: try JSONEncoder().encode(Body(contactGroup: .init(name: title))),
                    scopes: [.contacts]
                ),
                as: WireGroup.self
            )
            .group()
        }

        /// Adding a contact that is already a member changes nothing, so this
        /// is safe to repeat.
        public func add(_ contacts: [ContactName], to group: GroupName) async throws {
            struct Body: Encodable {
                let resourceNamesToAdd: [String]
            }
            try await google.send(
                Google.Request(
                    .post,
                    base: Self.base,
                    path: "/\(group.raw)/members:modify",
                    body: try JSONEncoder().encode(Body(resourceNamesToAdd: contacts.map(\.raw))),
                    scopes: [.contacts],
                    idempotent: true
                )
            )
        }

        private func searchRequest(_ text: String, limit: Int) async throws -> [Contact] {
            let response = try await google.send(
                Google.Request(
                    .get,
                    base: Self.base,
                    path: "/people:searchContacts",
                    query: [
                        .init(name: "query", value: text),
                        .init(name: "readMask", value: Person.readFields),
                        .init(name: "pageSize", value: String(min(max(limit, 1), 30))),
                    ],
                    scopes: [.contactsReadonly]
                ),
                as: SearchResponse.self
            )
            return try (response.results ?? []).compactMap(\.person).map { try $0.contact() }
        }
    }
}

private struct ConnectionsResponse: Decodable, Sendable {
    let connections: [Person]?
    let nextPageToken: String?
}

private struct SearchResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let person: Person?
    }

    let results: [Result]?
}

private struct GroupsResponse: Decodable, Sendable {
    let contactGroups: [WireGroup]?
    let nextPageToken: String?
}

private struct WireGroup: Decodable, Sendable {
    let resourceName: String?
    let name: String?
    let formattedName: String?
    let groupType: String?
    let memberCount: Int?

    func group() throws -> GoogleContacts.Group {
        guard let resourceName, let name = try? GoogleContacts.GroupName(resourceName) else {
            throw Google.Failure.invalidResponse
        }
        return .init(
            name: name,
            title: formattedName ?? self.name ?? resourceName,
            isSystem: groupType == "SYSTEM_CONTACT_GROUP",
            memberCount: memberCount ?? 0
        )
    }
}
