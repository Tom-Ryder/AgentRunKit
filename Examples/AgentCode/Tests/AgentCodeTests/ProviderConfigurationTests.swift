@testable import AgentCode
import Foundation
import Testing

struct ProviderConfigurationTests {
    @Test
    func missingAPIKeyUsesOfflineClient() throws {
        let config = try ProviderConfiguration.load(environment: [:], forceOffline: false)

        #expect(config.offline)
        #expect(config.description == "offline demo client")
    }

    @Test
    func compatibleProfileRequiresValidBaseURL() throws {
        #expect(throws: AgentCodeError.invalidBaseURL("not a url")) {
            _ = try ProviderConfiguration.load(
                environment: [
                    "OPENAI_API_KEY": "token",
                    "OPENAI_PROFILE": "compatible",
                    "OPENAI_BASE_URL": "not a url"
                ],
                forceOffline: false
            )
        }
    }
}
