@testable import AgentCode
import Foundation
import Testing

struct WorkspaceTests {
    @Test
    func readFileRejectsParentEscape() throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)

        #expect(throws: AgentCodeError.pathEscapesWorkspace("../outside.txt")) {
            _ = try workspace.readFile("../outside.txt")
        }
    }

    @Test
    func readFileRejectsDeniedSecretPath() throws {
        let directory = try TemporaryDirectory()
        try directory.write("token", to: ".env")
        let workspace = try Workspace(root: directory.url)

        #expect(throws: AgentCodeError.deniedPath(".env")) {
            _ = try workspace.readFile(".env")
        }
    }

    @Test
    func listFilesSkipsBuildAndHiddenDirectories() throws {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1", to: "Sources/App.swift")
        try directory.write("ignored", to: ".build/debug/output.txt")
        let workspace = try Workspace(root: directory.url)

        let files = try workspace.listFiles(limit: 10)

        #expect(files == ["Sources/App.swift"])
    }

    @Test
    func editFileReplacesUniqueTarget() throws {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1\n", to: "Sources/App.swift")
        let workspace = try Workspace(root: directory.url)

        let replacements = try workspace.editFile(
            "Sources/App.swift",
            oldString: "value = 1",
            newString: "value = 2",
            replaceAll: false
        )

        #expect(replacements == 1)
        #expect(try workspace.readFile("Sources/App.swift") == "let value = 2\n")
    }

    @Test
    func editFileRejectsAmbiguousTargetByDefault() throws {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1\nlet other = 1\n", to: "Sources/App.swift")
        let workspace = try Workspace(root: directory.url)

        #expect(throws: AgentCodeError.ambiguousEditTarget(path: "Sources/App.swift", target: " = 1", matches: 2)) {
            _ = try workspace.editFile(
                "Sources/App.swift",
                oldString: " = 1",
                newString: " = 2",
                replaceAll: false
            )
        }
    }

    @Test
    func editFileCanReplaceAllTargets() throws {
        let directory = try TemporaryDirectory()
        try directory.write("alpha\nalpha\n", to: "Sources/App.swift")
        let workspace = try Workspace(root: directory.url)

        let replacements = try workspace.editFile(
            "Sources/App.swift",
            oldString: "alpha",
            newString: "beta",
            replaceAll: true
        )

        #expect(replacements == 2)
        #expect(try workspace.readFile("Sources/App.swift") == "beta\nbeta\n")
    }

    @Test
    func writeFileCreatesParentDirectories() throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)

        let bytes = try workspace.writeFile("Sources/App.swift", content: "let value = 1\n")

        #expect(bytes == 14)
        #expect(try workspace.readFile("Sources/App.swift") == "let value = 1\n")
    }

    @Test
    func writeFileRejectsSymlinkEscapingWorkspace() throws {
        let directory = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        try outside.write("outside\n", to: "target.txt")
        let target = outside.url.appendingPathComponent("target.txt")
        let link = directory.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let workspace = try Workspace(root: directory.url)

        #expect(throws: AgentCodeError.pathEscapesWorkspace("link.txt")) {
            _ = try workspace.writeFile("link.txt", content: "changed\n")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside\n")
    }

    @Test
    func currentDiffReportsUnavailableOutsideGitRepository() async throws {
        let directory = try TemporaryDirectory()
        let workspace = try Workspace(root: directory.url)

        let diff = try await workspace.currentDiff()

        #expect(diff.contains("git diff unavailable"))
    }

    @Test
    func globMatchesWorkspaceFiles() throws {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1", to: "Sources/App.swift")
        try directory.write("plain", to: "README.md")
        let workspace = try Workspace(root: directory.url)

        let files = try workspace.glob("Sources/**/*.swift", limit: 10)

        #expect(files == ["Sources/App.swift"])
    }

    @Test
    func toolLimitRejectsZeroAndExcessiveValues() throws {
        #expect(try ToolLimits.bounded(nil, default: 10, maximum: 20) == 10)
        #expect(throws: AgentCodeError.invalidToolLimit(parameter: "limit", value: 0, allowed: "1...20")) {
            _ = try ToolLimits.bounded(0, default: 10, maximum: 20)
        }
        #expect(throws: AgentCodeError.invalidToolLimit(parameter: "limit", value: 21, allowed: "1...20")) {
            _ = try ToolLimits.bounded(21, default: 10, maximum: 20)
        }
    }
}
