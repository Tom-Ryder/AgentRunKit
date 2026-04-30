import Foundation

func buildJSONPostRequest(
    url: URL,
    body: some Encodable,
    headers: [String: String]
) throws -> URLRequest {
    try buildJSONPostRequest(url: url, body: body, headers: Array(headers))
}

func buildJSONPostRequest(
    url: URL,
    body: some Encodable,
    headers: [(String, String)]
) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (field, value) in headers {
        request.setValue(value, forHTTPHeaderField: field)
    }
    do {
        request.httpBody = try JSONEncoder().encode(body)
    } catch {
        throw AgentError.llmError(.encodingFailed(error))
    }
    return request
}
