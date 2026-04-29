# Multimodal and Audio

Send images, video, PDFs, and audio as input. Stream audio output from the model. Generate speech with ``TTSClient``.

## Multimodal Input

``ContentPart`` represents a single piece of content within a user message. Six variants cover text and media:

| Variant | Factory Method |
|---|---|
| `.text(String)` | Direct case |
| `.imageURL(String)` | ``ContentPart/image(url:)`` |
| `.imageBase64(data:mimeType:)` | ``ContentPart/image(data:mimeType:)`` |
| `.videoBase64(data:mimeType:)` | ``ContentPart/video(data:mimeType:)`` |
| `.pdfBase64(data:)` | ``ContentPart/pdf(data:)`` |
| `.audioBase64(data:format:)` | ``ContentPart/audio(data:format:)`` |

Build multimodal messages with ``ChatMessage`` convenience methods:

```swift
// Image from URL
let msg = ChatMessage.user(text: "Describe this image.", imageURL: "https://example.com/photo.jpg")

// Image from raw bytes
let msg = ChatMessage.user(text: "What's in this photo?", imageData: jpegData, mimeType: "image/jpeg")

// Video
let msg = ChatMessage.user(text: "Summarize this clip.", videoData: mp4Data, mimeType: "video/mp4")

// Audio with text prompt
let msg = ChatMessage.user(text: "Transcribe this.", audioData: wavData, format: .wav)

// Audio only
let msg = ChatMessage.user(audioData: wavData, format: .wav)
```

For full control, pass an array of ``ContentPart`` values directly:

```swift
let msg = ChatMessage.user([
    .text("Compare these two images."),
    .image(url: "https://example.com/a.jpg"),
    .image(data: localPNG, mimeType: "image/png"),
])
```

``AudioInputFormat`` supports: `wav`, `mp3`, `m4a`, `flac`, `ogg`, `opus`, `webm`. Each case provides a `mimeType` property for wire format encoding.

## Per-Provider Encoding

Each client encodes ``ContentPart`` onto its native wire format. Encoding and accepted media types vary:

| Provider | Images | Audio | Video | PDF | Wire format |
|---|---|---|---|---|---|
| ``OpenAIClient`` | URL, base64 | Yes | No | No | `content: [{type: "image_url" \| ...}]` |
| ``ResponsesAPIClient`` | URL, base64 | No | No | No | `content: [{type: "input_image" \| ...}]` |
| ``AnthropicClient`` | base64 | No | No | base64 | `content: [{type: "image" \| "document", source: {type: "base64", media_type, data}}]` |
| ``VertexAnthropicClient`` | base64 | No | No | base64 | same as ``AnthropicClient`` |
| ``GeminiClient`` | base64 | base64 | base64 | base64 | `parts: [{inlineData: {mimeType, data}}]` |
| ``VertexGoogleClient`` | base64 | base64 | base64 | base64 | same as ``GeminiClient`` |

Anthropic and Gemini reject raw image URLs because neither provider fetches external URLs server-side. Passing an `.imageURL` part to either client throws ``TransportError/featureUnsupported(provider:feature:)`` at request build. Fetch the bytes yourself and pass them as `.imageBase64`.

## Audio Streaming Output

Some providers (OpenAI) can stream audio alongside text. Three ``StreamEvent`` cases carry audio data:

| Event | Description |
|---|---|
| `.audioData(Data)` | A chunk of audio bytes, delivered incrementally |
| `.audioTranscript(String)` | Text transcript of the generated audio |
| `.audioFinished(id:expiresAt:data:)` | Final audio payload with metadata |

Enable audio output by passing `modalities` and `audio` configuration through ``RequestContext`` extra fields:

```swift
let requestContext = RequestContext(extraFields: [
    "modalities": .array([.string("text"), .string("audio")]),
    "audio": .object([
        "voice": .string("alloy"),
        "format": .string("pcm16"),
    ]),
])

for try await event in agent.stream(userMessage: "Tell me a story.", context: ctx, requestContext: requestContext) {
    switch event.kind {
    case .audioData(let chunk):
        audioPlayer.enqueue(chunk)
    case .audioTranscript(let text):
        print(text)
    case .audioFinished(_, _, let fullAudio):
        audioPlayer.finalize(fullAudio)
    default:
        break
    }
}
```

## Text-to-Speech

``TTSClient`` generates speech from text using any ``TTSProvider``. It handles chunking, concurrent generation, and ordered reassembly.

### Setup

```swift
let provider = OpenAITTSProvider(apiKey: "sk-...", model: "gpt-4o-mini-tts")
let tts = TTSClient(provider: provider, maxConcurrent: 4)
```

``OpenAITTSProvider`` accepts `baseURL`, `maxChunkCharacters`, `defaultVoice`, and `defaultFormat` in its initializer. AgentRunKit currently defaults the `model` parameter to `tts-1`, but OpenAI's current recommended speech-generation model is `gpt-4o-mini-tts`. The other defaults are voice `alloy`, format `.mp3`, and chunk size `4096`.

### Generating Audio

These methods cover different use cases:

