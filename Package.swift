// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "DexDictateMontereyProbe",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "MontereyWhisperProbe", targets: ["MontereyWhisperProbe"])
    ],
    dependencies: [
        // This is the exact revision used by DexDictate_MacOS, not a newer substitute.
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", revision: "deb1cb6a27256c7b01f5d3d2e7dc1dcc330b5d01")
    ],
    targets: [
        .executableTarget(
            name: "MontereyWhisperProbe",
            dependencies: [.product(name: "SwiftWhisper", package: "SwiftWhisper")],
            linkerSettings: [.linkedFramework("AVFoundation")]
        )
    ]
)
