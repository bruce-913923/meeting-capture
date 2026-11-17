// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingCapture",
            path: "Sources/MeetingCapture"
        )
    ]
)
