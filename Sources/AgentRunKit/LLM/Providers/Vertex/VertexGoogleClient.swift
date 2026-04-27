import Foundation

/// An LLM client for Google models on Vertex AI.
public struct VertexGoogleClient: LLMClient, Sendable {
    public let modelIdentifier: String?
    public let contextWindowSize: Int?
    public let providerIdentifier: ProviderIdentifier = .vertexGoogle

    let gemini: GeminiClient
    private let projectID: String
    private let location: String
    private let apiVersion: String
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(
        projectID: String,
        location: String,
        model: String,
        tokenProvider: @Sendable @escaping () async throws -> String,
        maxOutputTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        apiVersion: String = "v1beta1",
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil
    ) {
        self.projectID = projectID
        self.location = location
        modelIdentifier = model
        self.apiVersion = apiVersion
        self.tokenProvider = tokenProvider
        self.session = session
        self.retryPolicy = retryPolicy
        self.contextWindowSize = contextWindowSize
        gemini = GeminiClient(
            apiKey: "",
            model: model,
            maxOutputTokens: maxOutputTokens,
            contextWindowSize: contextWindowSize,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig
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
        maxOutputTokens: Int = 8192,
        contextWindowSize: Int? = nil,
        apiVersion: String = "v1beta1",
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        reasoningConfig: ReasoningConfig? = nil
    ) {
        self.init(
            projectID: projectID,
            location: location,
            model: model,
            tokenProvider: { try await authService.accessToken() },
            maxOutputTokens: maxOutputTokens,
            contextWindowSize: contextWindowSize,
            apiVersion: apiVersion,
            session: session,
            retryPolicy: retryPolicy,
            reasoningConfig: reasoningConfig
        )
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        try messages.validateForLLMRequest()
        let request = try gemini.buildRequest(
            messages: messages,
            tools: tools,
            responseFormat: responseFormat,
            functionCallingMode: requestContext?.gemini?.functionCallingMode ?? .auto,
            allowedFunctionNames: requestContext?.gemini?.allowedFunctionNames,
            extraFields: requestContext?.extraFields ?? [:]
        )
        let token = try await tokenProvider()
        let urlRequest = try buildVertexURLRequest(request, stream: false, token: token)
        let (data, httpResponse) = try await HTTPRetry.performData(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        requestContext?.onResponse?(httpResponse)
        return try gemini.parseResponse(data)
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
                        functionCallingMode: requestContext?.gemini?.functionCallingMode ?? .auto,
                        allowedFunctionNames: requestContext?.gemini?.allowedFunctionNames,
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
        functionCallingMode: GeminiFunctionCallingMode,
        allowedFunctionNames: [String]?,
        extraFields: [String: JSONValue],
        onResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        try messages.validateForLLMRequest()
        let request = try gemini.buildRequest(
            messages: messages,
            tools: tools,
            functionCallingMode: functionCallingMode,
            allowedFunctionNames: allowedFunctionNames,
            extraFields: extraFields
        )
        let token = try await tokenProvider()
        let urlRequest = try buildVertexURLRequest(request, stream: true, token: token)
        let (bytes, httpResponse) = try await HTTPRetry.performStream(
            urlRequest: urlRequest, session: session, retryPolicy: retryPolicy
        )
        onResponse?(httpResponse)

        let state = GeminiStreamState()

        try await processSSEStream(
            bytes: bytes,
            stallTimeout: retryPolicy.streamStallTimeout
        ) { event, _ in
            try await gemini.handleSSEEvent(
                event, state: state, providerIdentifier: providerIdentifier, continuation: continuation
            )
        }
        continuation.finish()
    }

    func buildVertexURLRequest(
        _ request: GeminiRequest,
        stream: Bool,
        token: String
    ) throws -> URLRequest {
        guard let modelIdentifier else {
            throw AgentError.llmError(.other("Vertex model identifier is required"))
        }
        let action = stream ? "streamGenerateContent" : "generateContent"
        let basePath = "\(apiVersion)/projects/\(projectID)/locations/\(location)"
            + "/publishers/google/models/\(modelIdentifier):\(action)"
        let host =
            if location == "global" {
                "https://aiplatform.googleapis.com"
            } else {
                "https://\(location)-aiplatform.googleapis.com"
            }
        guard let baseURL = URL(string: host) else {
            throw AgentError.llmError(.other("Invalid Vertex AI location: \(location)"))
        }
        var url = baseURL.appendingPathComponent(basePath)

        if stream {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw AgentError.llmError(.other("Failed to parse URL components from: \(url)"))
            }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let streamURL = components.url else {
                throw AgentError.llmError(.other("Failed to construct URL with query items"))
            }
            url = streamURL
        }

        let headers = ["Authorization": "Bearer \(token)"]
        return try buildJSONPostRequest(url: url, body: request, headers: headers)
    }
}
