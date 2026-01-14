.PHONY: build test lint format check clean

build:
	swift build

test:
	swift test

lint:
	swiftlint

format:
	swiftformat .

check: format lint test

clean:
	swift package clean
