// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dish",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dish",
            path: "Sources/Dish"
        ),
        .testTarget(
            name: "DishTests",
            dependencies: ["Dish"],
            path: "Tests/DishTests"
        )
    ]
)
