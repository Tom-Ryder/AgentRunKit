func resolvedToolTimeout<C: ToolContext>(
    for tool: any AnyTool<C>,
    default fallback: Duration
) -> Duration {
    tool.toolTimeout ?? fallback
}
