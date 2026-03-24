#if canImport(FoundationModels)

    import AgentRunKit
    import Foundation

    @available(macOS 26, iOS 26, *)
    public extension Agent {
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
