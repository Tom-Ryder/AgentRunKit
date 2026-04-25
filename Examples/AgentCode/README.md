# AgentCode

AgentCode is an interactive terminal coding agent built with AgentRunKit.

It opens a local workspace, streams the agent loop, shows tool calls as they happen, and asks before editing files or running verification commands.

## Run

```bash
cd Examples/AgentCode
swift run agent-code
```

By default AgentCode opens the bundled `DemoWorkspace`, which contains a small broken Swift package.

Use a real project explicitly:

```bash
swift run agent-code --workspace /path/to/project
```

## Provider

AgentCode uses OpenAI-compatible Chat Completions.

```bash
export OPENAI_API_KEY="sk-..."
export OPENAI_MODEL="gpt-5.4"
```

Optional:

```bash
export OPENAI_PROFILE="openai"
export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
```

`OPENAI_PROFILE` supports `openai`, `openrouter`, and `compatible`.

Without `OPENAI_API_KEY`, AgentCode starts in deterministic offline mode. Offline mode is useful for smoke testing the CLI, but a live model is needed for the full coding-agent experience.

## Approval Smoke Test

Verify that the terminal approval prompt is visible and accepts input without calling a model:

```bash
swift run agent-code --approval-smoke-test
```

The command should show an edit preview, print `Approve? [y]es / [n]o:`, and return `decision: approve` after `y`.

## Session Commands

- `/help`
- `/status`
- `/diff`
- `/model`
- `/permissions`
- `/reset`
- `/transcript`
- `/exit`
