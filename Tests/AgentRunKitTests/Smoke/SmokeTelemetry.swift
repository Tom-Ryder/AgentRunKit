@testable import AgentRunKit
import Foundation

enum SmokeFailureKind: String, Codable {
    case assertionFailure
    case httpError
    case rateLimited
    case networkError
    case invalidResponse
    case encodingFailed
    case decodingFailed
    case noChoices
    case idleTimeout
    case providerTerminationMissing
    case finishedDeltaMissing
    case midStreamTransportFailure
    case providerError
    case malformedStream
    case structuredOutputDecodingFailed
    case other
}

struct SmokeTelemetryRecord: Codable {
    let suite: String
    let test: String
    let provider: String
    let model: String
    let durationMillis: Int
    let kind: SmokeFailureKind
    let httpStatus: Int?
    let bodyExcerpt: String?
    let assistantTextExcerpt: String?
}

struct SmokeStructuredOutputFailure: Error {
    let rawContent: String
    let underlyingDescription: String
}

struct SmokeAssertionFailure: Error, CustomStringConvertible {
    let fileID: String
    let line: UInt
    let message: String?

    var description: String {
        if let message {
            return "Smoke assertion failed at \(fileID):\(line): \(message)"
        }
        return "Smoke assertion failed at \(fileID):\(line)"
    }
}

struct SmokeTelemetryFailure: Error {
    let underlying: Error
    let telemetry: Error
}

struct SmokeFailureClassification {
    let kind: SmokeFailureKind
    let httpStatus: Int?
    let bodyExcerpt: String?
    let assistantTextExcerpt: String?
}

func smokeExpect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
) throws {
    guard try condition() else {
        throw SmokeAssertionFailure(fileID: String(describing: fileID), line: line, message: message)
    }
}

func smokeRequire<T>(
    _ value: T?,
    _ message: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw SmokeAssertionFailure(fileID: String(describing: fileID), line: line, message: message)
    }
    return value
}

func smokeFail(
    _ message: String,
    fileID: StaticString = #fileID,
    line: UInt = #line
) throws -> Never {
    throw SmokeAssertionFailure(fileID: String(describing: fileID), line: line, message: message)
}

func runSmoke<Client: LLMClient>(
    target: String,
    test testName: String = #function,
    provider: String,
    model: String,
    using client: Client,
    _ body: (Client) async throws -> Void
) async throws {
    let start = Date()
    let trimmedTestName = trimmedSmokeTestName(testName)

    do {
        try await body(client)
        printSmokeContext(
            suite: target,
            test: trimmedTestName,
            provider: provider,
            model: model,
            durationMillis: elapsedSmokeDurationMillis(since: start)
        )
    } catch {
        let durationMillis = elapsedSmokeDurationMillis(since: start)
        let classification = classifySmokeFailure(error)
        printSmokeContext(
            suite: target,
            test: trimmedTestName,
            provider: provider,
            model: model,
            durationMillis: durationMillis
        )
        printSmokeFailure(
            suite: target,
            test: trimmedTestName,
            provider: provider,
            model: model,
            classification: classification
        )
        if let path = smokeTelemetryPath() {
            do {
                try appendSmokeJSONL(
                    SmokeTelemetryRecord(
                        suite: target,
                        test: trimmedTestName,
                        provider: provider,
                        model: model,
                        durationMillis: durationMillis,
                        kind: classification.kind,
                        httpStatus: classification.httpStatus,
                        bodyExcerpt: classification.bodyExcerpt,
                        assistantTextExcerpt: classification.assistantTextExcerpt
                    ),
                    to: path
                )
            } catch let sinkError {
                throw SmokeTelemetryFailure(underlying: error, telemetry: sinkError)
            }
        }
        throw error
    }
}

func classifySmokeFailure(_ error: Error) -> SmokeFailureClassification {
    if let failure = error as? SmokeTelemetryFailure {
        var classification = classifySmokeFailure(failure.underlying)
        let telemetryExcerpt = smokeExcerpt(String(describing: failure.telemetry))
        let bodyExcerpt = if let existing = classification.bodyExcerpt {
            "\(existing) | telemetry: \(telemetryExcerpt)"
        } else {
            "telemetry: \(telemetryExcerpt)"
        }
        classification = SmokeFailureClassification(
            kind: classification.kind,
            httpStatus: classification.httpStatus,
            bodyExcerpt: bodyExcerpt,
            assistantTextExcerpt: classification.assistantTextExcerpt
        )
        return classification
    }

    if let failure = error as? SmokeStructuredOutputFailure {
        return SmokeFailureClassification(
            kind: .structuredOutputDecodingFailed,
            httpStatus: nil,
            bodyExcerpt: smokeExcerpt(failure.underlyingDescription),
            assistantTextExcerpt: smokeExcerpt(failure.rawContent)
        )
    }

    if let failure = error as? SmokeAssertionFailure {
        return SmokeFailureClassification(
            kind: .assertionFailure,
            httpStatus: nil,
            bodyExcerpt: smokeExcerpt(failure.description),
            assistantTextExcerpt: nil
        )
    }

    guard let agentError = error as? AgentError else {
        return SmokeFailureClassification(
            kind: .other,
            httpStatus: nil,
            bodyExcerpt: smokeExcerpt(String(describing: error)),
            assistantTextExcerpt: nil
        )
    }

    switch agentError {
    case let .llmError(transportError):
        return classifySmokeTransportError(transportError)
    case let .structuredOutputDecodingFailed(message):
        return SmokeFailureClassification(
            kind: .structuredOutputDecodingFailed,
            httpStatus: nil,
            bodyExcerpt: smokeExcerpt(message),
            assistantTextExcerpt: nil
        )
    default:
        return SmokeFailureClassification(
            kind: .other,
            httpStatus: nil,
            bodyExcerpt: smokeExcerpt(agentError.errorDescription ?? String(describing: agentError)),
            assistantTextExcerpt: nil
        )
    }
}

