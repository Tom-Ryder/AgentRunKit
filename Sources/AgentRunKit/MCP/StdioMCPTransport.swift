import Foundation

#if os(macOS)
    /// An MCP transport that communicates over process stdin/stdout.
    ///
    /// @unchecked Sendable justification: Process and Pipe are not Sendable.
    /// Mutable state (process, stdinPipe) follows strict lifecycle: written once
    /// in connect(), read in send()/disconnect(), cleared in disconnect().
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

            let cont = continuation
            Task {
                let handle = stdoutPipe.fileHandleForReading
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                do {
                    for try await byte in handle.bytes {
                        buffer.append(byte)
                        if byte == newline {
                            let message = buffer
                            buffer = Data()
                            if !message.isEmpty {
                                cont.yield(message)
                            }
                        }
                    }
                } catch {
                    cont.finish(throwing: error)
                    return
                }
                cont.finish()
            }
        }

        public func disconnect() async {
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
    }
#endif
