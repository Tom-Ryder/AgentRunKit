# Contributing to AgentRunKit

Thanks for your interest in contributing.

## Setup

```bash
# Install tools
make bootstrap

# Verify everything works
make check
```

`make bootstrap` installs [Mint](https://github.com/yonaskolb/Mint) and the pinned versions of SwiftFormat and SwiftLint from the `Mintfile`.

## Before Submitting a PR

Run the full gate:

```bash
make check
```

This runs `swiftformat`, `swiftlint --strict`, and `swift test`. CI runs the same checks — if `make check` passes locally, CI will pass.

## Code Style

- SwiftFormat and SwiftLint enforce the style. Don't fight the tools.
- No comments or docstrings unless explaining a non-obvious *why*.
- No backward-compatibility hacks. Prefer the most elegant solution.
- All public types must be `Sendable`.

See `CLAUDE.md` for the full coding standards.

## Commit Messages

Format: `verb(scope): description`

```
add(gemini): google gemini client with streaming and tool calling
fix(auth): prevent token refresh race on concurrent requests
refactor(api): extract shared validation into middleware
```

Single sentence, lowercase, imperative mood, no trailing period.

## Tests

Every change needs tests. Test behavior, not implementation details. Run with:

```bash
swift test --filter YourTestSuite
```
