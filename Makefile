.PHONY: build test lint format check clean bootstrap

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

clean:
	swift package clean
