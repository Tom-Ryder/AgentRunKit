#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation

    @available(macOS 26, iOS 26, *)
    public extension Agent {
        /// Creates an agent that uses Apple's on-device foundation model with no network access.
        static func onDevice(
            tools: [any AnyTool<C>],
            context: C,
            instructions: String? = nil,
            configuration: AgentConfiguration = AgentConfiguration()
        ) -> Agent<C> {
            let client = FoundationModelsClient(tools: tools, context: context, instructions: instructions)
            return Agent(client: client, tools: tools, configuration: configuration)
        }
    }

#endif
