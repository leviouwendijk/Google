import Arguments

@main
enum GoogleCLI {
    static func main() async {
        await GoogleCommand.main()
    }
}

enum GoogleCommand: ArgumentCommand {
    static let name = "google"

    static var children: [ArgumentCommandType] {
        [
            ClientCommand.self,
            AuthorizeCommand.self,
            StatusCommand.self,
            RevokeCommand.self,
            ContactsCommand.self,
        ]
    }

    static func components() throws -> [CommandComponentLowerable] {
        [
            about(
                "Google APIs for one profile. Import a Desktop OAuth client once (`client import`), authorize once in the browser (`authorize`), then every command runs without a browser. Credentials are kept in the Keychain (service `google`)."
            ),
        ]
    }
}
