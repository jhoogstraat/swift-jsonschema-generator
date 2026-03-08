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

private enum CompositeKind {
    case oneOf
    case anyOf
    case allOf

    var key: String {
        switch self {
        case .oneOf:
            return "oneOf"
        case .anyOf:
            return "anyOf"
        case .allOf:
            return "allOf"
        }
    }
}

private enum ConcreteDecodingStrategy {
    case jsonDecode
    case helperFactory
}

private struct ConcreteTypeResolution {
    let typeInfo: SwiftTypeInfo
    let declarations: [String]
    let decodingStrategy: ConcreteDecodingStrategy
}

private struct GeneratedProperty {
    let originalName: String
    let swiftName: String
    let swiftType: String
    let optional: Bool
    let accessLevel: String
    let typedAccessorDeclaration: String?

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

private struct GeneratedProperties {
    let properties: [GeneratedProperty]
    let supportingDeclarations: [String]
}

private struct CompositeMember {
    let name: String
    let typeName: String?
    let allowsNull: Bool
    let declarations: [String]
    let decodingStrategy: ConcreteDecodingStrategy?
}

private final class GenerationContext {
    let schema: [String: Any]
    let rootTypeName: String
    let valueTypeName: String
    let accessLevel: String
    let definitions: [String: Any]
    let generatedDefinitionNames: [String: String]

    private var usedGeneratedTypeNames: Set<String>
    private let namedCompositeHelperNames: [String: String]

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

        var usedTypeNames = Set<String>()
        usedTypeNames.insert(rootTypeName)
        for swiftName in generatedDefinitionNames.values {
            usedTypeNames.insert(swiftName)
        }

        var helperNames: [String: String] = [:]
        if compositeKind(in: schema) != nil {
            helperNames[rootTypeName] = uniquedSwiftName("\(rootTypeName)Composite", usedNames: &usedTypeNames)
        }

        for definitionName in definitions.keys.sorted() {
            guard let definitionSchema = definitions[definitionName] as? [String: Any],
                  compositeKind(in: definitionSchema) != nil,
                  let swiftName = generatedDefinitionNames[definitionName] else {
                continue
            }
            helperNames[swiftName] = uniquedSwiftName("\(swiftName)Composite", usedNames: &usedTypeNames)
        }

        self.usedGeneratedTypeNames = usedTypeNames
        self.namedCompositeHelperNames = helperNames
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
            let generated = generateProperties(
                ownerTypeName: swiftName,
                propertiesObject: schema["properties"] as? [String: Any] ?? [:],
                required: Set((schema["required"] as? [String]) ?? [])
            )

            var declarations = generated.supportingDeclarations
            declarations.append(renderStruct(name: swiftName, properties: generated.properties, accessLevel: accessLevel))
            return declarations
        }

        if compositeKind(in: schema) != nil, let helperTypeName = namedCompositeHelperNames[swiftName] {
            var declarations = renderCompositeHelper(named: helperTypeName, for: schema)
            declarations.append("\(accessLevel) typealias \(swiftName) = \(resolveSwiftTypeInfo(schema: schema).fullType)")
            declarations.append(renderCompositeValueAccessorExtensions(
                valueTypeName: valueTypeName,
                helperTypeName: helperTypeName,
                accessLevel: accessLevel
            ))
            return declarations
        }

        let typeInfo = resolveSwiftTypeInfo(schema: schema)
        if typeInfo.baseType == swiftName, !typeInfo.allowsNull {
            return ["\(accessLevel) typealias \(swiftName) = \(valueTypeName)"]
        }

