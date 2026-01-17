import Foundation
import Testing

@testable import AgentRunKit

private let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]

private struct TestWorkout: Codable, SchemaProviding {
    let exercises: [TestExercise]

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "exercises": .array(items: TestExercise.jsonSchema)
            ],
            required: ["exercises"]
        )
    }
}

private struct TestExercise: Codable, SchemaProviding {
    let name: String
    let sets: Int

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "name": .string(description: "Exercise name"),
                "sets": .integer(description: "Number of sets")
            ],
            required: ["name", "sets"]
        )
    }
}

@Suite(.disabled(if: apiKey == nil, "Requires OPENROUTER_API_KEY environment variable"))
struct StructuredOutputIntegrationTests {
    let client: OpenAIClient

    init() {
        client = OpenAIClient(
            apiKey: apiKey ?? "",
            model: "openai/gpt-4o-mini",
            maxTokens: 1024,
            baseURL: OpenAIClient.openRouterBaseURL
        )
    }

    @Test
    func structuredOutputReturnsTypedResponse() async throws {
        let chat = Chat<EmptyContext>(client: client)

        let (workout, history) = try await chat.send(
            "Give me a few exercises for upper body",
            returning: TestWorkout.self
        )

        #expect(!workout.exercises.isEmpty)
        for exercise in workout.exercises {
            #expect(!exercise.name.isEmpty)
            #expect(exercise.sets > 0)
        }
        #expect(history.count >= 2)
    }
}
