// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Google",
    platforms: [.macOS(.v13)],
    products: [
        // credentials, OAuth, token cache, authorized transport
        .library(name: "Google", targets: ["Google"]),
        // People API: contacts and contact groups
        .library(name: "GoogleContacts", targets: ["GoogleContacts"]),
        .executable(name: "google", targets: ["GoogleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-lco/Primitives.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Sensitivity.git", branch: "master"),
        .package(url: "https://github.com/swift-webc/HTTP.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Milieu.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Readers.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Arguments.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "Google",
            dependencies: [
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Sensitivity", package: "Sensitivity"),
                .product(name: "HTTP", package: "HTTP"),
            ],
            path: "Sources/Google"
        ),
        .target(
            name: "GoogleContacts",
            dependencies: [
                "Google",
                .product(name: "Primitives", package: "Primitives"),
            ],
            path: "Sources/GoogleContacts"
        ),
        .executableTarget(
            name: "GoogleCLI",
            dependencies: [
                "Google",
                "GoogleContacts",
                .product(name: "Arguments", package: "Arguments"),
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Readers", package: "Readers"),
            ],
            path: "Sources/GoogleCLI"
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        settings.append(.unsafeFlags(["-continue-building-after-errors"]))
        target.swiftSettings = settings
    case .plugin, .system, .binary:
        break
    @unknown default:
        break
    }
}
