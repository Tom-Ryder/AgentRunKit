import Foundation

/// An LLM client for Anthropic models on Google Vertex AI.
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
        anthropicReasoning: AnthropicReasoningOptions = .manual,
        interleavedThinking: Bool = true,
        cachingEnabled: Bool = false,
        cacheControlTTL: CacheControlTTL? = nil
    ) throws {
        self.projectID = projectID
        self.location = location
        modelIdentifier = model
        self.tokenProvider = tokenProvider
        self.session = session
        self.retryPolicy = retryPolicy
        self.contextWindowSize = contextWindowSize
        anthropic = try AnthropicClient(
            apiKey: "",
            model: model,
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            interleavedThinking: interleavedThinking,
            cachingEnabled: cachingEnabled,
            cacheControlTTL: cacheControlTTL,
            capabilityTransport: .vertex
        )
    }

    @available(
        iOS,
        unavailable,
        message: "Use the tokenProvider initializer to supply access tokens."
    )
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
        anthropicReasoning: AnthropicReasoningOptions = .manual,
        interleavedThinking: Bool = true,
        cachingEnabled: Bool = false,
        cacheControlTTL: CacheControlTTL? = nil
    ) throws {
        try self.init(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { try await authService.accessToken() },
            maxTokens: maxTokens,
            contextWindowSize: contextWindowSize,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig,
            anthropicReasoning: anthropicReasoning,
            interleavedThinking: interleavedThinking,
            cachingEnabled: cachingEnabled,
            cacheControlTTL: cacheControlTTL
        )
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try messages.validateForLLMRequest()
        let request = try anthropic.buildRequest(
            messages: messages,
            tools: tools,
            transport: .vertex,
            responseFormat: responseFormat,
            toolChoice: requestContext?.anthropic?.toolChoice,
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
                        toolChoice: requestContext?.anthropic?.toolChoice,
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
        toolChoice: AnthropicToolChoice?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try anthropic.buildRequest(
            messages: messages, tools: tools,
            stream: true, transport: .vertex, toolChoice: toolChoice, extraFields: extraFields
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
        ) { event in
            try await anthropic.handleSSEEvent(
                event, state: state, continuation: continuation
            )
        }
        continuation.finish()
    }

    private func performRunStreamRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        toolChoice: AnthropicToolChoice?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<RunStreamElement, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try anthropic.buildRequest(
            messages: messages, tools: tools,
            stream: true, transport: .vertex, toolChoice: toolChoice, extraFields: extraFields
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
        ) { event in
            try await anthropic.handleSSEEvent(event, state: state) { delta in
                continuation.yield(.delta(delta))
            }
        }

        if await state.isCompleted {
            let blocks = try await state.finalizedBlocks()
            if await state.supportsReplayContinuity(), !blocks.isEmpty {
                let projection = AnthropicTurnProjection(orderedBlocks: blocks)
                continuation.yield(.finalizedContinuity(projection.continuity))
            }
        }
        continuation.finish()
    }

    func buildVertexURLRequest(
        _ request: VertexAnthropicRequest,
        stream: Bool,
        token: String
    ) throws -> URLRequest {
        guard let modelIdentifier else {
            throw AgentError.llmError(.other("Vertex model identifier is required"))
        }
        let action = stream ? "streamRawPredict" : "rawPredict"
        let basePath = "v1/projects/\(projectID)/locations/\(location)"
            + "/publishers/anthropic/models/\(modelIdentifier):\(action)"
        let host =
            if location == "global" {
                "https://aiplatform.googleapis.com"
            } else {
                "https://\(location)-aiplatform.googleapis.com"
            }
        guard let baseURL = URL(string: host) else {
            throw AgentError.llmError(.other("Invalid Vertex AI location: \(location)"))
        }
        let url = baseURL.appendingPathComponent(basePath)

        var headers = ["Authorization": "Bearer \(token)"]
        anthropic.applyBetaHeaders(for: request.inner, into: &headers)
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }
}

extension VertexAnthropicClient: HistoryRewriteAwareClient {
    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?,
        requestMode _: RunRequestMode
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performRunStreamRequest(
                        messages: messages,
                        tools: tools,
                        toolChoice: requestContext?.anthropic?.toolChoice,
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
}

extension VertexAnthropicClient: ContentOnlyTerminatingClient {}

struct VertexAnthropicRequest: Encodable {
    static let vertexAnthropicVersion = "vertex-2023-10-16"

    let inner: AnthropicRequest

    func encode(to encoder: any Encoder) throws {
        // Model goes in the URL path, not the body.
        var withoutModel = inner
        withoutModel.model = nil
        try withoutModel.encode(to: encoder)
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(
            Self.vertexAnthropicVersion,
            forKey: DynamicCodingKey("anthropic_version")
        )
    }
}
