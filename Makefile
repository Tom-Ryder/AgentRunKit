.PHONY: build test lint format check clean bootstrap docs docs-preview smoke

bootstrap:
	brew install mint
	mint bootstrap

build:
	swift build

test:
	swift test

lint:
	mint run swiftlint --strict

format:
	mint run swiftformat .

check: format lint test

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
