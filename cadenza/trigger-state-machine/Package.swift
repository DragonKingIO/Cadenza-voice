// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TriggerStateMachine",
    platforms: [.macOS("26.0")],
    products: [.library(name: "TriggerCore", targets: ["TriggerCore"])],
    targets: [
        .target(name: "TriggerCore"),
        .testTarget(name: "TriggerCoreTests", dependencies: ["TriggerCore"])
    ]
)
