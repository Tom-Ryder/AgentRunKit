# Examples

Run complete examples that show how AgentRunKit behaves outside isolated snippets.

## AgentCode

`Examples/AgentCode` is an interactive terminal coding agent built on ``Chat`` and type-safe ``Tool`` definitions. It opens a local workspace, streams tool activity, asks for approval before edits or commands, and records a JSON transcript of ``StreamEvent`` values.

```bash
cd Examples/AgentCode
swift run agent-code
```

The default workspace is `Examples/AgentCode/DemoWorkspace`, a small Swift package with a failing test. That makes the first run concrete: ask AgentCode to inspect the project, fix the failing tests, and run verification.

## Provider Modes

Without `OPENAI_API_KEY`, AgentCode uses deterministic offline mode. That path proves the CLI, tool schemas, event rendering, approval prompt, and workspace boundaries without making a network request.

For a live model, configure an OpenAI-compatible provider:

```bash
export OPENAI_API_KEY="sk-..."
export OPENAI_MODEL="gpt-5.4"
```

Optional provider settings:

```bash
export OPENAI_PROFILE="openai"
export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
```

`OPENAI_PROFILE` supports `openai`, `openrouter`, and `compatible`.

## What It Demonstrates

- Streaming token and tool events through ``Chat``.
- File-system tools modeled as typed ``Tool`` values with `Codable` parameters and outputs.
- Approval-gated writes and verification commands via ``ToolApprovalPolicy``.
- Local workspace safety: path containment, secret-file denial, bounded reads, command allowlisting, and output truncation.
- A runnable offline path that exercises tool discovery and event rendering without credentials.

Run the example tests with:

```bash
swift test --package-path Examples/AgentCode -Xswiftc -warnings-as-errors
```
