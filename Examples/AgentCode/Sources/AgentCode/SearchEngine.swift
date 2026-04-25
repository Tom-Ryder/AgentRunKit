import Foundation

struct SearchEngine {
    let outputLimiter: OutputLimiter

    init(outputLimiter: OutputLimiter = OutputLimiter(maxCharacters: 500)) {
        self.outputLimiter = outputLimiter
    }

    func search(
        query: String,
        regex: Bool,
        limit: Int,
        workspace: Workspace
    ) throws -> SearchResults {
        guard limit >= 1 else {
            throw AgentCodeError.invalidToolLimit(parameter: "limit", value: limit, allowed: "1...")
        }
        let files = try workspace.listFiles(limit: 10000)
        let expression = regex ? try NSRegularExpression(pattern: query) : nil
        var matches: [SearchResult] = []

        for file in files {
            let content: String
            do {
                content = try workspace.readFile(file)
            } catch AgentCodeError.binaryFile, AgentCodeError.fileTooLarge, AgentCodeError.unreadableText {
                continue
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where lineMatches(line, query: query, expression: expression) {
                matches.append(SearchResult(path: file, line: index + 1, text: outputLimiter.truncate(line)))
                if matches.count >= limit {
                    return SearchResults(matches: matches, truncated: true)
                }
            }
        }

        return SearchResults(matches: matches, truncated: false)
    }

    private func lineMatches(_ line: String, query: String, expression: NSRegularExpression?) -> Bool {
        if let expression {
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            return expression.firstMatch(in: line, range: range) != nil
        }
        return line.localizedCaseInsensitiveContains(query)
    }
}
