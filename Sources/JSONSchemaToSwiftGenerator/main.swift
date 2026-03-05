import Foundation

private let defaultRootTypeName = "JSONSchemaDocument"
private let defaultDefinitionTypePrefix = "JSONSchema"
private let defaultValueTypeName = "JSONSchemaValue"

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
    "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try"
]

private struct GeneratedProperty {
    let originalName: String
    let swiftName: String
    let swiftType: String
    let optional: Bool
    let accessLevel: String

    var declaration: String {
        "    \(accessLevel) let \(swiftName): \(swiftType)\(optional ? "?" : "")"
    }

    var needsCodingKey: Bool {
        originalName != swiftName
    }
}

struct GeneratorConfiguration: Decodable {
    let schema: String
    let rootTypeName: String?
    let definitionTypePrefix: String?
    let valueTypeName: String?
    let accessLevel: String?
    let outputFile: String?
}

enum GeneratorError: Error, LocalizedError {
    case invalidArguments
    case schemaRootNotObject

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: swift-jsonschema-generator --config <config-path> --target-dir <target-dir> --output <output-path>"
        case .schemaRootNotObject:
            return "JSON schema root must be an object"
        }
    }
}

private func argumentValue(named option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func loadJSONObject(from path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
        throw GeneratorError.schemaRootNotObject
    }
    return object
}

private func pascalCase(_ value: String) -> String {
    let pieces = value
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { part -> String in
            guard let first = part.first else { return "" }
            return String(first).uppercased() + part.dropFirst()
        }

    if pieces.isEmpty {
        return "Value"
    }

    return pieces.joined()
}

private func sanitizeSwiftIdentifier(_ raw: String) -> String {
    var identifier = raw.map { character -> Character in
        if character.isLetter || character.isNumber || character == "_" {
            return character
        }
        return "_"
    }

    if identifier.isEmpty {
        identifier = ["_"]
    }

    if let first = identifier.first, first.isNumber {
        identifier.insert("_", at: identifier.startIndex)
    }

    let name = String(identifier)
    if swiftKeywords.contains(name) {
        return "\(name)_"
    }
    return name
}

private func propertyTypeContainsNull(_ schema: [String: Any]) -> Bool {
    guard let type = schema["type"] as? [Any] else {
        return false
    }
    return type.contains { ($0 as? String) == "null" }
}

private func definitionName(fromRef ref: String) -> String? {
    let prefix = "#/definitions/"
    guard ref.hasPrefix(prefix) else {
        return nil
    }
    return String(ref.dropFirst(prefix.count))
}

private func mapValueType(
    from schema: [String: Any],
    generatedStructs: [String: String],
    valueTypeName: String
) -> String {
    if let ref = schema["$ref"] as? String,
       let definition = definitionName(fromRef: ref),
       let swiftName = generatedStructs[definition] {
        return swiftName
    }

    if let type = schema["type"] as? String {
        switch type {
        case "string":
            return "String"
        case "boolean":
            return "Bool"
        case "integer":
            return "Int"
        case "number":
            return "Double"
        default:
            return valueTypeName
        }
    }

    return valueTypeName
}

private func resolveSwiftType(
    schema: [String: Any],
    generatedStructs: [String: String],
    valueTypeName: String
) -> String {
    if schema["oneOf"] != nil || schema["anyOf"] != nil || schema["allOf"] != nil {
        return valueTypeName
    }

    if let ref = schema["$ref"] as? String,
       let definition = definitionName(fromRef: ref),
       let swiftName = generatedStructs[definition] {
        return swiftName
    }

    if let type = schema["type"] as? String {
        switch type {
        case "string":
            return "String"
        case "boolean":
            return "Bool"
        case "integer":
            return "Int"
        case "number":
            return "Double"
        case "array":
            if let items = schema["items"] as? [String: Any],
               items["oneOf"] == nil,
               items["anyOf"] == nil,
               items["allOf"] == nil {
                if let itemRef = items["$ref"] as? String,
                   let definition = definitionName(fromRef: itemRef),
                   let swiftName = generatedStructs[definition] {
                    return "[\(swiftName)]"
                }

                if let itemType = items["type"] as? String {
                    switch itemType {
                    case "string":
                        return "[String]"
                    case "boolean":
                        return "[Bool]"
                    case "integer":
                        return "[Int]"
                    case "number":
                        return "[Double]"
                    default:
                        return "[\(valueTypeName)]"
                    }
                }
            }
            return "[\(valueTypeName)]"
        case "object":
            if let patternProperties = schema["patternProperties"] as? [String: Any],
               let first = patternProperties.values.first as? [String: Any] {
                return "[String: \(mapValueType(from: first, generatedStructs: generatedStructs, valueTypeName: valueTypeName))?]"
            }
            if let additionalProperties = schema["additionalProperties"] as? [String: Any] {
                return "[String: \(mapValueType(from: additionalProperties, generatedStructs: generatedStructs, valueTypeName: valueTypeName))]"
            }
            return valueTypeName
        default:
            return valueTypeName
        }
    }

    return valueTypeName
}

