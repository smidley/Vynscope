.DEFAULT_GOAL := test
.PHONY: project test mac

project:
	xcodegen generate --quiet

test:
	cd Core && swift test

mac: project
	xcodebuild -project Vynscope.xcodeproj -scheme Vynscope -destination 'platform=macOS' -derivedDataPath build -quiet build
	touch build/Build/Products/Debug/Vynscope.app  # the Dock caches the icon by the bundle's date, which xcodebuild leaves alone
	open build/Build/Products/Debug/Vynscope.app
