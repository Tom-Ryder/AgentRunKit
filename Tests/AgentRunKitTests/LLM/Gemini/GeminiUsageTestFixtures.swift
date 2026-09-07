@testable import AgentRunKit

enum GeminiUsageTestFixtures {
    static let toolUseMetadata = #"{"promptTokenCount":33,"toolUsePromptTokenCount":39,"#
        + #""candidatesTokenCount":106,"thoughtsTokenCount":106,"totalTokenCount":284}"#

    static let measurements: [(metadata: String?, expected: TokenUsage?)] = [
        (nil, nil), ("null", nil), ("{}", TokenUsage(cacheRead: 0)),
        (#"{"promptTokenCount":null,"candidatesTokenCount":null,"thoughtsTokenCount":null,"#
            + #""cachedContentTokenCount":null}"#, TokenUsage(cacheRead: 0)),
        (#"{"promptTokenCount":1124,"totalTokenCount":1171,"thoughtsTokenCount":47}"#,
         TokenUsage(input: 1124, reasoning: 47, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":0}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":null}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 0)),
        (#"{"promptTokenCount":100,"candidatesTokenCount":20,"cachedContentTokenCount":80}"#,
         TokenUsage(input: 100, output: 20, cacheRead: 80)),
        (#"{"promptTokenCount":100,"cachedContentTokenCount":101}"#, nil),
        (toolUseMetadata, TokenUsage(input: 72, output: 106, reasoning: 106, cacheRead: 0)),
        (#"{"promptTokenCount":33,"toolUsePromptTokenCount":39,"cachedContentTokenCount":33}"#,
         TokenUsage(input: 72, cacheRead: 33)),
        (#"{"promptTokenCount":33,"toolUsePromptTokenCount":0}"#, TokenUsage(input: 33, cacheRead: 0)),
        (#"{"promptTokenCount":33,"toolUsePromptTokenCount":null}"#, TokenUsage(input: 33, cacheRead: 0)),
        (#"{"toolUsePromptTokenCount":39}"#, TokenUsage(input: 39, cacheRead: 0)),
        (#"{"promptTokenCount":33,"toolUsePromptTokenCount":39,"cachedContentTokenCount":40}"#, nil),
        (#"{"promptTokenCount":9223372036854775807,"toolUsePromptTokenCount":1}"#, nil),
        (#"{"promptTokenCount":9223372036854775768,"toolUsePromptTokenCount":39}"#,
         TokenUsage(input: .max, cacheRead: 0))
    ]

    static let scalarKeys = [
        "promptTokenCount", "toolUsePromptTokenCount", "candidatesTokenCount", "thoughtsTokenCount",
        "cachedContentTokenCount"
    ]

    static let malformedScalars = ["-1", #""1""#, "true", "1.5", "9223372036854775808"]
}
