// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-jsonschema-generator",
    platforms: [.macOS(.v15)],
    products: [
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
        .executableTarget(
            name: "JSONSchemaToSwiftGenerator"
        ),
        .plugin(
            name: "JSONSchemaToSwiftPlugin",
            capability: .buildTool(),
            dependencies: ["JSONSchemaToSwiftGenerator"]
        ),
    ]
)
