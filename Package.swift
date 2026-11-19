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
        // WebRTC data channels for the phone remote: libdatachannel over mbedTLS, static, built by
        // Scripts/build-webrtc.sh into .build/webrtc.
        .target(
            name: "CDataChannel",
            path: "Sources/CDataChannel",
            cSettings: [.headerSearchPath("../../.build/webrtc/include")]
        ),
        .executableTarget(
            name: "Inquiline",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CDataChannel"],
            path: "Sources/Inquiline",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(Context.packageDirectory)/.build/webrtc/include"])],
            // Weak: the apps' own bundles run this same program without Sparkle inside, and
            // only Inquiline itself uses it.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-weak_framework", "-Xlinker", "Sparkle",
                                           "-L\(Context.packageDirectory)/.build/webrtc/lib"]),
                             .linkedLibrary("datachannel"), .linkedLibrary("juice"), .linkedLibrary("usrsctp"),
                             .linkedLibrary("mbedtls"), .linkedLibrary("mbedx509"), .linkedLibrary("mbedcrypto"),
                             .linkedLibrary("everest"), .linkedLibrary("p256m"), .linkedLibrary("c++")]
        )
    ]
)
