import Foundation
import Testing
@testable import JSONSchemaToSwiftGeneratorCore

struct JSONSchemaToSwiftGeneratorCoreTests {
    private let generator = JSONSchemaToSwiftGenerator()

    @Test
    func nullablePrimitivePropertiesKeepTheirTypedSwiftRepresentation() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "age": { "type": "integer" },
                "nickname": { "type": ["string", "null"] }
              },
              "required": ["age", "nickname"]
            }
            """
        )

        #expect(output.contains("public let nickname: String?"))
        #expect(!output.contains("public let nickname: JSONSchemaValue?"))
        #expect(output.contains("public init(age: Int, nickname: String? = nil)"))
    }

    @Test
    func patternPropertiesGenerateNonOptionalDictionaryValuesUnlessSchemaAllowsNull() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "labels": {
                  "type": "object",
                  "patternProperties": {
                    "^[a-z]+$": { "type": "string" }
                  },
                  "additionalProperties": false
                }
              }
            }
            """
        )

        #expect(output.contains("public let labels: [String: String]?"))
        #expect(!output.contains("[String: String?]?"))
    }

    @Test
    func codingKeysEscapeSchemaPropertyNamesForSwiftStringLiterals() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "quote\\"slash\\\\name": { "type": "string" }
              }
            }
            """
        )

        #expect(output.contains(#"case quote_slash_name = "quote\"slash\\name""#))
    }

    @Test
    func rootRefsGenerateTypealiasesInsteadOfDroppingTheRootType() throws {
        let output = try render(
            """
            {
              "$ref": "#/definitions/user",
              "definitions": {
                "user": {
                  "type": "object",
                  "properties": {
                    "name": { "type": "string" }
                  },
                  "required": ["name"]
                }
              }
            }
            """
        )

        #expect(output.contains("public typealias JSONSchemaDocument = JSONSchemaUser"))
        #expect(output.contains("public struct JSONSchemaUser: Codable, Hashable, Sendable {"))
    }

    @Test
    func nullableObjectDefinitionsRemainTypedThroughReferences() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "user": { "$ref": "#/definitions/user" }
              },
              "definitions": {
                "user": {
                  "type": ["object", "null"],
                  "properties": {
                    "name": { "type": "string" }
                  },
                  "required": ["name"]
                }
              }
            }
            """
        )

        #expect(output.contains("public let user: JSONSchemaUser?"))
        #expect(output.contains("public struct JSONSchemaUserPayload: Codable, Hashable, Sendable {"))
        #expect(output.contains("public typealias JSONSchemaUser = JSONSchemaUserPayload?"))
    }

    private func render(_ schema: String) throws -> String {
        try generator.generateOutput(
            schemaData: Data(schema.utf8),
            configuration: GeneratorConfiguration(schema: "schema.json")
        )
    }
}
