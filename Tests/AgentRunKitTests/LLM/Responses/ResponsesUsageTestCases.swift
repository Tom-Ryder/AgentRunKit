import AgentRunKit

let responsesCacheUsageCases: [(details: String, expected: TokenUsage)] = [
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

let responsesMalformedUsageCases: [(usage: String, key: String)] = [
    (#"{"output_tokens":5}"#, "input_tokens"),
    (#"{"input_tokens":10}"#, "output_tokens"),
    (#"{"input_tokens":-1,"output_tokens":5}"#, "input_tokens"),
    (#"{"input_tokens":10,"output_tokens":-1}"#, "output_tokens"),
    (#"{"input_tokens":10,"output_tokens":null}"#, "output_tokens"),
    (#"{"input_tokens":10,"output_tokens":9223372036854775808}"#, "output_tokens"),
    (#"{"input_tokens":10,"output_tokens":1.5}"#, "output_tokens"),
    (#"{"input_tokens":10,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":-1}}"#,
     "reasoning_tokens"),
    (#"{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cached_tokens":-1}}"#, "cached_tokens"),
    (#"{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cache_write_tokens":"2"}}"#,
     "cache_write_tokens"),
    (#"{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cache_write_tokens":-1}}"#,
     "cache_write_tokens"),
    (#"{"input_tokens":10,"output_tokens":5,"input_tokens_details":false}"#, "input_tokens_details")
]
