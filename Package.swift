// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dropwheel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dropwheel",
            path: "Sources/Dropwheel",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
