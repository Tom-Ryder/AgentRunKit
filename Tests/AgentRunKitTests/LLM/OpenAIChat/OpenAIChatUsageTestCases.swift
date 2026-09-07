import AgentRunKit

let openAIChatCacheUsageCases: [(details: String, expected: TokenUsage)] = [
    (#"{"cached_tokens":80,"cache_write_tokens":70}"#,
     TokenUsage(input: 100, output: 30, reasoning: 20, cacheRead: 80, cacheWrite: 70)),
    (#"{"cached_tokens":0,"cache_write_tokens":0}"#,
     TokenUsage(input: 100, output: 30, reasoning: 20, cacheRead: 0, cacheWrite: 0)),
    (#"{"cached_tokens":80}"#, TokenUsage(input: 100, output: 30, reasoning: 20, cacheRead: 80)),
    (#"{"cache_write_tokens":70}"#, TokenUsage(input: 100, output: 30, reasoning: 20, cacheWrite: 70)),
    (#"{"cached_tokens":null,"cache_write_tokens":null}"#, TokenUsage(input: 100, output: 30, reasoning: 20)),
    ("{}", TokenUsage(input: 100, output: 30, reasoning: 20)),
    ("null", TokenUsage(input: 100, output: 30, reasoning: 20))
]