        guard schemaHasTypeInformation(schema) else {
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
        ownerTypeName: String,
        propertiesObject: [String: Any],
        required: Set<String>
    ) -> GeneratedProperties {
        var usedNames = Set<String>()
        var properties: [GeneratedProperty] = []
        var supportingDeclarations: [String] = []

        for propertyName in propertiesObject.keys.sorted() {
            guard let propertySchema = propertiesObject[propertyName] as? [String: Any] else {
                continue
            }

            let typeInfo = resolveSwiftTypeInfo(schema: propertySchema)
            let swiftName = uniquedSwiftName(sanitizeSwiftIdentifier(propertyName), usedNames: &usedNames)
            let isOptional = !required.contains(propertyName) || typeInfo.allowsNull

            var typedAccessorDeclaration: String?
            if compositeKind(in: propertySchema) != nil {
                let helperTypeName = uniqueGeneratedTypeName(base: "\(ownerTypeName)\(pascalCase(propertyName))Composite")
                supportingDeclarations.append(contentsOf: renderCompositeHelper(named: helperTypeName, for: propertySchema))
                typedAccessorDeclaration = renderPropertyCompositeAccessor(
                    propertyName: swiftName,
                    helperTypeName: helperTypeName,
                    isOptional: isOptional,
                    accessLevel: accessLevel
                )
            }

            properties.append(
                GeneratedProperty(
                    originalName: propertyName,
                    swiftName: swiftName,
                    swiftType: typeInfo.baseType,
                    optional: isOptional,
                    accessLevel: accessLevel,
                    typedAccessorDeclaration: typedAccessorDeclaration
                )
            )
        }

        return GeneratedProperties(properties: properties, supportingDeclarations: supportingDeclarations)
    }

    private func renderCompositeHelper(named helperTypeName: String, for schema: [String: Any]) -> [String] {
        guard let compositeKind = compositeKind(in: schema),
              let memberSchemas = schema[compositeKind.key] as? [Any] else {
            return []
        }

        let generatedMembers = buildCompositeMembers(
            ownerTypeName: helperTypeName,
            memberSchemas: memberSchemas.compactMap { $0 as? [String: Any] }
        )

        var declarations = generatedMembers.flatMap(\.declarations)
        switch compositeKind {
        case .oneOf, .anyOf:
            declarations.append(
                renderCompositeEnum(
                    name: helperTypeName,
                    members: generatedMembers,
                    accessLevel: accessLevel,
                    valueTypeName: valueTypeName
                )
            )
        case .allOf:
            declarations.append(
                renderCompositeStruct(
                    name: helperTypeName,
                    members: generatedMembers,
                    accessLevel: accessLevel,
                    valueTypeName: valueTypeName
                )
            )
        }

        return declarations
    }

    private func buildCompositeMembers(ownerTypeName: String, memberSchemas: [[String: Any]]) -> [CompositeMember] {
        var usedNames = Set<String>()
        var members: [CompositeMember] = []

        for (index, memberSchema) in memberSchemas.enumerated() {
            let memberIndex = index + 1
            let nonNullSchema = removingNullType(from: memberSchema)
            let nameBase = compositeMemberNameBase(for: nonNullSchema, index: memberIndex)
            let memberName = uniquedSwiftName(sanitizeSwiftIdentifier(camelCase(nameBase)), usedNames: &usedNames)

            guard schemaHasTypeInformation(nonNullSchema) else {
                members.append(
                    CompositeMember(
                        name: memberName,
                        typeName: nil,
                        allowsNull: schemaAllowsNull(memberSchema),
                        declarations: [],
                        decodingStrategy: nil
                    )
                )
                continue
            }

            let resolution = resolveConcreteSwiftTypeInfo(
                schema: nonNullSchema,
                namingHintBase: "\(ownerTypeName)\(nameBase)"
            )

            members.append(
                CompositeMember(
                    name: memberName,
                    typeName: resolution.typeInfo.baseType,
                    allowsNull: schemaAllowsNull(memberSchema) || resolution.typeInfo.allowsNull,
                    declarations: resolution.declarations,
                    decodingStrategy: resolution.decodingStrategy
                )
            )
        }

        return members
    }

    private func resolveSwiftTypeInfo(schema: [String: Any]) -> SwiftTypeInfo {
        let allowsNull = schemaAllowsNull(schema)

        if compositeKind(in: schema) != nil {
            return SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull)
        }

