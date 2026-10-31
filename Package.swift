// swift-tools-version:5.9
// For editor indexing only. Build and test the app with ManualCameraApp.xcodeproj
// (regenerate it with `python3 tools/generate_xcodeproj.py`).
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
            path: "Sources",
            exclude: ["Pipeline/Shaders.metal"]
        )
    ]
)
