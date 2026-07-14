#if canImport(FoundationModels)

    import AgentRunKit

    func isUnsupportedFoundationModelsMappingError(_ error: any Error) -> Bool {
        guard case let AgentError.llmError(inner) = error,
              case let .featureUnsupported(provider, feature) = inner
        else { return false }
        return provider == ProviderIdentifier.foundationModels.description
            && feature == "single-turn text-only message mapping"
    }

    actor ParamsRecorder<P: Sendable> {
        private(set) var received: [P] = []

        func record(_ value: P) {
            received.append(value)
        }
    }

#endif
