.PHONY: build test test-ci lint format format-check check dev-check clean bootstrap docs docs-preview smoke

bootstrap:
	brew install mint
	mint bootstrap

build:
	swift build

test:
	swift test

test-ci:
	swift test --parallel -Xswiftc -warnings-as-errors

lint:
	mint run swiftlint --strict

format:
	mint run swiftformat .

format-check:
	mint run swiftformat --lint .

dev-check: format lint test

check: format-check lint test-ci docs

docs:
	swift package generate-documentation --target AgentRunKit
	swift package generate-documentation --target AgentRunKitTesting
	swift package generate-documentation --target AgentRunKitFoundationModels
	swift package generate-documentation --target AgentRunKitMLX

docs-preview:
	swift package --disable-sandbox preview-documentation --target AgentRunKit

smoke:
	@if [ -f .env ]; then set -a && . ./.env && set +a; fi && swift test --filter Smoke

clean:
	swift package clean
