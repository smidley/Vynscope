.DEFAULT_GOAL := test
.PHONY: project test mac

project:
	xcodegen generate --quiet

test:
	cd Core && swift test

mac: project
	xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build
	open build/Build/Products/Debug/Vynscope.app
