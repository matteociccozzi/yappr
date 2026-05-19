// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yappr-stt-daemon",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../vendor/FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "YapprSttDaemon",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/YapprSttDaemon"
        ),
        // Tiny socket client used by bin/yappr. Has no FluidAudio dep —
        // builds in <1 s, starts in ~5 ms vs python3's ~30-50 ms.
        .executableTarget(
            name: "YapprSttConnect",
            path: "Sources/YapprSttConnect"
        )
    ]
)
