import Foundation

#if os(macOS)
    /// Mutable line buffer for the readability handler.
    ///
    /// `readabilityHandler` callbacks are serialized on a single dispatch
    /// source queue, so concurrent access cannot occur. The class wrapper
    /// provides reference semantics that satisfy Swift 6 `@Sendable` capture
    /// rules without introducing unnecessary synchronization overhead.
    private final class LineBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// An MCP transport that communicates over process stdin/stdout.
    ///
    /// @unchecked Sendable justification: Process and Pipe are not Sendable.
    /// Mutable state (process, stdoutHandle, stdinPipe) follows strict lifecycle:
    /// written once in connect(), read in send()/disconnect(), cleared in disconnect().
    /// stream and continuation are immutable let properties constructed in init.
    /// The owning MCPClient actor serializes all access through the MCPTransport protocol.
    public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
        private let command: String
        private let arguments: [String]
        private let environment: [String: String]?
        private let workingDirectory: URL?
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation

        private var process: Process?
        private var stdinPipe: Pipe?
        private var stdoutHandle: FileHandle?

        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: URL? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            self.stream = stream
            self.continuation = continuation
        }

        public func connect() async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.finish()
                throw MCPError.connectionFailed("Failed to start process '\(command)': \(error)")
            }

            self.process = process
            self.stdinPipe = stdinPipe

            // Use readabilityHandler for non-blocking reads instead of
            // FileHandle.bytes, which blocks a cooperative thread pool thread
            // per connection and causes thread starvation when multiple MCP
            // servers are active concurrently. The handler is invoked on a
            // background dispatch source thread whenever data is available.
            let handle = stdoutPipe.fileHandleForReading
            stdoutHandle = handle
            let cont = continuation
            let newline = UInt8(ascii: "\n")
            let buffer = LineBuffer()

            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    // EOF — process closed stdout
                    fileHandle.readabilityHandler = nil
                    cont.finish()
                    return
                }

                buffer.data.append(chunk)

                // Extract complete newline-delimited JSON-RPC messages
                while let newlineIndex = buffer.data.firstIndex(of: newline) {
                    let messageEnd = buffer.data.index(after: newlineIndex)
                    let message = buffer.data[buffer.data.startIndex ..< messageEnd]
                    buffer.data = Data(buffer.data[messageEnd...])
                    if !message.isEmpty {
                        cont.yield(Data(message))
                    }
                }
            }
        }

        public func disconnect() async {
            continuation.finish()
            stdoutHandle?.readabilityHandler = nil
            stdoutHandle = nil

            guard let process, process.isRunning else {
                process = nil
                stdinPipe = nil
                return
            }

            stdinPipe?.fileHandleForWriting.closeFile()
            stdinPipe = nil

            try? await Task.sleep(for: .seconds(2))
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .seconds(3))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            self.process = nil
        }

        public func send(_ data: Data) async throws {
            guard let stdinPipe else { throw MCPError.transportClosed }
            var framed = data
            framed.append(UInt8(ascii: "\n"))
            let handle = stdinPipe.fileHandleForWriting
            do {
                try handle.write(contentsOf: framed)
            } catch {
                throw MCPError.connectionFailed("Write failed: \(error)")
            }
        }

        public nonisolated func messages() -> AsyncThrowingStream<Data, Error> {
            stream
        }
    }
#endif
