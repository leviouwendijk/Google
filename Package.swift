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
        .executable(name: "t_google", targets: ["GoogleTests"]),
        .executable(name: "t_google_live", targets: ["GoogleLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Primitives.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Sensitivity.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/HTTP.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Milieu.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Readers.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Arguments.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master"),
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
        .executableTarget(
            name: "GoogleTests",
            dependencies: [
                "Google",
                "GoogleContacts",
                .product(name: "Testing", package: "Testing"),
            ],
            path: "Testing/GoogleTests"
        ),
        .executableTarget(
            name: "GoogleLive",
            dependencies: [
                "Google",
                "GoogleContacts",
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Testing", package: "Testing"),
            ],
            path: "Testing/GoogleLive"
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
