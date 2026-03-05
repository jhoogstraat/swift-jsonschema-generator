import Foundation

public let defaultRootTypeName = "JSONSchemaDocument"
public let defaultDefinitionTypePrefix = "JSONSchema"
public let defaultValueTypeName = "JSONSchemaValue"

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
    "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try"
]

public struct GeneratorConfiguration: Decodable, Sendable {
    public let schema: String
    public let rootTypeName: String?
    public let definitionTypePrefix: String?
    public let valueTypeName: String?
    public let accessLevel: String?
    public let outputFile: String?

    public init(
        schema: String,
        rootTypeName: String? = nil,
        definitionTypePrefix: String? = nil,
        valueTypeName: String? = nil,
        accessLevel: String? = nil,
        outputFile: String? = nil
    ) {
        self.schema = schema
        self.rootTypeName = rootTypeName
        self.definitionTypePrefix = definitionTypePrefix
        self.valueTypeName = valueTypeName
        self.accessLevel = accessLevel
        self.outputFile = outputFile
    }
}

public enum GeneratorError: Error, LocalizedError {
    case schemaRootNotObject
    case unsupportedSchemaRoot

    public var errorDescription: String? {
        switch self {
        case .schemaRootNotObject:
            return "JSON schema root must be an object"
        case .unsupportedSchemaRoot:
            return "JSON schema root could not be mapped to a Swift type"
        }
    }
}

public struct JSONSchemaToSwiftGenerator: Sendable {
    public init() {}

    public func generateOutput(schemaData: Data, configuration: GeneratorConfiguration) throws -> String {
        let schema = try loadJSONObject(from: schemaData)
        return try GenerationContext(schema: schema, configuration: configuration).render()
    }

    public func generateOutput(schemaPath: String, configuration: GeneratorConfiguration) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: schemaPath))
        return try generateOutput(schemaData: data, configuration: configuration)
    }

    public static func resolveSchemaURL(configurationSchema: String, relativeTo baseDirectory: String) -> URL {
        if configurationSchema.hasPrefix("/") {
            return URL(fileURLWithPath: configurationSchema)
        }
        return URL(fileURLWithPath: baseDirectory).appending(path: configurationSchema)
    }
}

private struct SwiftTypeInfo {
    let baseType: String
    let allowsNull: Bool

    var fullType: String {
        baseType + (allowsNull ? "?" : "")
    }
}

private struct GeneratedProperty {
    let originalName: String
    let swiftName: String
    let swiftType: String
    let optional: Bool
    let accessLevel: String

    var declaration: String {
        "    \(accessLevel) let \(swiftName): \(swiftType)\(optional ? "?" : "")"
    }

    var initializerParameter: String {
        "\(swiftName): \(swiftType)\(optional ? "? = nil" : "")"
    }

    var initializerAssignment: String {
        "        self.\(swiftName) = \(swiftName)"
    }

    var needsCodingKey: Bool {
        originalName != swiftName
    }
}

private struct GenerationContext {
    let schema: [String: Any]
    let rootTypeName: String
    let valueTypeName: String
    let accessLevel: String
    let definitions: [String: Any]
    let generatedDefinitionNames: [String: String]

    init(schema: [String: Any], configuration: GeneratorConfiguration) {
        self.schema = schema
        self.rootTypeName = sanitizeSwiftTypeName(configuration.rootTypeName ?? defaultRootTypeName)
        self.valueTypeName = sanitizeSwiftTypeName(configuration.valueTypeName ?? defaultValueTypeName)
        self.accessLevel = configuration.accessLevel ?? "public"
        self.definitions = (schema["definitions"] as? [String: Any]) ?? [:]
        self.generatedDefinitionNames = Self.makeDefinitionNames(
            definitions: (schema["definitions"] as? [String: Any]) ?? [:],
            prefix: sanitizeSwiftTypeName(configuration.definitionTypePrefix ?? defaultDefinitionTypePrefix)
        )
    }

    func render() throws -> String {
        var renderedTypes: [String] = [renderValueEnum(name: valueTypeName, accessLevel: accessLevel)]
        renderedTypes.append(contentsOf: try renderRootDeclarations())

        for definitionName in definitions.keys.sorted() {
            guard let definitionSchema = definitions[definitionName] as? [String: Any],
                  let swiftName = generatedDefinitionNames[definitionName] else {
                continue
            }
            renderedTypes.append(contentsOf: renderDeclarations(named: swiftName, for: definitionSchema))
        }

        return """
        // This file is auto-generated by swift-jsonschema-generator.
        // Do not edit by hand.

        import Foundation

        \(renderedTypes.joined(separator: "\n\n"))
        """
    }

