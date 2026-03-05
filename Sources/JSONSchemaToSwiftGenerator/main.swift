import Foundation
import JSONSchemaToSwiftGeneratorCore

private func argumentValue(named option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments

guard let configPath = argumentValue(named: "--config", in: arguments),
      let targetDirectory = argumentValue(named: "--target-dir", in: arguments),
      let outputPath = argumentValue(named: "--output", in: arguments) else {
    fputs("Usage: swift-jsonschema-generator --config <config-path> --target-dir <target-dir> --output <output-path>\n", stderr)
    exit(1)
}

let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
let configuration = try JSONDecoder().decode(GeneratorConfiguration.self, from: configData)
let schemaURL = JSONSchemaToSwiftGenerator.resolveSchemaURL(
    configurationSchema: configuration.schema,
    relativeTo: targetDirectory
)

let generator = JSONSchemaToSwiftGenerator()
let output = try generator.generateOutput(
    schemaPath: schemaURL.path(percentEncoded: false),
    configuration: configuration
)

try output.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