        if let ref = schema["$ref"] as? String,
           let definition = definitionName(fromRef: ref),
           let swiftName = generatedDefinitionNames[definition] {
            let referencedSchema = definitions[definition] as? [String: Any]
            let referencedAllowsNull = referencedSchema.map(schemaAllowsNull) ?? false
            return SwiftTypeInfo(baseType: swiftName, allowsNull: allowsNull || referencedAllowsNull)
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

    private func resolveConcreteSwiftTypeInfo(schema: [String: Any], namingHintBase: String) -> ConcreteTypeResolution {
        let allowsNull = schemaAllowsNull(schema)

        if let ref = schema["$ref"] as? String,
           let definition = definitionName(fromRef: ref),
           let swiftName = generatedDefinitionNames[definition] {
            let referencedSchema = definitions[definition] as? [String: Any]
            let referencedAllowsNull = referencedSchema.map(schemaAllowsNull) ?? false

            if let referencedSchema, compositeKind(in: referencedSchema) != nil,
               let helperTypeName = namedCompositeHelperNames[swiftName] {
                return ConcreteTypeResolution(
                    typeInfo: SwiftTypeInfo(baseType: helperTypeName, allowsNull: allowsNull || referencedAllowsNull),
                    declarations: [],
                    decodingStrategy: .helperFactory
                )
            }

            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: swiftName, allowsNull: allowsNull || referencedAllowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        }

        if compositeKind(in: schema) != nil {
            let helperTypeName = uniqueGeneratedTypeName(base: namingHintBase)
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: helperTypeName, allowsNull: allowsNull),
                declarations: renderCompositeHelper(named: helperTypeName, for: schema),
                decodingStrategy: .helperFactory
            )
        }

