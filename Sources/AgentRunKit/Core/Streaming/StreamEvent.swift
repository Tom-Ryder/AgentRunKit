import Foundation

/// Streamed event envelope with identity, session context, and semantic payload; see <doc:StreamingAndSwiftUI>.
public struct StreamEvent: Sendable, Identifiable {
    public let id: EventID
    public let timestamp: Date
    public let sessionID: SessionID?
    public let runID: RunID?
    public let parentEventID: EventID?
    public let origin: EventOrigin
    public let kind: Kind

    public init(
        id: EventID = EventID(),
        timestamp: Date = Date(),
        sessionID: SessionID? = nil,
        runID: RunID? = nil,
        parentEventID: EventID? = nil,
        origin: EventOrigin = .live,
        kind: Kind
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.runID = runID
        self.parentEventID = parentEventID
        self.origin = origin
        self.kind = kind
    }

    static func make(
        _ kind: Kind,
        sessionID: SessionID? = nil,
        runID: RunID? = nil,
        parentEventID: EventID? = nil,
        origin: EventOrigin = .live
    ) -> StreamEvent {
        StreamEvent(
            sessionID: sessionID,
            runID: runID,
            parentEventID: parentEventID,
            origin: origin,
            kind: kind
        )
    }

    func with(origin: EventOrigin) -> StreamEvent {
        StreamEvent(
            id: id,
            timestamp: timestamp,
            sessionID: sessionID,
            runID: runID,
            parentEventID: parentEventID,
            origin: origin,
            kind: kind
        )
    }

    /// Semantic event payload independent of envelope identity.
    ///
    /// Equality compares payloads only. For ``subAgentEvent(toolCallId:toolName:event:)``,
    /// nested child envelope metadata is ignored and only the child `kind` participates.
    public enum Kind: Sendable {
        case delta(String)
        case reasoningDelta(String)
        case toolCallStarted(name: String, id: String)
        case toolCallCompleted(id: String, name: String, result: ToolResult)
        case audioData(Data)
        case audioTranscript(String)
        case audioFinished(id: String, expiresAt: Int, data: Data)
        case finished(tokenUsage: TokenUsage, content: String?, reason: FinishReason?, history: [ChatMessage])
        case subAgentStarted(toolCallId: String, toolName: String)
        indirect case subAgentEvent(toolCallId: String, toolName: String, event: StreamEvent)
        case subAgentCompleted(toolCallId: String, toolName: String, result: ToolResult)
        case iterationCompleted(usage: TokenUsage, iteration: Int, history: [ChatMessage])
        case compacted(totalTokens: Int, windowSize: Int)
        /// Emitted after each provider response when a budget snapshot is available.
        case budgetUpdated(budget: ContextBudget)
        /// Emitted once when the configured soft threshold is crossed.
        case budgetAdvisory(budget: ContextBudget)
        case toolApprovalRequested(ToolApprovalRequest)
        case toolApprovalResolved(toolCallId: String, decision: ToolApprovalDecision)
    }
}

// MARK: - Kind Equatable