    private static func makeDefinitionNames(definitions: [String: Any], prefix: String) -> [String: String] {
        var usedNames = Set<String>()
        var names: [String: String] = [:]

        for definitionName in definitions.keys.sorted() {
            let baseName = sanitizeSwiftTypeName(prefix + pascalCase(definitionName))
            names[definitionName] = uniquedSwiftName(baseName, usedNames: &usedNames)
        }

        return names
    }

    private func renderRootDeclarations() throws -> [String] {
        let declarations = renderDeclarations(named: rootTypeName, for: schema)
        guard !declarations.isEmpty else {
            throw GeneratorError.unsupportedSchemaRoot
        }
        return declarations
    }

    private func renderDeclarations(named swiftName: String, for schema: [String: Any]) -> [String] {
        if shouldRenderStruct(for: schema) {
            let properties = generateProperties(
                propertiesObject: schema["properties"] as? [String: Any] ?? [:],
                required: Set((schema["required"] as? [String]) ?? [])
            )
            if schemaAllowsNull(schema) {
                let payloadName = "\(swiftName)Payload"
                return [
                    renderStruct(name: payloadName, properties: properties, accessLevel: accessLevel),
                    "\(accessLevel) typealias \(swiftName) = \(payloadName)?"
                ]
            }

            return [renderStruct(name: swiftName, properties: properties, accessLevel: accessLevel)]
        }

        let typeInfo = resolveSwiftTypeInfo(schema: schema)
        if typeInfo.baseType == swiftName, !typeInfo.allowsNull {
            return ["\(accessLevel) typealias \(swiftName) = \(valueTypeName)"]
        }

        let schemaHasTypeInformation = schema["$ref"] != nil
            || schema["type"] != nil
            || schema["oneOf"] != nil
            || schema["anyOf"] != nil
            || schema["allOf"] != nil
            || schema["properties"] != nil
            || schema["patternProperties"] != nil
            || schema["additionalProperties"] != nil

        guard schemaHasTypeInformation else {
            return []
        }

        return ["\(accessLevel) typealias \(swiftName) = \(typeInfo.fullType)"]
    }

    private func shouldRenderStruct(for schema: [String: Any]) -> Bool {
        if schema["properties"] as? [String: Any] != nil {
            return true
        }

        let typeName = primaryNonNullType(in: schema)
        return typeName == "object"
            && schema["additionalProperties"] == nil
            && schema["patternProperties"] == nil
            && schema["$ref"] == nil
    }

    private func generateProperties(
        propertiesObject: [String: Any],
        required: Set<String>
    ) -> [GeneratedProperty] {
        var usedNames = Set<String>()

        return propertiesObject
            .keys
            .sorted()
            .compactMap { propertyName in
                guard let propertySchema = propertiesObject[propertyName] as? [String: Any] else {
                    return nil
                }

                let typeInfo = resolveSwiftTypeInfo(schema: propertySchema)
                let swiftName = uniquedSwiftName(sanitizeSwiftIdentifier(propertyName), usedNames: &usedNames)

                return GeneratedProperty(
                    originalName: propertyName,
                    swiftName: swiftName,
                    swiftType: typeInfo.baseType,
                    optional: !required.contains(propertyName) || typeInfo.allowsNull,
                    accessLevel: accessLevel
                )
            }
    }

    private func resolveSwiftTypeInfo(schema: [String: Any]) -> SwiftTypeInfo {
        let allowsNull = schemaAllowsNull(schema)

        if schema["oneOf"] != nil || schema["anyOf"] != nil || schema["allOf"] != nil {
            return SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull)
        }

        if let ref = schema["$ref"] as? String,
           let definition = definitionName(fromRef: ref),
           let swiftName = generatedDefinitionNames[definition] {
            return SwiftTypeInfo(baseType: swiftName, allowsNull: allowsNull)
        }

