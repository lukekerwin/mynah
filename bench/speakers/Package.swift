// swift-tools-version:6.0
import PackageDescription

// Speaker-profile POC: diarizes meeting audio with FluidAudio and writes, per
// speaker found, two voiceprints (WeSpeaker centroid + CAM++). See README.md.
let package = Package(
    name: "SpeakerProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042"),
    ],
    targets: [
        .executableTarget(name: "SpeakerProbe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/SpeakerProbe"),
    ]
)
