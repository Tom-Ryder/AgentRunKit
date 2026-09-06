/// Describes whether reported token counts cover every recorded response.
public enum TokenUsageCoverage: String, Sendable, Codable {
    case complete
    case partial
    case unavailable
}
