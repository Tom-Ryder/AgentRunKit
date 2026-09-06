@testable import AgentRunKit
import Foundation
import Testing

@Suite(.tags(.wireFormat))
struct JSONRequestBuilderTests {
    private struct Body: Encodable {
        let schema: JSONSchema
        let payload: JSONValue
    }

    private enum EncodingFailure: Error {
        case refused
    }

    private struct ThrowingBody: Encodable {
        func encode(to _: any Encoder) throws {
            throw EncodingFailure.refused
        }
    }

    @Test(arguments: [["zeta", "alpha"], ["alpha", "zeta"]])
    func ordersNestedObjectsWithoutChangingArraysOrStrings(keys: [String]) throws {
        let nestedProperties = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, JSONSchema.string(enumValues: ["z", "a"]))
        })
        let properties = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, JSONSchema.array(items: .object(properties: nestedProperties, required: ["zeta", "alpha"])))
        })
        let body = Body(
            schema: .object(properties: properties, required: ["zeta", "alpha"]),
            payload: .array([
                .object(["zeta": .string(#"{ "z": 1, "a": 2 }"#), "alpha": .object([:])]),
                .string("雪\n\"\\")
            ])
        )
        let request = try buildJSONPostRequest(
            url: #require(URL(string: "https://json-request.test/nested")),
            body: body,
            headers: [:]
        )
        let item = #"{"additionalProperties":false,"properties":{"alpha":{"enum":["z","a"],"type":"string"},"#
            + #""zeta":{"enum":["z","a"],"type":"string"}},"required":["zeta","alpha"],"type":"object"}"#
        let expected = #"{"payload":[{"alpha":{},"zeta":"{ \"z\": 1, \"a\": 2 }"},"雪\n\"\\"],"#
            + #""schema":{"additionalProperties":false,"properties":{"alpha":{"items":"#
            + item + #","type":"array"},"zeta":{"items":"#
            + item + #","type":"array"}},"required":["zeta","alpha"],"type":"object"}}"#

        #expect(request.httpBody == Data(expected.utf8))
    }

    @Test
    func emptySchemaPreservesItsEmptyPropertiesObject() throws {
        let request = try buildJSONPostRequest(
            url: #require(URL(string: "https://json-request.test/empty-schema")),
            body: JSONSchema.object(properties: [:], required: []),
            headers: [:]
        )

        #expect(request.httpBody == Data(#"{"additionalProperties":false,"properties":{},"type":"object"}"#.utf8))
    }

    @Test
    func dictionaryHeadersPreserveRequestPropertiesAndOverrideContentType() throws {
        let url = try #require(URL(string: "https://json-request.test/headers?mode=test"))
        let request = try buildJSONPostRequest(
            url: url,
            body: JSONValue.object([:]),
            headers: ["content-type": "application/custom+json", "Authorization": "Bearer test"]
        )

        #expect(request.url == url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/custom+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test
    func orderedHeadersUseTheLastCaseInsensitiveValue() throws {
        let request = try buildJSONPostRequest(
            url: #require(URL(string: "https://json-request.test/ordered-headers")),
            body: JSONValue.object([:]),
            headers: [("Authorization", "Bearer first"), ("authorization", "Bearer last")]
        )

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer last")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test
    func customEncodingFailureRetainsTransportWrapping() throws {
        let url = try #require(URL(string: "https://json-request.test/throwing"))

        #expect(throws: AgentError.llmError(.encodingFailed(EncodingFailure.refused))) {
            _ = try buildJSONPostRequest(url: url, body: ThrowingBody(), headers: [:])
        }
    }

    @Test(arguments: [Double.infinity, -.infinity, .nan])
    func nonfiniteNumbersProduceEncodingFailures(value: Double) throws {
        let url = try #require(URL(string: "https://json-request.test/nonfinite"))

        #expect {
            _ = try buildJSONPostRequest(url: url, body: ["value": value], headers: [:])
        } throws: { error in
            guard case AgentError.llmError(.encodingFailed) = error else { return false }
            return true
        }
    }

    @Test
    func concurrentBuildsKeepTheirOwnBodies() async throws {
        let url = try #require(URL(string: "https://json-request.test/concurrent"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0 ..< 8 {
                group.addTask {
                    let request = try buildJSONPostRequest(
                        url: url,
                        body: ["zeta": value, "alpha": -value],
                        headers: [:]
                    )
                    #expect(request.httpBody == Data("{\"alpha\":\(-value),\"zeta\":\(value)}".utf8))
                }
            }
            try await group.waitForAll()
        }
    }
}