| Method | Returns | Behavior |
|---|---|---|
| `generate(text:voice:options:)` | `Data` | Single request, no chunking |
| `stream(text:voice:options:)` | `AsyncThrowingStream<TTSSegment, Error>` | Chunked, yields ordered ``TTSSegment`` values as they complete |
| `generateAll(text:voice:options:)` | `Data` | Chunked, concatenates all segments into one `Data` |
| `generateWithManifest(text:voice:options:)` | ``TTSConcatenationResult`` | Like `generateAll` but also returns a per-segment manifest of chunk, encoding, and timing |
| `chunks(for:)` | `[TTSChunk]` | The chunk plan this client will use, without invoking the provider |

```swift
// Single generation
let audio = try await tts.generate(text: "Hello, world.", voice: "nova")

// Streaming segments
for try await segment in tts.stream(text: longArticle) {
    player.play(segment.audio)
    let chunk = segment.chunk
    print("chunk \(chunk.index + 1)/\(chunk.total) bytes \(chunk.sourceRange): \(chunk.text)")
}

// Full concatenated output
let fullAudio = try await tts.generateAll(text: longArticle, options: TTSOptions(speed: 1.25))

// Concatenated audio plus a per-segment manifest
let result = try await tts.generateWithManifest(text: longArticle, options: TTSOptions(responseFormat: .pcm))
for entry in result.manifest {
    if let range = entry.timing.byteRangeInConcatenatedAudio {
        print("chunk \(entry.chunk.index): bytes \(range) of result.audio")
    }
}

// Forecast the chunk plan without generating audio
let plan = tts.chunks(for: longArticle)
```

`generateWithManifest` populates ``TTSSegmentTiming/byteRangeInConcatenatedAudio`` for `pcm`
output today. Other formats leave it `nil` until the framework can compute byte ranges defensibly.
`generateAll` is implemented on top of the same path and returns `result.audio`.

`stream` segments always carry ``TTSSegmentTiming/uncomputed`` timing. Per-segment audio is the
raw chunk bytes, and final container offsets are only meaningful after concatenation.

### TTSOptions

``TTSOptions`` controls per-request parameters:

- `speed`: Playback speed multiplier. OpenAI accepts 0.25 to 4.0.
- `responseFormat`: Override the provider's default format. See ``TTSAudioFormat`` (`mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`).

### How Chunking Works

The chunker splits input text on sentence boundaries using `NLTokenizer`. Sentences are packed up to
the provider's `maxChunkCharacters` limit. Oversized sentences fall back to word-level, then
character-level splitting.

``TTSClient`` dispatches up to `maxConcurrent` chunk requests in parallel. Results are buffered and
yielded in original order.

Each ``TTSSegment`` carries a ``TTSChunk``, a ``TTSAudioEncoding``, a ``TTSSegmentTiming``, and the
audio bytes. The chunk, encoding, and timing fields are the canonical access path; flat properties
on ``TTSSegment`` forward to the chunk for compact logging.

For force-split chunks, `text` normalizes whitespace to single spaces while `sourceRange` covers the
span of the words it contains. That keeps ranges monotonic for caller-side highlighting and forced
alignment.

``TTSClient/chunks(for:)`` returns the same ``TTSChunk`` values the stream will emit, without calling
the provider. Use it to forecast chunk identity before generation or to drive offline planning.

``TTSConcatenationResult`` and ``TTSManifestEntry`` pair concatenated audio bytes with a per-segment
manifest of chunk, encoding, and timing.

For MP3 output, the concatenator strips ID3v2 headers, Xing/Info frames, and ID3v1 tails from interior segments for clean concatenation.

### Custom Providers

Conform to ``TTSProvider`` to use any speech synthesis backend. ``TTSClient`` delivers a ``TTSChunkContext`` carrying the chunk plan and requested encoding alongside each call. Providers should treat `context.encoding` as the authoritative source for the format to produce, and can additionally use it for logging or request correlation:

```swift
struct MyTTSProvider: TTSProvider {
    let config: TTSProviderConfig

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        let chunkID = "\(context.chunk.index + 1)/\(context.chunk.total)"
        log("synthesizing \(chunkID) as \(context.encoding.mimeType)")
        // Call your speech API and return audio bytes
    }
}

let provider = MyTTSProvider(config: TTSProviderConfig(
    maxChunkCharacters: 2000,
    defaultVoice: "default",
    defaultFormat: .wav
))
let tts = TTSClient(provider: provider)
```

For HTTP-backed providers, ``HTTPDataRetry`` exposes the same retry primitive
``OpenAITTSProvider`` uses: exponential backoff with jitter and `Retry-After`-aware handling of
429 responses. Pass a ``RetryPolicy`` and receive `(Data, HTTPURLResponse)` on success or a
``TransportError`` on failure; cancellation propagates through `CancellationError`.

```swift
let (data, response) = try await HTTPDataRetry.perform(
    urlRequest: request,
    session: .shared,
    retryPolicy: .default
)
```

## See Also

- <doc:AgentAndChat>
- <doc:LLMProviders>
- ``ContentPart``
- ``ChatMessage``
- ``AudioInputFormat``
- ``StreamEvent``
- ``TTSClient``
- ``TTSProvider``
- ``OpenAITTSProvider``
- ``TTSSegment``
- ``TTSSegmentTiming``
- ``TTSChunk``
- ``TTSChunkContext``
- ``TTSAudioEncoding``
- ``TTSManifestEntry``
- ``TTSConcatenationResult``
- ``TTSOptions``
- ``HTTPDataRetry``