        switch primaryNonNullType(in: schema) {
        case "string":
            return SwiftTypeInfo(baseType: "String", allowsNull: allowsNull)
        case "boolean":
            return SwiftTypeInfo(baseType: "Bool", allowsNull: allowsNull)
        case "integer":
            return SwiftTypeInfo(baseType: "Int", allowsNull: allowsNull)
        case "number":
            return SwiftTypeInfo(baseType: "Double", allowsNull: allowsNull)
        case "array":
            if let items = schema["items"] as? [String: Any] {
                let itemType = resolveSwiftTypeInfo(schema: items)
                return SwiftTypeInfo(baseType: "[\(itemType.fullType)]", allowsNull: allowsNull)
            }
            return SwiftTypeInfo(baseType: "[\(valueTypeName)]", allowsNull: allowsNull)
        case "object":
            if let dictionaryType = resolveDictionaryType(schema: schema) {
                return SwiftTypeInfo(baseType: dictionaryType, allowsNull: allowsNull)
            }
            return SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull)
        default:
            if schema["properties"] as? [String: Any] != nil {
                return SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull)
            }
            return SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull)
        }
    }

    private func resolveDictionaryType(schema: [String: Any]) -> String? {
        if let additionalProperties = schema["additionalProperties"] as? [String: Any] {
            let valueType = resolveSwiftTypeInfo(schema: additionalProperties)
            return "[String: \(valueType.fullType)]"
        }

        if let allowsAdditional = schema["additionalProperties"] as? Bool, allowsAdditional {
            return "[String: \(valueTypeName)]"
        }

        guard let patternProperties = schema["patternProperties"] as? [String: Any] else {
            return nil
        }

        let resolvedTypes = patternProperties.values.compactMap { value -> String? in
            guard let propertySchema = value as? [String: Any] else {
                return nil
            }
            return resolveSwiftTypeInfo(schema: propertySchema).fullType
        }

        guard !resolvedTypes.isEmpty else {
            return nil
        }

        let uniqueTypes = Set(resolvedTypes)
        if uniqueTypes.count == 1, let onlyType = uniqueTypes.first {
            return "[String: \(onlyType)]"
        }

        return "[String: \(valueTypeName)]"
    }
}

private func renderStruct(name: String, properties: [GeneratedProperty], accessLevel: String) -> String {
    var lines: [String] = []
    lines.append("\(accessLevel) struct \(name): Codable, Hashable, Sendable {")

    if properties.isEmpty {
        lines.append("    \(accessLevel) init() {}")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    for property in properties {
        lines.append(property.declaration)
    }

    lines.append("")
    lines.append("    \(accessLevel) init(\(properties.map(\.initializerParameter).joined(separator: ", "))) {")
    for property in properties {
        lines.append(property.initializerAssignment)
    }
    lines.append("    }")

    if properties.contains(where: \.needsCodingKey) {
        lines.append("")
        lines.append("    private enum CodingKeys: String, CodingKey {")
        for property in properties {
            if property.needsCodingKey {
                lines.append("        case \(property.swiftName) = \(swiftStringLiteral(property.originalName))")
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
    \(accessLevel) enum \(name): Codable, Hashable, Sendable {
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

private func loadJSONObject(from data: Data) throws -> [String: Any] {
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

private func sanitizeSwiftTypeName(_ raw: String) -> String {
    sanitizeSwiftIdentifier(raw)
}

private func uniquedSwiftName(_ baseName: String, usedNames: inout Set<String>) -> String {
    var candidate = baseName
    var suffix = 2

    while usedNames.contains(candidate) {
        candidate = "\(baseName)\(suffix)"
        suffix += 1
    }

    usedNames.insert(candidate)
    return candidate
}

private func schemaAllowsNull(_ schema: [String: Any]) -> Bool {
    schemaTypeOptions(in: schema).contains("null")
}

private func schemaTypeOptions(in schema: [String: Any]) -> [String] {
    if let type = schema["type"] as? String {
        return [type]
    }

    if let types = schema["type"] as? [String] {
        return types
    }

    if let rawTypes = schema["type"] as? [Any] {
        return rawTypes.compactMap { $0 as? String }
    }

    return []
}

private func primaryNonNullType(in schema: [String: Any]) -> String? {
    let nonNullTypes = schemaTypeOptions(in: schema).filter { $0 != "null" }
    guard nonNullTypes.count == 1 else {
        return nil
    }
    return nonNullTypes[0]
}

private func definitionName(fromRef ref: String) -> String? {
    let prefix = "#/definitions/"
    guard ref.hasPrefix(prefix) else {
        return nil
    }
    return String(ref.dropFirst(prefix.count))
}

private func swiftStringLiteral(_ raw: String) -> String {
    var escaped = "\""

    for character in raw {
        switch character {
        case "\\":
            escaped.append("\\\\")
        case "\"":
            escaped.append("\\\"")
        case "\n":
            escaped.append("\\n")
        case "\r":
            escaped.append("\\r")
        case "\t":
            escaped.append("\\t")
        default:
            escaped.append(character)
        }
    }

    escaped.append("\"")
    return escaped
}
