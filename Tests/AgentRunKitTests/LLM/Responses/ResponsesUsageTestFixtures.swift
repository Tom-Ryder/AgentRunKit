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
