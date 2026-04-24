# ``AgentRunKit/StreamEvent``

Stable envelope for a streamed event.

Each event carries identity, timing, and provenance metadata around a semantic ``StreamEvent/Kind`` payload. Transcript order is the order of emission, not the timestamp sort order. ``StreamEvent/origin`` distinguishes live emission from replayed checkpoint events; see <doc:CheckpointAndResume>.

## Topics

### Envelope

- ``init(id:timestamp:sessionID:runID:parentEventID:origin:kind:)``
- ``id``
- ``timestamp``
- ``sessionID``
- ``runID``
- ``parentEventID``
- ``origin``
- ``kind``

### Provenance

- ``EventOrigin``

### Semantic Payload

- ``StreamEvent/Kind``
