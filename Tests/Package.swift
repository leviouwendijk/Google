// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GoogleTests",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "t_google", targets: ["GoogleTests"]),
        .executable(name: "t_google_live", targets: ["GoogleLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-lco/Milieu.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Primitives.git", branch: "master"),
        .package(url: "https://github.com/swift-tooling/Testing.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "GoogleTests",
            dependencies: [
                .product(name: "Google", package: "Google"),
                .product(name: "GoogleContacts", package: "Google"),
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Testing", package: "Testing"),
            ]
        ),
        .executableTarget(
            name: "GoogleLive",
            dependencies: [
                .product(name: "Google", package: "Google"),
                .product(name: "GoogleContacts", package: "Google"),
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Testing", package: "Testing"),
            ]
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
