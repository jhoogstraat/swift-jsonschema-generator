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
        #expect(output.contains("public struct JSONSchemaUser: Codable, Hashable, Sendable {"))
        #expect(!output.contains("JSONSchemaUserPayload"))
    }

    @Test
    func oneOfPropertiesGenerateNarrowedCompositeAccessors() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "payload": {
                  "oneOf": [
                    { "$ref": "#/definitions/cat" },
                    { "$ref": "#/definitions/dog" }
                  ]
                }
              },
              "definitions": {
                "cat": {
                  "type": "object",
                  "properties": {
                    "name": { "type": "string" }
                  },
                  "required": ["name"]
                },
                "dog": {
                  "type": "object",
                  "properties": {
                    "barks": { "type": "boolean" }
                  },
                  "required": ["barks"]
                }
              }
            }
            """
        )

        #expect(output.contains("public let payload: JSONSchemaValue?"))
        #expect(output.contains("public enum JSONSchemaDocumentPayloadComposite: Hashable, Sendable {"))
        #expect(output.contains("case cat(JSONSchemaCat)"))
        #expect(output.contains("case dog(JSONSchemaDog)"))
        #expect(output.contains("public var payloadTyped: JSONSchemaDocumentPayloadComposite?"))
    }

    @Test
    func anyOfPropertiesDecodeTypedMembersInSchemaOrder() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "payload": {
                  "anyOf": [
                    { "type": "number" },
                    { "type": "integer" }
                  ]
                }
              }
            }
            """
        )

        let doubleDecode = "value.decodedCompositeValue(as: Double.self)"
        let intDecode = "value.decodedCompositeValue(as: Int.self)"

        #expect(output.contains("public enum JSONSchemaDocumentPayloadComposite: Hashable, Sendable {"))
        #expect(output.contains("case number(Double)"))
        #expect(output.contains("case integer(Int)"))
        #expect(output.range(of: doubleDecode)?.lowerBound ?? output.endIndex < output.range(of: intDecode)?.lowerBound ?? output.startIndex)
    }

    @Test
    func allOfPropertiesGenerateMergedCompositeHelpers() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "payload": {
                  "allOf": [
                    { "$ref": "#/definitions/base" },
                    { "$ref": "#/definitions/details" }
                  ]
                }
              },
              "definitions": {
                "base": {
                  "type": "object",
                  "properties": {
                    "id": { "type": "string" }
                  },
                  "required": ["id"]
                },
                "details": {
                  "type": "object",
                  "properties": {
                    "count": { "type": "integer" }
                  },
                  "required": ["count"]
                }
              }
            }
            """
        )

        #expect(output.contains("public let payload: JSONSchemaValue?"))
        #expect(output.contains("public struct JSONSchemaDocumentPayloadComposite: Hashable, Sendable {"))
        #expect(output.contains("public let base: JSONSchemaBase"))
        #expect(output.contains("public let details: JSONSchemaDetails"))
        #expect(output.contains("public static func from(_ value: JSONSchemaValue) -> Self?"))
        #expect(output.contains("public var payloadTyped: JSONSchemaDocumentPayloadComposite?"))
    }

    @Test
    func compositeInlineObjectMembersGenerateNamedSwiftTypes() throws {
        let output = try render(
            """
            {
              "type": "object",
              "properties": {
                "payload": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": {
                        "name": { "type": "string" }
                      },
                      "required": ["name"]
                    },
                    { "type": "string" }
                  ]
                }
              }
            }
            """
        )

        #expect(output.contains("public struct JSONSchemaDocumentPayloadCompositeObject1: Codable, Hashable, Sendable {"))
        #expect(output.contains("case object1(JSONSchemaDocumentPayloadCompositeObject1)"))
        #expect(output.contains("case string(String)"))
    }

    @Test
    func compositeRootsGenerateRawAliasAndValueExtensions() throws {
        let output = try render(
            """
            {
              "oneOf": [
                { "$ref": "#/definitions/cat" },
                { "$ref": "#/definitions/dog" }
              ],
              "definitions": {
                "cat": {
                  "type": "object",
                  "properties": {
                    "name": { "type": "string" }
                  },
                  "required": ["name"]
                },
                "dog": {
                  "type": "object",
                  "properties": {
                    "barks": { "type": "boolean" }
                  },
                  "required": ["barks"]
                }
              }
            }
            """
        )

        #expect(output.contains("public typealias JSONSchemaDocument = JSONSchemaValue"))
        #expect(output.contains("public enum JSONSchemaDocumentComposite: Hashable, Sendable {"))
        #expect(output.contains("public extension JSONSchemaValue {"))
        #expect(output.contains("var asJSONSchemaDocumentComposite: JSONSchemaDocumentComposite?"))
    }

    private func render(_ schema: String) throws -> String {
        try generator.generateOutput(
            schemaData: Data(schema.utf8),
            configuration: GeneratorConfiguration(schema: "schema.json")
        )
    }
}
