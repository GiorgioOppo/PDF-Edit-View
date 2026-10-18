// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CartaPDF",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CartaPDF", targets: ["CartaPDF"])],
    targets: [
        .executableTarget(name: "CartaPDF", path: "Sources/CartaPDF", resources: [.copy("Resources/PDFAProfiles"), .copy("Resources/PDFFontData"), .process("Resources/Localization")]),
        .testTarget(name: "CartaPDFTests", dependencies: ["CartaPDF"], path: "Tests/CartaPDFTests")
    ]
)
