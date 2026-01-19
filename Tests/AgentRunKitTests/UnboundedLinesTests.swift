import Foundation
import Testing

@testable import AgentRunKit

struct MockByteSequence: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: [UInt8]
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }
}

@Suite
struct UnboundedLinesTests {
    @Test
    func lfLineEndings() async throws {
        let input = "line1\nline2\nline3\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines == ["line1", "line2", "line3"])
    }

    @Test
    func crlfLineEndings() async throws {
        let input = "line1\r\nline2\r\nline3\r\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines == ["line1", "line2", "line3"])
    }

    @Test
    func mixedLineEndings() async throws {
        let input = "line1\nline2\r\nline3\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines == ["line1", "line2", "line3"])
    }

    @Test
    func emptyLines() async throws {
        let input = "line1\n\nline3\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines == ["line1", "", "line3"])
    }

    @Test
    func noTrailingNewline() async throws {
        let input = "line1\nline2"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines == ["line1", "line2"])
    }

    @Test
    func emptyInput() async throws {
        let source = MockByteSequence(bytes: [])
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines.isEmpty)
    }

    @Test
    func invalidUtf8Throws() async throws {
        let invalidBytes: [UInt8] = [0x48, 0x69, 0xFF, 0xFE, 0x0A]
        let source = MockByteSequence(bytes: invalidBytes)
        do {
            for try await _ in UnboundedLines(source: source) {}
            Issue.record("Expected error for invalid UTF-8")
        } catch let error as AgentError {
            guard case let .llmError(transport) = error,
                  case let .decodingFailed(desc) = transport
            else {
                Issue.record("Expected decodingFailed error")
                return
            }
            #expect(desc.contains("UTF-8"))
        }
    }

    @Test
    func largeLine30KB() async throws {
        let largeContent = String(repeating: "x", count: 30000)
        let input = "\(largeContent)\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines.count == 1)
        #expect(lines[0].count == 30000)
    }

    @Test
    func multipleVeryLargeLines() async throws {
        let largeContent1 = String(repeating: "a", count: 50000)
        let largeContent2 = String(repeating: "b", count: 50000)
        let input = "\(largeContent1)\n\(largeContent2)\n"
        let source = MockByteSequence(bytes: Array(input.utf8))
        var lines: [String] = []
        for try await line in UnboundedLines(source: source) {
            lines.append(line)
        }
        #expect(lines.count == 2)
        #expect(lines[0].count == 50000)
        #expect(lines[0].allSatisfy { $0 == "a" })
        #expect(lines[1].count == 50000)
        #expect(lines[1].allSatisfy { $0 == "b" })
    }
}
