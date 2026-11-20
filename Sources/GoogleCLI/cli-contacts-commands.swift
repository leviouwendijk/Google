import Arguments
import Foundation
import Google
import GoogleContacts

enum ContactsCommand: ArgumentCommand {
    static let name = "contacts"

    static var children: [ArgumentCommandType] {
        [
            ContactsGroupsCommand.self,
            ContactsSearchCommand.self,
            ContactsUpsertCommand.self,
        ]
    }

    static func components() throws -> [CommandComponentLowerable] {
        [about("The profile's Google Contacts, as Gmail and synced apps (Apple Contacts) show them.")]
    }
}

private func contactsClient(_ invocation: ParsedInvocation) async throws -> GoogleContacts.Client {
    let profile = try Profile(invocation)
    return GoogleContacts.Client(profile.client(try await profile.authorizer()))
}

private func row(_ contact: GoogleContacts.Contact) -> [String] {
    [
        contact.displayName ?? [contact.givenName, contact.familyName].compactMap { $0 }.joined(separator: " "),
        contact.emails.map(\.value).joined(separator: ", "),
        contact.phones.map(\.value).joined(separator: ", "),
        contact.externalIDs.map { "\($0.type)=\($0.value)" }.joined(separator: ", "),
        contact.name.raw,
    ]
}

enum ContactsGroupsCommand: RunnableArgumentCommand {
    static let name = "groups"

    static func components() throws -> [CommandComponentLowerable] {
        [about("List contact groups (labels).")] + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let groups = try await contactsClient(invocation).groups()
        printTable(
            ["TITLE", "MEMBERS", "KIND", "NAME"],
            groups.sorted { $0.title < $1.title }.map {
                [$0.title, String($0.memberCount), $0.isSystem ? "system" : "user", $0.name.raw]
            }
        )
    }
}

enum ContactsSearchCommand: RunnableArgumentCommand {
    static let name = "search"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Search contacts by name, email, phone or organization prefix."),
            arg("text", as: String.self, help: "What to search for."),
        ] + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let text = try invocation.require("text", as: String.self)
        let contacts = try await contactsClient(invocation).search(text)
        printTable(["NAME", "EMAIL", "PHONE", "EXTERNAL", "RESOURCE"], contacts.map(row))
    }
}

enum ContactsUpsertCommand: RunnableArgumentCommand {
    static let name = "upsert"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Create or update the contact carrying an external id (such as a sysid). Writes names, emails, phones, organization and external ids; leaves other fields alone."),
            opt("external-id", as: String.self, arity: .required, help: "type=value, e.g. sysid=1234."),
            opt("given", as: String.self, arity: .required, help: "Given name."),
            opt("family", as: String.self, help: "Family name."),
            opt("email", as: String.self, take: .repeating, help: "Email, optionally label=address. Repeatable."),
            opt("phone", as: String.self, take: .repeating, help: "Phone, optionally label=number. Repeatable."),
            opt("organization", as: String.self, help: "Organization."),
            opt("group", as: String.self, help: "Group title to add the contact to; created when missing."),
            opt("known", as: String.self, help: "The contact's people/… name, when stored, to skip the scan."),
        ] + CLIOptions.profile()
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let rawID = try invocation.require("external-id", as: String.self)
        let idParts = rawID.split(separator: "=", maxSplits: 1).map(String.init)
        guard idParts.count == 2, !idParts[0].isEmpty, !idParts[1].isEmpty else {
            throw CLIFailure.invalidExternalID(rawID)
        }
        let id = GoogleContacts.ExternalID(type: idParts[0], value: idParts[1])

        func labeled(_ values: [String]) -> [GoogleContacts.LabeledValue] {
            values.map { value in
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? .init(label: parts[0], value: parts[1]) : .init(value: value)
            }
        }
        let draft = GoogleContacts.ContactDraft(
            givenName: try invocation.require("given", as: String.self),
            familyName: try invocation.value("family", as: String.self),
            emails: labeled(try invocation.values("email", as: String.self)),
            phones: labeled(try invocation.values("phone", as: String.self)),
            organization: try invocation.value("organization", as: String.self)
        )

        let contacts = try await contactsClient(invocation)
        var group: GoogleContacts.GroupName?
        if let title = try invocation.value("group", as: String.self) {
            group = try await contacts.group(titled: title).name
        }
        let known = try invocation.value("known", as: String.self).map { try GoogleContacts.ContactName($0) }
        let result = try await contacts.upsert(draft, matching: id, known: known, group: group)
        print("\(result.action.rawValue): \(result.contact.name.raw)")
        printTable(["NAME", "EMAIL", "PHONE", "EXTERNAL", "RESOURCE"], [row(result.contact)])
    }
}