extension StreamEvent.Kind: Equatable {
    // swiftlint:disable:next cyclomatic_complexity
    public static func == (lhs: StreamEvent.Kind, rhs: StreamEvent.Kind) -> Bool {
        switch (lhs, rhs) {
        case let (.delta(lhsText), .delta(rhsText)):
            lhsText == rhsText
        case let (.reasoningDelta(lhsText), .reasoningDelta(rhsText)):
            lhsText == rhsText
        case let (.toolCallStarted(lhsName, lhsID), .toolCallStarted(rhsName, rhsID)):
            lhsName == rhsName && lhsID == rhsID
        case let (.toolCallCompleted(lhsID, lhsName, lhsResult), .toolCallCompleted(rhsID, rhsName, rhsResult)):
            lhsID == rhsID && lhsName == rhsName && lhsResult == rhsResult
        case let (.audioData(lhsData), .audioData(rhsData)):
            lhsData == rhsData
        case let (.audioTranscript(lhsText), .audioTranscript(rhsText)):
            lhsText == rhsText
        case let (.audioFinished(lhsID, lhsExpires, lhsData), .audioFinished(rhsID, rhsExpires, rhsData)):
            lhsID == rhsID && lhsExpires == rhsExpires && lhsData == rhsData
        case let (.finished(lhsUsage, lhsContent, lhsReason, lhsHistory),
                  .finished(rhsUsage, rhsContent, rhsReason, rhsHistory)):
            lhsUsage == rhsUsage && lhsContent == rhsContent && lhsReason == rhsReason && lhsHistory == rhsHistory
        case let (.subAgentStarted(lhsID, lhsName), .subAgentStarted(rhsID, rhsName)):
            lhsID == rhsID && lhsName == rhsName
        case let (.subAgentEvent(lhsID, lhsName, lhsEvent), .subAgentEvent(rhsID, rhsName, rhsEvent)):
            lhsID == rhsID && lhsName == rhsName && lhsEvent.kind == rhsEvent.kind
        case let (.subAgentCompleted(lhsID, lhsName, lhsResult), .subAgentCompleted(rhsID, rhsName, rhsResult)):
            lhsID == rhsID && lhsName == rhsName && lhsResult == rhsResult
        case let (.iterationCompleted(lhsUsage, lhsIter, lhsHistory),
                  .iterationCompleted(rhsUsage, rhsIter, rhsHistory)):
            lhsUsage == rhsUsage && lhsIter == rhsIter && lhsHistory == rhsHistory
        case let (.compacted(lhsTokens, lhsWindow), .compacted(rhsTokens, rhsWindow)):
            lhsTokens == rhsTokens && lhsWindow == rhsWindow
        case let (.budgetUpdated(lhsBudget), .budgetUpdated(rhsBudget)):
            lhsBudget == rhsBudget
        case let (.budgetAdvisory(lhsBudget), .budgetAdvisory(rhsBudget)):
            lhsBudget == rhsBudget
        case let (.toolApprovalRequested(lhsReq), .toolApprovalRequested(rhsReq)):
            lhsReq == rhsReq
        case let (.toolApprovalResolved(lhsID, lhsDecision), .toolApprovalResolved(rhsID, rhsDecision)):
            lhsID == rhsID && lhsDecision == rhsDecision
        default: false
        }
    }
}

// MARK: - Kind Codable

