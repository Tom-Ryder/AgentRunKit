import Foundation

#if os(macOS)
    /// An MCP transport that communicates over process stdin/stdout.
    ///
    /// @unchecked Sendable justification: Process and Pipe are not Sendable.
    /// Mutable state (process, stdinPipe, stdoutHandle, stdoutChunkContinuation,
    /// stdoutReaderTask) follows strict lifecycle: written once in connect(),
    /// read in send()/disconnect(), cleared in disconnect().
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
        private var stdoutChunkContinuation: AsyncStream<Data>.Continuation?
        private var stdoutReaderTask: Task<Void, Never>?

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

            let handle = stdoutPipe.fileHandleForReading
            stdoutHandle = handle
            let (chunks, chunkContinuation) = AsyncStream<Data>.makeStream()
            stdoutChunkContinuation = chunkContinuation
            stdoutReaderTask = makeStdoutReaderTask(chunks: chunks)

            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    fileHandle.readabilityHandler = nil
                    chunkContinuation.finish()
                    return
                }
                chunkContinuation.yield(chunk)
            }
        }

        public func disconnect() async {
            stdoutHandle?.readabilityHandler = nil
            stdoutHandle = nil
            stdoutChunkContinuation?.finish()
            stdoutChunkContinuation = nil
            stdoutReaderTask?.cancel()
            stdoutReaderTask = nil
            continuation.finish()

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

        private func makeStdoutReaderTask(chunks: AsyncStream<Data>) -> Task<Void, Never> {
            let continuation = continuation
            return Task {
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                for await chunk in chunks {
                    buffer.append(chunk)

                    while let newlineIndex = buffer.firstIndex(of: newline) {
                        let messageEnd = buffer.index(after: newlineIndex)
                        let message = buffer[buffer.startIndex ..< messageEnd]
                        buffer = Data(buffer[messageEnd...])
                        if !message.isEmpty {
                            continuation.yield(Data(message))
                        }
                    }
                }

                continuation.finish()
            }
        }
    }
#endif
