import Foundation
import PackagePlugin

@main
struct JSONSchemaToSwiftPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        let fileManager = FileManager.default
        let targetDirectory = sourceTarget.directoryURL
        let configURL = targetDirectory.appending(path: "jsonschema-generator-config.json")
        let configPath = configURL.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: configPath) else {
            return []
        }

        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(PluginConfiguration.self, from: data)

        let schemaURL: URL
        if URL(fileURLWithPath: config.schema).path.hasPrefix("/") {
            schemaURL = URL(fileURLWithPath: config.schema)
        } else {
            schemaURL = targetDirectory.appending(path: config.schema)
        }

        let outputDirectory = context.pluginWorkDirectoryURL.appending(path: sourceTarget.name)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let outputFileName = config.outputFile ?? "GeneratedJSONSchemaModels.swift"
        let outputURL = outputDirectory.appending(path: outputFileName)

        let generator = try context.tool(named: "swift-jsonschema-generator")

        return [
            .buildCommand(
                displayName: "Generating Swift models from \(schemaURL.lastPathComponent)",
                executable: generator.url,
                arguments: [
                    "--config", configPath,
                    "--target-dir", targetDirectory.path(percentEncoded: false),
                    "--output", outputURL.path(percentEncoded: false),
                ],
                environment: [:],
                inputFiles: [
                    configURL,
                    schemaURL,
                ],
                outputFiles: [
                    outputURL,
                ]
            )
        ]
    }
}

private struct PluginConfiguration: Decodable {
    let schema: String
    let outputFile: String?
}
