# Token Accounting

Preserve measurement gaps when accumulating token usage.

## Overview

``TokenUsage`` describes the measurements attached to one model response. ``TokenUsageTotals`` records those responses and tracks whether their measurements cover the entire accumulation. Pass each response's optional usage to ``TokenUsageTotals/record(_:)``, including `nil` when the response has no usable measurement.

```swift
var totals = TokenUsageTotals()
totals.record(TokenUsage(input: 100, output: 20, cacheRead: 0))
totals.record(nil)
```

These totals report 100 input tokens, 20 output tokens, and partial overall coverage. The cache-read subtotal is a measured zero with partial coverage. Cache-write measurements are unavailable, so `cacheWrite` is `nil`.

## Coverage

``TokenUsageCoverage`` describes availability independently for overall usage, cache reads, and cache writes:

| Coverage | Meaning |
|---|---|
| `complete` | Every recorded response supplied the measurement. |
| `partial` | Measurements have gaps, or their completeness is unknown. |
| `unavailable` | No measurement is represented for this dimension. |

Empty totals have complete coverage and five exact zero counts because no responses have been recorded. Recording `nil` changes that state to unavailable usage with zero reported scalar counts and `nil` cache counts. Recording a measured zero instead preserves its availability. Those states remain distinct after encoding and decoding.

Once measurements have gaps, later responses cannot restore complete coverage. Cache dimensions are independent: a response can report complete input and output measurements while leaving one or both cache breakdowns unavailable. A cache subtotal is `nil` exactly when its coverage is unavailable; partial and complete cache subtotals always have a numeric value, including zero.

Provider adapters resolve wire defaults before constructing ``TokenUsage``. For example, Gemini and Vertex Google treat omitted or null counters inside a present usage metadata object as zero, allowing complete cache-read coverage. An absent or null metadata object contributes `nil` usage instead. Foundation Models does not report token usage, so recording its responses produces unavailable totals. See <doc:LLMProviders> for provider mappings.

## Interpreting Counts

Input includes reported cache reads and cache writes. Cache counters describe portions of input, so ``TokenUsageTotals/total`` adds only input, output, and reasoning. Output excludes reasoning when a provider supplies a separate breakdown; undifferentiated output remains output. A reasoning count of zero can mean that no separate breakdown was reported. Complete overall coverage describes usage availability and does not establish that a provider identified every reasoning token separately.

Gemini and Vertex Google input includes both `promptTokenCount` and `toolUsePromptTokenCount`. Cached content is already included in `promptTokenCount`, so its count is not added again. Tool-use input therefore contributes to usage totals, context utilization, token ceilings, and compaction thresholds.

All sums saturate at `Int.max`. Coverage still describes measurement availability when a sum saturates; it does not certify arithmetic precision or the accuracy of provider estimates.

Interpreting `cacheRead / input` as a token share requires compatible measurements, complete overall and cache-read coverage, a positive input count, and unsaturated sums. With partial coverage, the numerator and denominator may describe different sets of responses. Even a complete token share is not a request cache-hit rate: a response may reuse only part of its input.

The aggregate represents recorded responses. It does not estimate failed HTTP attempts, failed or cancelled streams, hidden provider work, or monetary cost. Child-agent consumption is separate from its parent's budget. These totals are useful for reported usage and budgeting, but they are not a billing ledger.

## Runtime Accounting

``AgentResult/totalTokenUsage``, the `tokenUsage` payload of ``StreamEvent/Kind/finished(tokenUsage:content:reason:history:)``, and ``AgentCheckpoint/tokenUsage`` carry ``TokenUsageTotals``. ``AgentStream/tokenUsage`` is optional until a finish event or checkpoint preload supplies totals. ``Agent`` and streaming ``Chat`` populate these values automatically.

A blocking response contributes once when it returns. A streamed response contributes once after the stream drains and passes validation. A finished delta followed by a stream error, cancellation, or invalid completion contributes no returned response. A summarization response contributes as soon as it returns, even when its content is rejected and compaction falls back. Local pruning, truncation, and failed requests that return no response contribute nothing.

For custom ``LLMClient`` implementations, each ``StreamDelta/finished(usage:)`` replaces the previous usage snapshot for that response. If a stream sends multiple finished deltas, the last value wins, including `nil`; those snapshots are not added together. This response-level rule is separate from provider wire updates, which each adapter normalizes before emitting deltas.

Completed Agent iterations carry optional single-response ``TokenUsage``. Their sample array cannot reconstruct aggregate totals: summary responses are included in totals but have no iteration sample. Missing samples remain `nil`, including on Foundation Models. Resume restores aggregate values and coverage directly; replaying saved or buffered events does not record responses again. Nested child events do not change parent totals.

Use coverage when presenting a total:

```swift
switch result.totalTokenUsage.coverage {
case .complete:
    print("\(result.totalTokenUsage.total) tokens")
case .partial:
    print("\(result.totalTokenUsage.total) reported tokens (partial)")
case .unavailable:
    print("Usage unavailable")
}
```

## Persistence

The aggregate encodes `input`, `output`, `reasoning`, `cacheRead`, and `cacheWrite` as top-level keys. An `accounting` object preserves whether the aggregate is empty or observed and records coverage for observed totals. Unavailable cache values are omitted:

```json
{
  "input": 100,
  "output": 20,
  "reasoning": 0,
  "cacheRead": 0,
  "accounting": {
    "type": "observed",
    "usage": "partial",
    "cacheRead": "partial",
    "cacheWrite": "unavailable"
  }
}
```

When decoding an aggregate without `accounting`, counts retain their encoded values with partial overall coverage. Present cache counts have partial coverage; absent cache counts are unavailable. This applies even when every count is zero.

Decoding rejects malformed `accounting` metadata, negative counts, and contradictions between counts and coverage.

## See Also

- ``TokenUsage``
- ``TokenUsageTotals``
- ``TokenUsageCoverage``
- <doc:LLMProviders>
- <doc:ContextManagement>