private func generateProperties(
    propertiesObject: [String: Any],
    required: Set<String>,
    generatedStructs: [String: String],
    valueTypeName: String,
    accessLevel: String
) -> [GeneratedProperty] {
    propertiesObject
        .keys
        .sorted()
        .compactMap { propertyName in
            guard let propertySchema = propertiesObject[propertyName] as? [String: Any] else {
                return nil
            }

            return GeneratedProperty(
                originalName: propertyName,
                swiftName: sanitizeSwiftIdentifier(propertyName),
                swiftType: resolveSwiftType(
                    schema: propertySchema,
                    generatedStructs: generatedStructs,
                    valueTypeName: valueTypeName
                ),
                optional: !required.contains(propertyName) || propertyTypeContainsNull(propertySchema),
                accessLevel: accessLevel
            )
        }
}

private func renderStruct(name: String, properties: [GeneratedProperty], accessLevel: String) -> String {
    var lines: [String] = []
    lines.append("\(accessLevel) struct \(name): Codable {")

    if properties.isEmpty {
        lines.append("    \(accessLevel) init() {}")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    for property in properties {
        lines.append(property.declaration)
    }

    if properties.contains(where: \.needsCodingKey) {
        lines.append("")
        lines.append("    enum CodingKeys: String, CodingKey {")
        for property in properties {
            if property.needsCodingKey {
                lines.append("        case \(property.swiftName) = \"\(property.originalName)\"")
            } else {
                lines.append("        case \(property.swiftName)")
            }
        }
        lines.append("    }")
    }

    lines.append("}")
    return lines.joined(separator: "\n")
}

private func renderValueEnum(name: String, accessLevel: String) -> String {
    """
    \(accessLevel) enum \(name): Codable, Hashable {
        case object([String: \(name)])
        case array([\(name)])
        case string(String)
        case integer(Int)
        case number(Double)
        case bool(Bool)
        case null

        \(accessLevel) init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if container.decodeNil() {
                self = .null
                return
            }

            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }

            if let value = try? container.decode(Int.self) {
                self = .integer(value)
                return
            }

            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }

            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }

            if let value = try? container.decode([\(name)].self) {
                self = .array(value)
                return
            }

            if let value = try? container.decode([String: \(name)].self) {
                self = .object(value)
                return
            }

            throw DecodingError.typeMismatch(
                \(name).self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON schema value"
                )
            )
        }

        \(accessLevel) func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            switch self {
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            case .string(let value):
                try container.encode(value)
            case .integer(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }
    """
}

private func generateOutput(
    schemaPath: String,
    configuration: GeneratorConfiguration
) throws -> String {
    let schema = try loadJSONObject(from: schemaPath)
    let definitions = schema["definitions"] as? [String: Any] ?? [:]

    let rootTypeName = configuration.rootTypeName ?? defaultRootTypeName
    let definitionTypePrefix = configuration.definitionTypePrefix ?? defaultDefinitionTypePrefix
    let valueTypeName = configuration.valueTypeName ?? defaultValueTypeName
    let accessLevel = configuration.accessLevel ?? "public"

    var generatedStructNames: [String: String] = [:]
    for definitionName in definitions.keys.sorted() {
        guard let definitionSchema = definitions[definitionName] as? [String: Any],
              definitionSchema["properties"] as? [String: Any] != nil else {
            continue
        }
        generatedStructNames[definitionName] = "\(definitionTypePrefix)\(pascalCase(definitionName))"
    }

    var renderedTypes: [String] = []
    renderedTypes.append(renderValueEnum(name: valueTypeName, accessLevel: accessLevel))

    if let rootProperties = schema["properties"] as? [String: Any] {
        let required = Set((schema["required"] as? [String]) ?? [])
        let properties = generateProperties(
            propertiesObject: rootProperties,
            required: required,
            generatedStructs: generatedStructNames,
            valueTypeName: valueTypeName,
            accessLevel: accessLevel
        )
        renderedTypes.append(renderStruct(name: rootTypeName, properties: properties, accessLevel: accessLevel))
    }

    for definitionName in definitions.keys.sorted() {
        guard let definitionSchema = definitions[definitionName] as? [String: Any],
              let structName = generatedStructNames[definitionName],
              let definitionProperties = definitionSchema["properties"] as? [String: Any] else {
            continue
        }

        let required = Set((definitionSchema["required"] as? [String]) ?? [])
        let properties = generateProperties(
            propertiesObject: definitionProperties,
            required: required,
            generatedStructs: generatedStructNames,
            valueTypeName: valueTypeName,
            accessLevel: accessLevel
        )
        renderedTypes.append(renderStruct(name: structName, properties: properties, accessLevel: accessLevel))
    }

    return """
    // This file is auto-generated by swift-jsonschema-generator.
    // Do not edit by hand.

    import Foundation

    \(renderedTypes.joined(separator: "\n\n"))
    """
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

let schemaURL: URL
if URL(fileURLWithPath: configuration.schema).path.hasPrefix("/") {
    schemaURL = URL(fileURLWithPath: configuration.schema)
} else {
    schemaURL = URL(fileURLWithPath: targetDirectory).appending(path: configuration.schema)
}

let output = try generateOutput(
    schemaPath: schemaURL.path(percentEncoded: false),
    configuration: configuration
)

try output.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
