// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KMLinkNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KMLinkNative", targets: ["KMLinkNative"])
    ],
    targets: [
        .target(
            name: "KMLinkNativeCSCSI",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "KMLinkNative",
            dependencies: ["KMLinkNativeCSCSI"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
