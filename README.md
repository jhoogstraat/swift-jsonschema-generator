# swift-jsonschema-generator

`swift-jsonschema-generator` generates Swift `Codable` model types from JSON Schema documents.

It exposes:

- a reusable library target: `JSONSchemaToSwiftGeneratorCore`
- an executable: `swift-jsonschema-generator`
- a SwiftPM build tool plugin: `JSONSchemaToSwiftPlugin`

## Plugin Usage

Attach `JSONSchemaToSwiftPlugin` to a source target and place a `jsonschema-generator-config.json`
file in the root of that target directory.

Example configuration:

```json
{
  "schema": "compose-spec.json",
  "rootTypeName": "ComposeSpecDocument",
  "definitionTypePrefix": "ComposeSpec",
  "valueTypeName": "ComposeSpecValue",
  "accessLevel": "public"
}
```

The `schema` path is resolved relative to the target directory. Generated Swift is emitted into the
plugin work directory and compiled as part of the target.

The generator emits a concrete root `struct` for object schemas with properties, and a `typealias`
root when the schema root is a `$ref`, array, primitive, or map-like object.
