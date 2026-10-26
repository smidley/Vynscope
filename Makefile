.PHONY: project test

project:
	xcodegen generate --quiet

test:
	cd Core && swift test
