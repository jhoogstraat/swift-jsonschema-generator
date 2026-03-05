// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-jsonschema-generator",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "JSONSchemaToSwiftGeneratorCore",
            targets: ["JSONSchemaToSwiftGeneratorCore"]
        ),
        .executable(
            name: "swift-jsonschema-generator",
            targets: ["JSONSchemaToSwiftGenerator"]
        ),
        .plugin(
            name: "JSONSchemaToSwiftPlugin",
            targets: ["JSONSchemaToSwiftPlugin"]
        ),
    ],
    targets: [
        .target(
            name: "JSONSchemaToSwiftGeneratorCore"
        ),
        .executableTarget(
            name: "JSONSchemaToSwiftGenerator",
            dependencies: ["JSONSchemaToSwiftGeneratorCore"]
        ),
        .testTarget(
            name: "JSONSchemaToSwiftGeneratorCoreTests",
            dependencies: ["JSONSchemaToSwiftGeneratorCore"]
        ),
        .plugin(
            name: "JSONSchemaToSwiftPlugin",
            capability: .buildTool(),
            dependencies: ["JSONSchemaToSwiftGenerator"]
        ),
    ]
)