        if shouldRenderStruct(for: schema) {
            let structName = uniqueGeneratedTypeName(base: namingHintBase)
            let generated = generateProperties(
                ownerTypeName: structName,
                propertiesObject: schema["properties"] as? [String: Any] ?? [:],
                required: Set((schema["required"] as? [String]) ?? [])
            )

            var declarations = generated.supportingDeclarations
            declarations.append(renderStruct(name: structName, properties: generated.properties, accessLevel: accessLevel))

            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: structName, allowsNull: allowsNull),
                declarations: declarations,
                decodingStrategy: .jsonDecode
            )
        }

        switch primaryNonNullType(in: schema) {
        case "string":
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "String", allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        case "boolean":
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "Bool", allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        case "integer":
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "Int", allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        case "number":
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "Double", allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        case "array":
            if let items = schema["items"] as? [String: Any] {
                let itemType = resolveConcreteSwiftTypeInfo(schema: items, namingHintBase: "\(namingHintBase)Item")
                return ConcreteTypeResolution(
                    typeInfo: SwiftTypeInfo(baseType: "[\(itemType.typeInfo.fullType)]", allowsNull: allowsNull),
                    declarations: itemType.declarations,
                    decodingStrategy: .jsonDecode
                )
            }

            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "[\(valueTypeName)]", allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        case "object":
            if let dictionaryType = resolveConcreteDictionaryType(schema: schema, namingHintBase: "\(namingHintBase)Value") {
                return dictionaryType
            }

            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        default:
            if schema["properties"] as? [String: Any] != nil {
                return ConcreteTypeResolution(
                    typeInfo: SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull),
                    declarations: [],
                    decodingStrategy: .jsonDecode
                )
            }

            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: valueTypeName, allowsNull: allowsNull),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
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

    private func resolveConcreteDictionaryType(schema: [String: Any], namingHintBase: String) -> ConcreteTypeResolution? {
        if let additionalProperties = schema["additionalProperties"] as? [String: Any] {
            let valueType = resolveConcreteSwiftTypeInfo(schema: additionalProperties, namingHintBase: namingHintBase)
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(
                    baseType: "[String: \(valueType.typeInfo.fullType)]",
                    allowsNull: schemaAllowsNull(schema)
                ),
                declarations: valueType.declarations,
                decodingStrategy: .jsonDecode
            )
        }

        if let allowsAdditional = schema["additionalProperties"] as? Bool, allowsAdditional {
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "[String: \(valueTypeName)]", allowsNull: schemaAllowsNull(schema)),
                declarations: [],
                decodingStrategy: .jsonDecode
            )
        }

        guard let patternProperties = schema["patternProperties"] as? [String: Any] else {
            return nil
        }

        var resolutions: [ConcreteTypeResolution] = []
        for key in patternProperties.keys.sorted() {
            guard let propertySchema = patternProperties[key] as? [String: Any] else {
                continue
            }
            resolutions.append(
                resolveConcreteSwiftTypeInfo(
                    schema: propertySchema,
                    namingHintBase: "\(namingHintBase)\(pascalCase(key))"
                )
            )
        }

        guard !resolutions.isEmpty else {
            return nil
        }

        let resolvedTypes = Set(resolutions.map { $0.typeInfo.fullType })
        if resolvedTypes.count == 1, let onlyType = resolvedTypes.first {
            return ConcreteTypeResolution(
                typeInfo: SwiftTypeInfo(baseType: "[String: \(onlyType)]", allowsNull: schemaAllowsNull(schema)),
                declarations: resolutions.flatMap(\.declarations),
                decodingStrategy: .jsonDecode
            )
        }

        return ConcreteTypeResolution(
            typeInfo: SwiftTypeInfo(baseType: "[String: \(valueTypeName)]", allowsNull: schemaAllowsNull(schema)),
            declarations: resolutions.flatMap(\.declarations),
            decodingStrategy: .jsonDecode
        )
    }

    private func renderPropertyCompositeAccessor(
        propertyName: String,
        helperTypeName: String,
        isOptional: Bool,
        accessLevel: String
    ) -> String {
        let body = isOptional
            ? "\(propertyName).flatMap(\(helperTypeName).from)"
            : "\(helperTypeName).from(\(propertyName))"

        return """
            \(accessLevel) var \(propertyName)Typed: \(helperTypeName)? {
                \(body)
            }
        """
    }

    private func renderCompositeEnum(
        name: String,
        members: [CompositeMember],
        accessLevel: String,
        valueTypeName: String
    ) -> String {
        let payloadMembers = members.filter { $0.typeName != nil }
        let includesNull = members.contains { $0.allowsNull }

        var lines: [String] = []
        lines.append("\(accessLevel) enum \(name): Hashable, Sendable {")

        if includesNull {
            lines.append("    case null")
        }

        for member in payloadMembers {
            guard let typeName = member.typeName else {
                continue
            }
            lines.append("    case \(member.name)(\(typeName))")
        }

        lines.append("")
        lines.append("    \(accessLevel) static func from(_ value: \(valueTypeName)) -> Self? {")

        if includesNull {
            lines.append("        if case .null = value {")
            lines.append("            return .null")
            lines.append("        }")
            if !payloadMembers.isEmpty {
                lines.append("")
            }
        }

        for (index, member) in payloadMembers.enumerated() {
            guard let typeName = member.typeName else {
                continue
            }

            lines.append("        if let decoded = \(renderCompositeDecodeExpression(strategy: member.decodingStrategy, typeName: typeName, valueExpression: "value")) {")
            lines.append("            return .\(member.name)(decoded)")
            lines.append("        }")

            if index < payloadMembers.count - 1 {
                lines.append("")
            }
        }

        if !payloadMembers.isEmpty {
            lines.append("")
        }

        lines.append("        return nil")
        lines.append("    }")
        lines.append("}")

        return lines.joined(separator: "\n")
    }

    private func renderCompositeStruct(
        name: String,
        members: [CompositeMember],
        accessLevel: String,
        valueTypeName: String
    ) -> String {
        let payloadMembers = members.compactMap { member -> (name: String, typeName: String, strategy: ConcreteDecodingStrategy)? in
            guard let typeName = member.typeName, let strategy = member.decodingStrategy else {
                return nil
            }
            return (name: member.name, typeName: typeName, strategy: strategy)
        }

        var lines: [String] = []
        lines.append("\(accessLevel) struct \(name): Hashable, Sendable {")

        if payloadMembers.isEmpty {
            lines.append("    \(accessLevel) init() {}")
            lines.append("")
            lines.append("    \(accessLevel) static func from(_ value: \(valueTypeName)) -> Self? {")
            lines.append("        nil")
            lines.append("    }")
            lines.append("}")
            return lines.joined(separator: "\n")
        }

        for member in payloadMembers {
            lines.append("    \(accessLevel) let \(member.name): \(member.typeName)")
        }

        lines.append("")
        lines.append("    \(accessLevel) init(\(payloadMembers.map { "\($0.name): \($0.typeName)" }.joined(separator: ", "))) {")
        for member in payloadMembers {
            lines.append("        self.\(member.name) = \(member.name)")
        }
        lines.append("    }")
        lines.append("")
        lines.append("    \(accessLevel) static func from(_ value: \(valueTypeName)) -> Self? {")
        lines.append("        guard")

        for (index, member) in payloadMembers.enumerated() {
            let suffix = index == payloadMembers.count - 1 ? "" : ","
            lines.append(
                "            let \(member.name) = \(renderCompositeDecodeExpression(strategy: member.strategy, typeName: member.typeName, valueExpression: "value"))\(suffix)"
            )
        }

        lines.append("        else {")
        lines.append("            return nil")
        lines.append("        }")
        lines.append("")
        lines.append("        return Self(\(payloadMembers.map { "\($0.name): \($0.name)" }.joined(separator: ", ")))")
        lines.append("    }")
        lines.append("}")

        return lines.joined(separator: "\n")
    }

    private func renderCompositeDecodeExpression(
        strategy: ConcreteDecodingStrategy?,
        typeName: String,
        valueExpression: String
    ) -> String {
        switch strategy {
        case .helperFactory:
            return "\(typeName).from(\(valueExpression))"
        case .jsonDecode, .none:
            return "\(valueExpression).decodedCompositeValue(as: \(typeName).self)"
        }
    }

    private func renderCompositeValueAccessorExtensions(
        valueTypeName: String,
        helperTypeName: String,
        accessLevel: String
    ) -> String {
        """
        \(accessLevel) extension \(valueTypeName) {
            var as\(helperTypeName): \(helperTypeName)? {
                \(helperTypeName).from(self)
            }
        }

        \(accessLevel) extension Optional where Wrapped == \(valueTypeName) {
            var as\(helperTypeName): \(helperTypeName)? {
                guard let value = self else {
                    return nil
                }

                return \(helperTypeName).from(value)
            }
        }
        """
    }

    private func compositeMemberNameBase(for schema: [String: Any], index: Int) -> String {
        if let ref = schema["$ref"] as? String, let definition = definitionName(fromRef: ref) {
            return pascalCase(definition)
        }

        if compositeKind(in: schema) != nil {
            return "CompositeMember\(index)"
        }

        switch primaryNonNullType(in: schema) {
        case "string":
            return "String"
        case "boolean":
            return "Bool"
        case "integer":
            return "Integer"
        case "number":
            return "Number"
        case "array":
            return "Array"
        case "object":
            if schema["properties"] as? [String: Any] != nil {
                return "Object\(index)"
            }
            if schema["additionalProperties"] != nil || schema["patternProperties"] != nil {
                return "Map"
            }
            return "Object\(index)"
        default:
            if schema["properties"] as? [String: Any] != nil {
                return "Object\(index)"
            }
            return "Member\(index)"
        }
    }

    private func uniqueGeneratedTypeName(base: String) -> String {
        uniquedSwiftName(sanitizeSwiftTypeName(base), usedNames: &usedGeneratedTypeNames)
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

    let typedAccessors = properties.compactMap(\.typedAccessorDeclaration)
    if !typedAccessors.isEmpty {
        lines.append("")
        for (index, accessor) in typedAccessors.enumerated() {
            lines.append(accessor)
            if index < typedAccessors.count - 1 {
                lines.append("")
            }
        }
    }

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

        fileprivate func decodedCompositeValue<T: Decodable>(as type: T.Type) -> T? {
            guard let data = try? JSONEncoder().encode(self) else {
                return nil
            }

            return try? JSONDecoder().decode(T.self, from: data)
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

private func camelCase(_ value: String) -> String {
    let pascal = pascalCase(value)
    guard let first = pascal.first else {
        return "value"
    }

    return first.lowercased() + pascal.dropFirst()
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

private func removingNullType(from schema: [String: Any]) -> [String: Any] {
    guard schema["type"] != nil else {
        return schema
    }

    let nonNullTypes = schemaTypeOptions(in: schema).filter { $0 != "null" }
    var strippedSchema = schema

    switch nonNullTypes.count {
    case 0:
        strippedSchema.removeValue(forKey: "type")
    case 1:
        strippedSchema["type"] = nonNullTypes[0]
    default:
        strippedSchema["type"] = nonNullTypes
    }

    return strippedSchema
}

private func primaryNonNullType(in schema: [String: Any]) -> String? {
    let nonNullTypes = schemaTypeOptions(in: schema).filter { $0 != "null" }
    guard nonNullTypes.count == 1 else {
        return nil
    }
    return nonNullTypes[0]
}

private func compositeKind(in schema: [String: Any]) -> CompositeKind? {
    if schema["oneOf"] != nil {
        return .oneOf
    }

    if schema["anyOf"] != nil {
        return .anyOf
    }

    if schema["allOf"] != nil {
        return .allOf
    }

    return nil
}

private func schemaHasTypeInformation(_ schema: [String: Any]) -> Bool {
    schema["$ref"] != nil
        || schema["type"] != nil
        || schema["oneOf"] != nil
        || schema["anyOf"] != nil
        || schema["allOf"] != nil
        || schema["properties"] != nil
        || schema["patternProperties"] != nil
        || schema["additionalProperties"] != nil
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