extension StreamEvent.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text, name, id, result, data, expiresAt
        case tokenUsage, content, reason, history
        case toolCallId, toolName, event
        case usage, iteration
        case totalTokens, windowSize
        case budget
        case request, decision
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "delta":
            self = try .delta(container.decode(String.self, forKey: .text))
        case "reasoningDelta":
            self = try .reasoningDelta(container.decode(String.self, forKey: .text))
        case "toolCallStarted":
            self = try .toolCallStarted(
                name: container.decode(String.self, forKey: .name),
                id: container.decode(String.self, forKey: .id)
            )
        case "toolCallCompleted":
            self = try .toolCallCompleted(
                id: container.decode(String.self, forKey: .id),
                name: container.decode(String.self, forKey: .name),
                result: container.decode(ToolResult.self, forKey: .result)
            )
        case "audioData":
            self = try .audioData(container.decode(Data.self, forKey: .data))
        case "audioTranscript":
            self = try .audioTranscript(container.decode(String.self, forKey: .text))
        case "audioFinished":
            self = try .audioFinished(
                id: container.decode(String.self, forKey: .id),
                expiresAt: container.decode(Int.self, forKey: .expiresAt),
                data: container.decode(Data.self, forKey: .data)
            )
        case "finished":
            self = try .finished(
                tokenUsage: container.decode(TokenUsage.self, forKey: .tokenUsage),
                content: container.decodeIfPresent(String.self, forKey: .content),
                reason: container.decodeIfPresent(FinishReason.self, forKey: .reason),
                history: container.decode([ChatMessage].self, forKey: .history)
            )
        case "subAgentStarted":
            self = try .subAgentStarted(
                toolCallId: container.decode(String.self, forKey: .toolCallId),
                toolName: container.decode(String.self, forKey: .toolName)
            )
        case "subAgentEvent":
            self = try .subAgentEvent(
                toolCallId: container.decode(String.self, forKey: .toolCallId),
                toolName: container.decode(String.self, forKey: .toolName),
                event: container.decode(StreamEvent.self, forKey: .event)
            )
        case "subAgentCompleted":
            self = try .subAgentCompleted(
                toolCallId: container.decode(String.self, forKey: .toolCallId),
                toolName: container.decode(String.self, forKey: .toolName),
                result: container.decode(ToolResult.self, forKey: .result)
            )
        case "iterationCompleted":
            let history: [ChatMessage] = container.contains(.history)
                ? try container.decode([ChatMessage].self, forKey: .history)
                : []
            self = try .iterationCompleted(
                usage: container.decode(TokenUsage.self, forKey: .usage),
                iteration: container.decode(Int.self, forKey: .iteration),
                history: history
            )
        case "compacted":
            self = try .compacted(
                totalTokens: container.decode(Int.self, forKey: .totalTokens),
                windowSize: container.decode(Int.self, forKey: .windowSize)
            )
        case "budgetUpdated":
            self = try .budgetUpdated(budget: container.decode(ContextBudget.self, forKey: .budget))
        case "budgetAdvisory":
            self = try .budgetAdvisory(budget: container.decode(ContextBudget.self, forKey: .budget))
        case "toolApprovalRequested":
            self = try .toolApprovalRequested(container.decode(ToolApprovalRequest.self, forKey: .request))
        case "toolApprovalResolved":
            self = try .toolApprovalResolved(
                toolCallId: container.decode(String.self, forKey: .toolCallId),
                decision: container.decode(ToolApprovalDecision.self, forKey: .decision)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown StreamEvent.Kind type: \(type)"
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .delta(text):
            try container.encode("delta", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .reasoningDelta(text):
            try container.encode("reasoningDelta", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .toolCallStarted(name, id):
            try container.encode("toolCallStarted", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(id, forKey: .id)
        case let .toolCallCompleted(id, name, result):
            try container.encode("toolCallCompleted", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(result, forKey: .result)
        case let .audioData(data):
            try container.encode("audioData", forKey: .type)
            try container.encode(data, forKey: .data)
        case let .audioTranscript(text):
            try container.encode("audioTranscript", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .audioFinished(id, expiresAt, data):
            try container.encode("audioFinished", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(expiresAt, forKey: .expiresAt)
            try container.encode(data, forKey: .data)
        case let .finished(tokenUsage, content, reason, history):
            try container.encode("finished", forKey: .type)
            try container.encode(tokenUsage, forKey: .tokenUsage)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encode(history, forKey: .history)
        case let .subAgentStarted(toolCallId, toolName):
            try container.encode("subAgentStarted", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
        case let .subAgentEvent(toolCallId, toolName, event):
            try container.encode("subAgentEvent", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(event, forKey: .event)
        case let .subAgentCompleted(toolCallId, toolName, result):
            try container.encode("subAgentCompleted", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(result, forKey: .result)
        case let .iterationCompleted(usage, iteration, history):
            try container.encode("iterationCompleted", forKey: .type)
            try container.encode(usage, forKey: .usage)
            try container.encode(iteration, forKey: .iteration)
            try container.encode(history, forKey: .history)
        case let .compacted(totalTokens, windowSize):
            try container.encode("compacted", forKey: .type)
            try container.encode(totalTokens, forKey: .totalTokens)
            try container.encode(windowSize, forKey: .windowSize)
        case let .budgetUpdated(budget):
            try container.encode("budgetUpdated", forKey: .type)
            try container.encode(budget, forKey: .budget)
        case let .budgetAdvisory(budget):
            try container.encode("budgetAdvisory", forKey: .type)
            try container.encode(budget, forKey: .budget)
        case let .toolApprovalRequested(request):
            try container.encode("toolApprovalRequested", forKey: .type)
            try container.encode(request, forKey: .request)
        case let .toolApprovalResolved(toolCallId, decision):
            try container.encode("toolApprovalResolved", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(decision, forKey: .decision)
        }
    }
}

// MARK: - StreamEvent Codable

extension StreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sessionID, runID, parentEventID, origin, kind
    }

    private static let timestampCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(EventID.self, forKey: .id)
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        guard let parsedTimestamp = Self.decodeTimestamp(timestampString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: container,
                debugDescription: "Invalid ISO 8601 timestamp: \(timestampString)"
            )
        }
        timestamp = parsedTimestamp
        sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        runID = try container.decodeIfPresent(RunID.self, forKey: .runID)
        parentEventID = try container.decodeIfPresent(EventID.self, forKey: .parentEventID)
        origin = container.contains(.origin) ? try container.decode(EventOrigin.self, forKey: .origin) : .live
        kind = try container.decode(Kind.self, forKey: .kind)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        let timestamp = try Self.encodeTimestamp(
            timestamp,
            codingPath: container.codingPath + [CodingKeys.timestamp]
        )
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(parentEventID, forKey: .parentEventID)
        if case .replayed = origin {
            try container.encode(origin, forKey: .origin)
        }
        try container.encode(kind, forKey: .kind)
    }

    private static func decodeTimestamp(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count == 24,
              bytes[4] == UInt8(ascii: "-"),
              bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"),
              bytes[19] == UInt8(ascii: "."),
              bytes[23] == UInt8(ascii: "Z")
        else {
            return nil
        }

        guard let year = parseInteger(bytes, in: 0 ..< 4),
              let month = parseInteger(bytes, in: 5 ..< 7),
              let day = parseInteger(bytes, in: 8 ..< 10),
              let hour = parseInteger(bytes, in: 11 ..< 13),
              let minute = parseInteger(bytes, in: 14 ..< 16),
              let second = parseInteger(bytes, in: 17 ..< 19),
              let millisecond = parseInteger(bytes, in: 20 ..< 23)
        else {
            return nil
        }

        var components = DateComponents()
        components.calendar = timestampCalendar
        components.timeZone = timestampCalendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let wholeSecondDate = timestampCalendar.date(from: components) else {
            return nil
        }

        let normalizedComponents = timestampCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: wholeSecondDate
        )
        guard normalizedComponents.year == year,
              normalizedComponents.month == month,
              normalizedComponents.day == day,
              normalizedComponents.hour == hour,
              normalizedComponents.minute == minute,
              normalizedComponents.second == second
        else {
            return nil
        }

        return Date(timeIntervalSince1970: wholeSecondDate.timeIntervalSince1970 + TimeInterval(millisecond) / 1000)
    }

    private static func encodeTimestamp(_ date: Date, codingPath: [any CodingKey]) throws -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "StreamEvent timestamps must fit in canonical Int64 milliseconds"
                )
            )
        }

        var seconds = Int64(milliseconds) / 1000
        var millisecond = Int(Int64(milliseconds) % 1000)
        if millisecond < 0 {
            seconds -= 1
            millisecond += 1000
        }

        let wholeSecondDate = Date(timeIntervalSince1970: TimeInterval(seconds))
        let components = timestampCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: wholeSecondDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Failed to derive UTC timestamp components"
                )
            )
        }

        guard (0 ... 9999).contains(year) else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "StreamEvent timestamps must use a four-digit UTC year"
                )
            )
        }

        return padded(year, width: 4)
            + "-" + padded(month, width: 2)
            + "-" + padded(day, width: 2)
            + "T" + padded(hour, width: 2)
            + ":" + padded(minute, width: 2)
            + ":" + padded(second, width: 2)
            + "." + padded(millisecond, width: 3)
            + "Z"
    }

    private static func parseInteger(_ bytes: [UInt8], in range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            let digit = bytes[index] - UInt8(ascii: "0")
            guard digit <= 9 else {
                return nil
            }
            value = (value * 10) + Int(digit)
        }
        return value
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let string = String(value)
        if string.count >= width {
            return string
        }
        return String(repeating: "0", count: width - string.count) + string
    }
}
