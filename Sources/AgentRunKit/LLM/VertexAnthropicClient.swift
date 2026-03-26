import Foundation

public struct VertexAnthropicClient: LLMClient, Sendable {
    public let modelIdentifier: String?
    public let contextWindowSize: Int?

    let anthropic: AnthropicClient
    private let projectID: String
    private let location: String
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(
        projectID: String,
        location: String,
        model: String,
        tokenProvider: @Sendable @escaping () async throws -> String,
        maxTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        interleavedThinking: Bool = true,
        cachingEnabled: Bool = false
    ) {
        self.projectID = projectID
        self.location = location
        modelIdentifier = model
        self.tokenProvider = tokenProvider
        self.session = session
        self.retryPolicy = retryPolicy
        self.contextWindowSize = contextWindowSize
        anthropic = AnthropicClient(
            apiKey: "",
            model: model,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            interleavedThinking: interleavedThinking,
            cachingEnabled: cachingEnabled
        )
    }

    public init(
        projectID: String,
        location: String,
        model: String,
        authService: GoogleAuthService,
        maxTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil,
        interleavedThinking: Bool = true,
        cachingEnabled: Bool = false
    ) {
        self.init(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { try await authService.accessToken() },
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            interleavedThinking: interleavedThinking,
            cachingEnabled: cachingEnabled
        )
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        if responseFormat != nil {
            throw AgentError.llmError(.other("VertexAnthropicClient does not support responseFormat"))
        }
        let request = try anthropic.buildRequest(
            messages: messages,
            tools: tools,
            extraFields: requestContext?.extraFields ?? [:]
        )
        let token = try await tokenProvider()
        let urlRequest = try buildVertexURLRequest(
            VertexAnthropicRequest(inner: request), stream: false, token: token
        )
        let (data, httpResponse) = try await HTTPRetry.performData(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        requestContext?.onResponse?(httpResponse)
        return try anthropic.parseResponse(data)
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStreamRequest(
                        messages: messages,
                        tools: tools,
                        extraFields: requestContext?.extraFields ?? [:],
                        onResponse: requestContext?.onResponse,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        let request = try anthropic.buildRequest(
            messages: messages, tools: tools,
            stream: true, extraFields: extraFields
        )
        let token = try await tokenProvider()
        let urlRequest = try buildVertexURLRequest(
            VertexAnthropicRequest(inner: request), stream: true, token: token
        )
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)

        let state = AnthropicStreamState()

        try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { line in
            try await anthropic.handleSSELine(
                line, state: state, continuation: continuation
            )
        }
        continuation.finish()
    }

    func buildVertexURLRequest(
        _ request: VertexAnthropicRequest,
        stream: Bool,
        token: String
    ) throws -> URLRequest {
        let action = stream ? "streamRawPredict" : "rawPredict"
        let basePath = "v1/projects/\(projectID)/locations/\(location)"
            + "/publishers/anthropic/models/\(modelIdentifier ?? ""):\(action)"
        guard let baseURL = URL(string: "https://\(location)-aiplatform.googleapis.com") else {
            throw AgentError.llmError(.other("Invalid Vertex AI location: \(location)"))
        }
        let url = baseURL.appendingPathComponent(basePath)

        let headers = ["Authorization": "Bearer \(token)"]
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }
}

struct VertexAnthropicRequest: Encodable {
    static let vertexAnthropicVersion = "vertex-2023-10-16"

    let inner: AnthropicRequest

    func encode(to encoder: any Encoder) throws {
        // Re-encode the inner request without the `model` field, which is
        // specified in the Vertex AI URL path and rejected in the body.
        let withoutModel = AnthropicRequest(
            model: nil,
            messages: inner.messages,
            system: inner.system,
            tools: inner.tools,
            maxTokens: inner.maxTokens,
            stream: inner.stream,
            thinking: inner.thinking,
            extraFields: inner.extraFields
        )
        try withoutModel.encode(to: encoder)
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(
            Self.vertexAnthropicVersion,
            forKey: DynamicCodingKey("anthropic_version")
        )
    }
}
