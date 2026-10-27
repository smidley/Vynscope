.DEFAULT_GOAL := test
.PHONY: project test mac

# ENABLE_ENHANCED_SECURITY builds the app for arm64e; Xcode builds the BMWCodingCore package for arm64e too only when
# the project's workspace settings say so, and xcodegen cannot write them.
WORKSPACE_SETTINGS := BMWCoding.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings

project:
	xcodegen generate --quiet
	mkdir -p $(dir $(WORKSPACE_SETTINGS))
	plutil -create xml1 $(WORKSPACE_SETTINGS)
	plutil -insert macOSPackagesShouldBuildARM64e -bool YES $(WORKSPACE_SETTINGS)
	plutil -insert iOSPackagesShouldBuildARM64e -bool YES $(WORKSPACE_SETTINGS)

test:
	cd Core && swift test

mac: project
	xcodebuild -project BMWCoding.xcodeproj -scheme BMWCoding -destination 'platform=macOS' -derivedDataPath build -quiet build
	open build/Build/Products/Debug/BMWCoding.app
