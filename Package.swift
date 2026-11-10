// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inquiline",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates: "Check for Updates…", and the appcast on GitHub Releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Inquiline",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Inquiline",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
