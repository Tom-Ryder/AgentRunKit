import Foundation

extension ResponsesAPIClient {
    struct ResponsesRequestBuildOptions {
        let tools: [ToolDefinition]
        let stream: Bool
        let responseFormat: ResponseFormat?
        let extraFields: [String: JSONValue]
        let requestOptions: ResponsesRequestOptions?
    }

    func mapMessages(_ messages: [ChatMessage]) throws -> (instructions: String?, input: [ResponsesInputItem]) {
        var instructions: [String] = []
        var input: [ResponsesInputItem] = []

        for message in messages {
            try appendResponsesMessage(message, instructions: &instructions, input: &input)
        }

        return (
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n"),
            input: input
        )
    }

    private func appendResponsesMessage(
        _ message: ChatMessage,
        instructions: inout [String],
        input: inout [ResponsesInputItem]
    ) throws {
        switch message {
        case let .system(text):
            instructions.append(text)
        case let .user(text):
            input.append(.userMessage(role: "user", content: .text(text)))
        case let .userMultimodal(parts):
            try input.append(.userMessage(role: "user", content: responsesUserMessageContent(for: parts)))
        case let .assistant(message):
            try appendResponsesAssistantMessage(message, input: &input)
        case let .tool(id, _, content):
            input.append(.functionCallOutput(ResponsesFunctionCallOutputItem(callId: id, output: content)))
        }
    }

    private func appendResponsesAssistantMessage(
        _ message: AssistantMessage,
        input: inout [ResponsesInputItem]
    ) throws {
        if let continuity = message.continuity, continuity.substrate == .responses {
            let replayState = try ResponsesReplayState(continuity: continuity)
            input.append(contentsOf: replayState.replayInputItems)
            return
        }

        if let reasoningDetails = message.reasoningDetails {
            input.append(contentsOf: reasoningDetails.map(ResponsesInputItem.reasoning))
        }

        if !message.content.isEmpty {
            input.append(.assistantMessage(ResponsesAssistantItem(
                content: [ResponsesOutputTextItem(text: message.content)]
            )))
        }

        for toolCall in message.toolCalls {
            input.append(.functionCall(ResponsesFunctionCallItem(
                callId: toolCall.id,
                name: toolCall.name,
                arguments: toolCall.arguments
            )))
        }
    }

    private func responsesUserMessageContent(for parts: [ContentPart]) throws -> ResponsesUserMessageContent {
        var textParts: [String] = []
        var items: [ResponsesInputContentItem] = []
        var includesMedia = false

        for part in parts {
            let item = try responsesInputContentItem(for: part)
            if case let .inputText(text) = item {
                textParts.append(text)
            } else {
                includesMedia = true
            }
            items.append(item)
        }

        return includesMedia ? .items(items) : .text(textParts.joined(separator: "\n"))
    }

    private func responsesInputContentItem(for part: ContentPart) throws -> ResponsesInputContentItem {
        switch part {
        case let .text(text):
            return .inputText(text)
        case let .imageURL(url):
            return .inputImageURL(url)
        case let .imageBase64(data, mimeType):
            return .inputImageURL("data:\(mimeType);base64,\(data.base64EncodedString())")
        case let .videoBase64(_, mimeType):
            throw AgentError.llmError(.featureUnsupported(provider: "responses", feature: "video (\(mimeType))"))
        case .pdfBase64:
            throw AgentError.llmError(.featureUnsupported(provider: "responses", feature: "pdf"))
        case let .audioBase64(_, format):
            throw AgentError.llmError(
                .featureUnsupported(provider: "responses", feature: "audio (\(format.rawValue))")
            )
        }
    }

    func buildFullRequest(
        messages: [ChatMessage],
        options: ResponsesRequestBuildOptions
    ) throws -> ResponsesRequest {
        let mappedMessages = try mapMessages(messages)
        return try buildResponsesRequest(
            instructions: mappedMessages.instructions,
            input: mappedMessages.input,
            previousResponseId: nil,
            options: options
        )
    }

    func buildDeltaRequest(
        messages: [ChatMessage],
        previousResponseId: String,
        suffixStart: Int,
        options: ResponsesRequestBuildOptions
    ) throws -> ResponsesRequest {
        let mappedMessages = try mapMessages(Array(messages[suffixStart...]))
        return try buildResponsesRequest(
            instructions: nil,
            input: mappedMessages.input,
            previousResponseId: previousResponseId,
            options: options
        )
    }

    private func buildResponsesRequest(
        instructions: String?,
        input: [ResponsesInputItem],
        previousResponseId: String?,
        options: ResponsesRequestBuildOptions
    ) throws -> ResponsesRequest {
        let include: [String]? = store ? nil : ["reasoning.encrypted_content"]
        let requestTools = responsesRequestTools(
            functionTools: options.tools,
            requestOptions: options.requestOptions
        )
        return ResponsesRequest(
            model: modelIdentifier,
            instructions: instructions,
            input: input,
            tools: requestTools.isEmpty ? nil : requestTools,
            stream: options.stream ? true : nil,
            maxOutputTokens: maxOutputTokens,
            text: options.responseFormat.map {
                ResponsesTextConfig(
                    format: ResponsesFormatConfig(
                        name: $0.schemaName,
                        strict: $0.isStrict,
                        schema: $0.schema
                    )
                )
            },
            store: store,
            reasoning: reasoningConfig.map(ResponsesReasoningConfig.init),
            include: include,
            previousResponseId: previousResponseId,
            extraFields: options.extraFields
        )
    }

    private func responsesRequestTools(
        functionTools: [ToolDefinition],
        requestOptions: ResponsesRequestOptions?
    ) -> [ResponsesToolDefinition] {
        let localTools = functionTools.map(ResponsesToolDefinition.init)
        let hostedTools = (requestOptions?.hostedTools ?? []).map(ResponsesToolDefinition.init(hosted:))
        return localTools + hostedTools
    }
}
