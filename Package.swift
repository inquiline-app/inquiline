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
        // Game controllers: SDL 3, static, only its controller parts, built by Scripts/build-sdl.sh
        // into .build/sdl.
        .target(
            name: "CSDL",
            path: "Sources/CSDL",
            cSettings: [.headerSearchPath("../../.build/sdl/include")]
        ),
        .executableTarget(
            name: "Inquiline",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CDataChannel", "CSDL"],
            path: "Sources/Inquiline",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(Context.packageDirectory)/.build/webrtc/include",
                                           "-Xcc", "-I\(Context.packageDirectory)/.build/sdl/include"])],
            // Weak: the apps' own bundles run this same program without Sparkle inside, and
            // only Inquiline itself uses it.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-weak_framework", "-Xlinker", "Sparkle",
                                           "-L\(Context.packageDirectory)/.build/webrtc/lib",
                                           "-L\(Context.packageDirectory)/.build/sdl/lib"]),
                             .linkedLibrary("datachannel"), .linkedLibrary("juice"), .linkedLibrary("usrsctp"), .linkedLibrary("srtp2"),
                             .linkedLibrary("mbedtls"), .linkedLibrary("mbedx509"), .linkedLibrary("mbedcrypto"),
                             .linkedLibrary("everest"), .linkedLibrary("p256m"), .linkedLibrary("c++"),
                             .linkedLibrary("SDL3"), .linkedFramework("IOKit"), .linkedFramework("ForceFeedback"),
                             .linkedFramework("GameController"), .linkedFramework("CoreHaptics"), .linkedFramework("Carbon"),
                             .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"), .linkedFramework("UniformTypeIdentifiers")]
        )
    ]
)
