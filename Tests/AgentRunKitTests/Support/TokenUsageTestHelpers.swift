import AgentRunKit

func makeTokenUsageTotals(_ usages: TokenUsage?...) -> TokenUsageTotals {
    var totals = TokenUsageTotals()
    for usage in usages {
        totals.record(usage)
    }
    return totals
}
