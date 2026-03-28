.PHONY: build test lint format check clean bootstrap docs docs-preview

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

docs-preview:
	swift package --disable-sandbox preview-documentation --target AgentRunKit

clean:
	swift package clean
