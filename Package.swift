// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ManualCameraApp",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "ManualCameraApp", targets: ["ManualCameraApp"])
    ],
    targets: [
        .target(
            name: "ManualCameraApp",
            path: "Sources"
        )
    ]
)
