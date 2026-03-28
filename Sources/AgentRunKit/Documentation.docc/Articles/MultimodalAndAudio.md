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

``AudioInputFormat`` supports: `wav`, `mp3`, `m4a`, `flac`, `ogg`, `opus`, `webm`. Each case provides a `mimeType` property for wire format encoding. Provider support varies by model. See <doc:LLMProviders>.

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
    switch event {
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
let provider = OpenAITTSProvider(apiKey: "sk-...", model: "tts-1")
let tts = TTSClient(provider: provider, maxConcurrent: 4)
```

``OpenAITTSProvider`` accepts `baseURL`, `maxChunkCharacters`, `defaultVoice`, and `defaultFormat` in its initializer. The defaults are: model `tts-1`, voice `alloy`, format `.mp3`, chunk size `4096`.

### Generating Audio

Three methods cover different use cases:

| Method | Returns | Behavior |
|---|---|---|
| `generate(text:voice:options:)` | `Data` | Single request, no chunking |
| `stream(text:voice:options:)` | `AsyncThrowingStream<TTSSegment, Error>` | Chunked, yields ordered ``TTSSegment`` values as they complete |
| `generateAll(text:voice:options:)` | `Data` | Chunked, concatenates all segments into one `Data` |

```swift
// Single generation
let audio = try await tts.generate(text: "Hello, world.", voice: "nova")

// Streaming segments
for try await segment in tts.stream(text: longArticle) {
    player.play(segment.audio)  // segment.index, segment.total available
}

// Full concatenated output
let fullAudio = try await tts.generateAll(text: longArticle, options: TTSOptions(speed: 1.25))
```

### TTSOptions

``TTSOptions`` controls per-request parameters:

- `speed`: Playback speed multiplier. OpenAI accepts 0.25 to 4.0.
- `responseFormat`: Override the provider's default format. See ``TTSAudioFormat`` (`mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`).

### How Chunking Works

The chunker splits input text on sentence boundaries using `NLTokenizer`. Sentences are packed into chunks up to the provider's `maxChunkCharacters` limit. Oversized sentences fall back to word-level, then character-level splitting. ``TTSClient`` dispatches up to `maxConcurrent` chunk requests in parallel using a task group. Results are buffered and yielded in original order.

For MP3 output, the concatenator strips ID3v2 headers, Xing/Info frames, and ID3v1 tails from interior segments for clean concatenation.

### Custom Providers

Conform to ``TTSProvider`` to use any speech synthesis backend:

```swift
struct MyTTSProvider: TTSProvider {
    let config: TTSProviderConfig

    func generate(text: String, voice: String, options: TTSOptions) async throws -> Data {
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
- ``TTSOptions``
