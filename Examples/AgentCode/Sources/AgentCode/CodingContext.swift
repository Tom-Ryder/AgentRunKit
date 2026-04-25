import AgentRunKit
import Foundation

struct CodingContext: ToolContext {
    let workspace: Workspace
    let commandRunner: CommandRunner
}
