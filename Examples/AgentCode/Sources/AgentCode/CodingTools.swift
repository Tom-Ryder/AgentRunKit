import AgentRunKit
import Foundation

enum CodingTools {
    static func makeTools() throws -> [any AnyTool<CodingContext>] {
        try [
            workspaceStatusTool(),
            listFilesTool(),
            readFileTool(),
            grepTool(),
            globTool(),
            gitDiffTool(),
            editFileTool(),
            multiEditTool(),
            writeFileTool(),
            runCommandTool()
        ]
    }

    private static func workspaceStatusTool() throws -> some AnyTool<CodingContext> {
        try Tool<EmptyParameters, WorkspaceStatus, CodingContext>(
            name: "workspace_status",
            description: "Inspect the current workspace root, detected package type, and git status.",
            isConcurrencySafe: true
        ) { _, context in
            let gitStatus = try await context.commandRunner.run(
                CommandInvocation(command: "git", arguments: ["status", "--short", "--branch"], timeoutSeconds: 10),
                in: context.workspace
            )
            return WorkspaceStatus(
                root: context.workspace.root.path,
                packageType: detectPackageType(in: context.workspace.root),
                gitStatus: gitStatus.combinedOutput
            )
        }
    }

    private static func listFilesTool() throws -> some AnyTool<CodingContext> {
        try Tool<ListFilesParameters, FileList, CodingContext>(
            name: "list_files",
            description: "List text-oriented source files in the workspace.",
            isConcurrencySafe: true
        ) { params, context in
            let limit = try ToolLimits.bounded(params.limit, default: 250, maximum: 500)
            let files = try context.workspace.listFiles(limit: limit + 1)
            return FileList(files: Array(files.prefix(limit)), truncated: files.count > limit)
        }
    }

    private static func readFileTool() throws -> some AnyTool<CodingContext> {
        try Tool<ReadFileParameters, FileContent, CodingContext>(
            name: "read_file",
            description: "Read one UTF-8 text file inside the workspace.",
            isConcurrencySafe: true
        ) { params, context in
            try FileContent(path: params.path, content: context.workspace.readFile(params.path))
        }
    }

    private static func grepTool() throws -> some AnyTool<CodingContext> {
        try Tool<GrepParameters, SearchResults, CodingContext>(
            name: "grep",
            description: "Search workspace text files by literal text or regular expression.",
            isConcurrencySafe: true
        ) { params, context in
            try SearchEngine().search(
                query: params.query,
                regex: params.regex ?? false,
                limit: ToolLimits.bounded(params.limit, default: 50, maximum: 200),
                workspace: context.workspace
            )
        }
    }

    private static func globTool() throws -> some AnyTool<CodingContext> {
        try Tool<GlobParameters, FileList, CodingContext>(
            name: "glob",
            description: "Find workspace files matching a glob pattern such as Sources/**/*.swift.",
            isConcurrencySafe: true
        ) { params, context in
            let limit = try ToolLimits.bounded(params.limit, default: 100, maximum: 500)
            let files = try context.workspace.glob(params.pattern, limit: limit + 1)
            return FileList(files: Array(files.prefix(limit)), truncated: files.count > limit)
        }
    }

    private static func gitDiffTool() throws -> some AnyTool<CodingContext> {
        try Tool<EmptyParameters, String, CodingContext>(
            name: "git_diff",
            description: "Return the current git diff for the workspace.",
            isConcurrencySafe: true
        ) { _, context in
            try await context.workspace.currentDiff()
        }
    }

    private static func editFileTool() throws -> some AnyTool<CodingContext> {
        try Tool<EditFileParameters, FileEditResult, CodingContext>(
            name: "edit_file",
            description: "Replace an exact string in an existing file. The old string must match exactly once."
        ) { params, context in
            let replacements = try context.workspace.editFile(
                params.path,
                oldString: params.oldString,
                newString: params.newString,
                replaceAll: params.replaceAll ?? false
            )
            let diff = try await context.workspace.currentDiff()
            return FileEditResult(path: params.path, replacements: replacements, diff: diff)
        }
    }

    private static func multiEditTool() throws -> some AnyTool<CodingContext> {
        try Tool<MultiEditParameters, FileEditResult, CodingContext>(
            name: "multi_edit",
            description: "Apply a sequence of exact string replacements to one existing file."
        ) { params, context in
            let replacements = try context.workspace.applyEdits(params.path, edits: params.edits)
            let diff = try await context.workspace.currentDiff()
            return FileEditResult(path: params.path, replacements: replacements, diff: diff)
        }
    }

    private static func writeFileTool() throws -> some AnyTool<CodingContext> {
        try Tool<WriteFileParameters, FileWriteResult, CodingContext>(
            name: "write_file",
            description: "Create or overwrite a UTF-8 text file in the workspace."
        ) { params, context in
            let bytes = try context.workspace.writeFile(params.path, content: params.content)
            let diff = try await context.workspace.currentDiff()
            return FileWriteResult(path: params.path, bytes: bytes, diff: diff)
        }
    }

    private static func runCommandTool() throws -> some AnyTool<CodingContext> {
        try Tool<RunCommandParameters, CommandResult, CodingContext>(
            name: "run_command",
            description: "Run an allowlisted verification command in the workspace.",
            toolTimeout: .seconds(300)
        ) { params, context in
            try await context.commandRunner.run(
                CommandInvocation(
                    command: params.command,
                    arguments: params.arguments,
                    timeoutSeconds: params.timeoutSeconds
                ),
                in: context.workspace
            )
        }
    }

    private static func detectPackageType(in root: URL) -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return "Swift Package"
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("package.json").path) {
            return "npm package"
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) {
            return "Python package"
        }
        return "unknown"
    }
}

enum ToolLimits {
    static func bounded(_ value: Int?, default defaultValue: Int, maximum: Int) throws -> Int {
        let limit = value ?? defaultValue
        guard (1 ... maximum).contains(limit) else {
            throw AgentCodeError.invalidToolLimit(parameter: "limit", value: limit, allowed: "1...\(maximum)")
        }
        return limit
    }
}