private func classifySmokeTransportError(_ transportError: TransportError) -> SmokeFailureClassification {
    switch transportError {
    case let .httpError(statusCode, body):
        smokeFailureClassification(kind: .httpError, httpStatus: statusCode, bodyExcerpt: body)
    case .rateLimited:
        smokeFailureClassification(kind: .rateLimited, httpStatus: 429)
    case let .networkError(_, description):
        smokeFailureClassification(kind: .networkError, bodyExcerpt: description)
    case .invalidResponse:
        smokeFailureClassification(kind: .invalidResponse)
    case let .encodingFailed(description):
        smokeFailureClassification(kind: .encodingFailed, bodyExcerpt: description)
    case let .decodingFailed(description):
        smokeFailureClassification(kind: .decodingFailed, bodyExcerpt: description)
    case .noChoices:
        smokeFailureClassification(kind: .noChoices)
    case let .streamFailed(failure):
        smokeFailureClassification(kind: smokeFailureKind(for: failure), bodyExcerpt: failure.description)
    case let .capabilityMismatch(model, requirement):
        smokeFailureClassification(kind: .other, bodyExcerpt: "capabilityMismatch(\(model)): \(requirement)")
    case let .featureUnsupported(provider, feature):
        smokeFailureClassification(kind: .other, bodyExcerpt: "featureUnsupported(\(provider)): \(feature)")
    case let .other(message):
        smokeFailureClassification(kind: .other, bodyExcerpt: message)
    }
}

private func smokeFailureKind(for failure: StreamFailure) -> SmokeFailureKind {
    switch failure {
    case .idleTimeout:
        .idleTimeout
    case .providerTerminationMissing:
        .providerTerminationMissing
    case .finishedDeltaMissing:
        .finishedDeltaMissing
    case .midStreamTransportFailure:
        .midStreamTransportFailure
    case .providerError:
        .providerError
    case .malformedStream:
        .malformedStream
    }
}

private func smokeFailureClassification(
    kind: SmokeFailureKind,
    httpStatus: Int? = nil,
    bodyExcerpt: String? = nil,
    assistantTextExcerpt: String? = nil
) -> SmokeFailureClassification {
    SmokeFailureClassification(
        kind: kind,
        httpStatus: httpStatus,
        bodyExcerpt: bodyExcerpt.map(smokeExcerpt),
        assistantTextExcerpt: assistantTextExcerpt.map(smokeExcerpt)
    )
}

func appendSmokeJSONL(_ record: SmokeTelemetryRecord, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(0x0A)

    if !FileManager.default.fileExists(atPath: path),
       !FileManager.default.createFile(atPath: path, contents: nil) {
        throw CocoaError(.fileWriteUnknown)
    }

    guard let handle = FileHandle(forWritingAtPath: path) else {
        throw CocoaError(.fileNoSuchFile)
    }

    defer {
        handle.closeFile()
    }

    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func printSmokeContext(
    suite: String,
    test: String,
    provider: String,
    model: String,
    durationMillis: Int
) {
    print("[smoke] suite=\(suite) test=\(test) provider=\(provider) model=\(model) duration=\(durationMillis)ms")
}

private func printSmokeFailure(
    suite: String,
    test: String,
    provider: String,
    model: String,
    classification: SmokeFailureClassification
) {
    let httpStatus = classification.httpStatus.map(String.init) ?? "-"
    let bodyExcerpt = classification.bodyExcerpt ?? "-"
    let assistantTextExcerpt = classification.assistantTextExcerpt ?? "-"
    let message =
        "[smoke-fail] suite=\(suite) test=\(test) provider=\(provider) model=\(model) " +
        "kind=\(classification.kind.rawValue) http=\(httpStatus) body=\(bodyExcerpt) raw=\(assistantTextExcerpt)"

    print(message)
}

private func trimmedSmokeTestName(_ testName: String) -> String {
    if testName.hasSuffix("()") {
        return String(testName.dropLast(2))
    }
    return testName
}

private func elapsedSmokeDurationMillis(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

private func smokeTelemetryPath() -> String? {
    let path = ProcessInfo.processInfo.environment["SMOKE_TELEMETRY_PATH"] ?? ""
    return path.isEmpty ? nil : path
}

private func smokeExcerpt(_ input: String) -> String {
    let normalized = input
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let clipped: String = if normalized.count > 500 {
        String(normalized.prefix(500)) + "..."
    } else {
        normalized
    }

    guard let regex = try? NSRegularExpression(pattern: #"Bearer\s+[^\s"']+"#, options: [.caseInsensitive]) else {
        return clipped
    }

    let range = NSRange(clipped.startIndex..., in: clipped)
    return regex.stringByReplacingMatches(in: clipped, range: range, withTemplate: "Bearer [REDACTED]")
}
