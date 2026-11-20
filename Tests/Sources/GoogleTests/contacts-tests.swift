import Foundation
import Google
import GoogleContacts
import Testing

enum ContactsTests {
    static func parse() throws {
        try Expect.equal(try GoogleContacts.ContactName("people/c123").raw, "people/c123", "Contact name")
        try Expect.throwsError("Wrong prefix") { _ = try GoogleContacts.ContactName("contactGroups/abc") }
        try Expect.throwsError("Path injection") { _ = try GoogleContacts.ContactName("people/c1/../x") }
        try Expect.equal(GoogleContacts.GroupName.myContacts.raw, "contactGroups/myContacts", "System group")
    }

    /// A small in-memory People API: connections, create, update, groups.
    actor Book {
        var people: [String: String] = [:]
        var next = 1

        func handle(_ request: URLRequest) throws -> (Int, String, [String: String]) {
            let path = request.url?.path ?? ""
            let body = Fixtures.body(request).replacingOccurrences(of: "\\/", with: "/")
            switch (request.httpMethod ?? "GET", path) {
            case (_, Fixtures.tokenPath):
                return (200, Fixtures.token(), [:])
            case ("GET", "/v1/people/me/connections"):
                return (200, #"{"connections":[\#(people.values.sorted().joined(separator: ","))]}"#, [:])
            case ("POST", "/v1/people:createContact"):
                let name = "people/c\(next)"
                next += 1
                people[name] = stored(body, name: name, etag: "e1")
                return (200, people[name]!, [:])
            case ("POST", "/v1/contactGroups/leads/members:modify"):
                for name in people.keys where body.contains(name) {
                    people[name] = people[name]!.replacingOccurrences(
                        of: #""memberships":[]"#,
                        with: #""memberships":[{"contactGroupMembership":{"contactGroupResourceName":"contactGroups/leads"}}]"#
                    )
                }
                return (200, "{}", [:])
            default:
                if path.hasSuffix(":updateContact") {
                    let name = String(path.dropFirst("/v1/".count).dropLast(":updateContact".count))
                    guard people[name] != nil, body.contains(#""etag":"e1""#) else {
                        return (400, #"{"error":{"status":"FAILED_PRECONDITION"}}"#, [:])
                    }
                    people[name] = stored(body, name: name, etag: "e2")
                    return (200, people[name]!, [:])
                }
                if path.hasPrefix("/v1/people/"), let person = people[String(path.dropFirst("/v1/".count))] {
                    return (200, person, [:])
                }
                return (404, #"{"error":{"status":"NOT_FOUND"}}"#, [:])
            }
        }

        /// The request body with server fields set, as Google echoes it.
        private func stored(_ body: String, name: String, etag: String) -> String {
            var object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
            object["resourceName"] = name
            object["etag"] = etag
            if object["memberships"] == nil {
                object["memberships"] = [Any]()
            }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func upsert() async throws {
        let book = Book()
        let server = FixtureServer { request, _ in
            try await book.handle(request)
        }
        let contacts = GoogleContacts.Client(try ClientTests.client(server))
        let sysid = GoogleContacts.ExternalID(type: "sysid", value: "SYS-1")
        let leads = try GoogleContacts.GroupName("contactGroups/leads")
        let draft = GoogleContacts.ContactDraft(
            givenName: "Client",
            familyName: "A",
            emails: [.init(label: "home", value: "client.a@example.org")]
        )

        let created = try await contacts.upsert(draft, matching: sysid, group: leads)
        try Expect.equal(created.action, .created, "First upsert creates")
        try Expect.true(created.contact.externalIDs.contains(sysid), "Sysid stored")
        try Expect.equal(created.contact.groups, [leads], "Added to group")

        let again = try await contacts.upsert(draft, matching: sysid, group: leads)
        try Expect.equal(again.action, .unchanged, "Same draft changes nothing")
        try Expect.equal(again.contact.name, created.contact.name, "Same contact")

        let moved = GoogleContacts.ContactDraft(
            givenName: "Client",
            familyName: "A",
            emails: [.init(label: "home", value: "client.a@example.org")],
            phones: [.init(label: "mobile", value: "+31600000000")]
        )
        let updated = try await contacts.upsert(moved, matching: sysid, known: created.contact.name)
        try Expect.equal(updated.action, .updated, "Changed draft updates")
        try Expect.equal(updated.contact.phones.map(\.value), ["+31600000000"], "Phone written")
        try Expect.equal(await book.people.count, 1, "Still one contact")
    }
}
