import Foundation

struct Workspace {
    let root: URL
    let maxReadBytes: Int

    init(root: URL, maxReadBytes: Int = 200_000) throws {
        precondition(maxReadBytes >= 1, "maxReadBytes must be at least 1")
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolvedRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AgentCodeError.invalidWorkspace(root.path)
        }
        self.root = resolvedRoot
        self.maxReadBytes = maxReadBytes
    }

    func relativePath(for url: URL) throws -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(resolved) else {
            throw AgentCodeError.pathEscapesWorkspace(url.path)
        }
        let rootPath = normalizedRootPath
        if resolved.path == rootPath { return "." }
        return String(resolved.path.dropFirst(rootPath.count + 1))
    }

    func resolve(_ path: String) throws -> URL {
        guard !path.contains("\0") else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        let candidate = path.isEmpty || path == "."
            ? root
            : root.appendingPathComponent(path)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(resolved) else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        try validateAllowed(relativePath: relativePath(for: resolved))
        return resolved
    }

    func listFiles(limit: Int) throws -> [String] {
        guard limit >= 1 else {
            throw AgentCodeError.invalidToolLimit(parameter: "limit", value: limit, allowed: "1...")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let relative = try relativePath(for: url)
            if shouldSkip(relativePath: relative) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                paths.append(relative)
                if paths.count >= limit { break }
            }
        }
        return paths.sorted()
    }

    func readFile(_ path: String) throws -> String {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AgentCodeError.unreadableText(path)
        }
        let size = values.fileSize ?? 0
        guard size <= maxReadBytes else {
            throw AgentCodeError.fileTooLarge(path: path, bytes: size)
        }
        let data = try Data(contentsOf: url)
        guard !looksBinary(data) else {
            throw AgentCodeError.binaryFile(path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentCodeError.unreadableText(path)
        }
        return text
    }

    func writeFile(_ path: String, content: String) throws -> Int {
        let url = try resolveForWrite(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    func editFile(_ path: String, oldString: String, newString: String, replaceAll: Bool) throws -> Int {
        try applyEdits(path, edits: [TextEdit(oldString: oldString, newString: newString, replaceAll: replaceAll)])
    }

    func applyEdits(_ path: String, edits: [TextEdit]) throws -> Int {
        let url = try resolve(path)
        var content = try readFile(path)
        var replacements = 0
        for edit in edits {
            let replaceAll = edit.replaceAll ?? false
            let editCount = try replacementCount(
                in: content,
                oldString: edit.oldString,
                path: path,
                requireUnique: !replaceAll
            )
            content = replaceAll
                ? content.replacingOccurrences(of: edit.oldString, with: edit.newString)
                : content.replacingFirstOccurrence(of: edit.oldString, with: edit.newString)
            replacements += editCount
        }
        try Data(content.utf8).write(to: url, options: .atomic)
        return replacements
    }

    func currentDiff() async throws -> String {
        do {
            let result = try await CommandRunner(allowedCommands: [.gitDiff]).run(
                CommandInvocation(command: "git", arguments: ["diff", "--"], timeoutSeconds: 10),
                in: self
            )
            return result.combinedOutput
        } catch let AgentCodeError.processFailed(_, _, output) {
            return "git diff unavailable:\n\(output)"
        }
    }

    func glob(_ pattern: String, limit: Int) throws -> [String] {
        guard limit >= 1 else {
            throw AgentCodeError.invalidToolLimit(parameter: "limit", value: limit, allowed: "1...")
        }
        let expression = try NSRegularExpression(pattern: globPatternToRegex(pattern))
        let scanLimit = limit > Int.max / 4 ? Int.max : limit * 4
        let matches = try listFiles(limit: max(scanLimit, limit)).filter { path in
            let range = NSRange(path.startIndex ..< path.endIndex, in: path)
            return expression.firstMatch(in: path, range: range) != nil
        }
        return Array(matches.prefix(limit))
    }

    private var normalizedRootPath: String {
        root.path
    }

    private func resolveForWrite(_ path: String) throws -> URL {
        guard !path.contains("\0") else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        let candidate = root.appendingPathComponent(path)
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideWorkspace(parent) else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        let fileManager = FileManager.default
        let resolved = fileManager.fileExists(atPath: candidate.path)
            ? candidate.standardizedFileURL.resolvingSymlinksInPath()
            : candidate.standardizedFileURL
        guard isInsideWorkspace(resolved) else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        try validateAllowed(relativePath: relativePathForCandidate(resolved))
        return resolved
    }

    private func relativePathForCandidate(_ url: URL) throws -> String {
        let rootPath = normalizedRootPath
        let path = url.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw AgentCodeError.pathEscapesWorkspace(path)
        }
        return path == rootPath ? "." : String(path.dropFirst(rootPath.count + 1))
    }

    private func replacementCount(
        in content: String,
        oldString: String,
        path: String,
        requireUnique: Bool
    ) throws -> Int {
        guard !oldString.isEmpty else {
            throw AgentCodeError.emptyEditTarget(path)
        }
        let count = content.nonOverlappingOccurrenceCount(of: oldString)
        guard count > 0 else {
            throw AgentCodeError.editTargetNotFound(path: path, target: oldString)
        }
        if requireUnique, count != 1 {
            throw AgentCodeError.ambiguousEditTarget(path: path, target: oldString, matches: count)
        }
        return count
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let rootPath = normalizedRootPath
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func validateAllowed(relativePath: String) throws {
        guard !DeniedPathPolicy.isDenied(relativePath) else {
            throw AgentCodeError.deniedPath(relativePath)
        }
    }

    private func shouldSkip(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        return components.contains { DeniedPathPolicy.isIgnoredDirectory($0) }
            || DeniedPathPolicy.isDenied(relativePath)
    }

    private func looksBinary(_ data: Data) -> Bool {
        data.prefix(4096).contains(0)
    }

    private func globPatternToRegex(_ pattern: String) -> String {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterGlobstar = pattern.index(after: next)
                    if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
                        regex += "(?:.*/)?"
                        index = pattern.index(after: afterGlobstar)
                    } else {
                        regex += ".*"
                        index = afterGlobstar
                    }
                } else {
                    regex += "[^/]*"
                    index = next
                }
                continue
            }
            if character == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        return regex + "$"
    }
}

private extension String {
    func nonOverlappingOccurrenceCount(of target: String) -> Int {
        guard !target.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while let range = range(of: target, range: searchStart ..< endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    func replacingFirstOccurrence(of oldString: String, with newString: String) -> String {
        guard let range = range(of: oldString) else { return self }
        var copy = self
        copy.replaceSubrange(range, with: newString)
        return copy
    }
}

enum DeniedPathPolicy {
    static func isIgnoredDirectory(_ name: String) -> Bool {
        [
            ".git",
            ".build",
            "DerivedData",
            "node_modules",
            ".swiftpm",
            ".cache",
            "dist",
            "build"
        ].contains(name)
    }

    static func isDenied(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        if name == ".env" || name.hasSuffix(".pem") || name.hasSuffix(".p12") || name.hasSuffix(".key") {
            return true
        }
        return relativePath.split(separator: "/").contains { component in
            component == ".ssh" || component == "Secrets" || component == "secrets"
        }
    }
}
