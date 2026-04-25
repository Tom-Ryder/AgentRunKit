#if os(macOS)
    @testable import AgentRunKit
    import Foundation
    import Testing

    struct StdioMCPTransportTests {
        @Test
        func concurrentServersInitializeWithoutCooperativePoolStarvation() async throws {
            let serverCount = min(16, max(8, ProcessInfo.processInfo.processorCount + 2))
            let script = """
            while IFS= read -r line; do
              case "$line" in
                *\\"method\\":\\"initialize\\"*)
                  printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}'
                  ;;
                *tools*list*)
                  printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
                  ;;
              esac
            done
            """
            let configurations = (0 ..< serverCount).map { index in
                MCPServerConfiguration(
                    name: "server-\(index)",
                    command: "/bin/sh",
                    arguments: ["-c", script],
                    initializationTimeout: .seconds(10),
                    toolCallTimeout: .seconds(2)
                )
            }
            let session = MCPSession(configurations: configurations)

            try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
                #expect(tools.isEmpty)
            }
        }
    }
#endif
