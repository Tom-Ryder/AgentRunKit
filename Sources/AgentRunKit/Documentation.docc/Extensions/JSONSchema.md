# ``AgentRunKit/JSONSchema``

See <doc:LLMProviders#Request-Serialization> for object ordering in HTTP requests and the boundary with caller-owned encoders.

## Topics

### Schema Types

- ``string(description:enumValues:)``
- ``integer(description:)``
- ``number(description:)``
- ``boolean(description:)``
- ``array(items:description:)``
- ``object(properties:required:description:)``
- ``null``
- ``anyOf(_:)``

### Modifiers

- ``optional()``
