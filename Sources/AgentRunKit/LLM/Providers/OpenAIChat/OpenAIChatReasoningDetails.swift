import Foundation

enum OpenAIChatReasoningDetails {
    static func decode(from data: Data) throws -> [JSONValue]? {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }
        let message = first["message"] as? [String: Any] ?? first["delta"] as? [String: Any]
        guard let details = message?["reasoning_details"] as? [Any] else { return nil }
        let result = try details.map { try JSONValue.fromJSONObject($0) }
        return result.isEmpty ? nil : result
    }
}
