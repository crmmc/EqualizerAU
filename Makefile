PROJECT := EqualizerAU.xcodeproj
SCHEME  := EqualizerAU
CONFIG  := Debug
DEST    := platform=macOS,arch=arm64
DD      := .build/DerivedData
BIN_DIR := build/bin
COVERAGE_DIR := build/coverage
COVERAGE_RESULT := $(COVERAGE_DIR)/EqualizerAU.xcresult

APP_NAME  := EqualizerAU.app
APP_PATH   := Build/Products/$(CONFIG)/M1/$(APP_NAME)
BUILT_APP  := $(DD)/$(APP_PATH)

.PHONY: all build release test coverage clean

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST)' -derivedDataPath $(DD) build
	@mkdir -p $(BIN_DIR)
	@rm -rf $(BIN_DIR)/$(APP_NAME)
	@cp -R "$(BUILT_APP)" $(BIN_DIR)/
	@echo "Output: $(BIN_DIR)/$(APP_NAME)"

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(DEST)' -derivedDataPath $(DD) build
	@mkdir -p $(BIN_DIR)
	@rm -rf $(BIN_DIR)/$(APP_NAME)
	@cp -R "$(DD)/Build/Products/Release/M1/$(APP_NAME)" $(BIN_DIR)/
	@echo "Output: $(BIN_DIR)/$(APP_NAME)"

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST)' -derivedDataPath $(DD) $(XCODEBUILD_ARGS) test

coverage:
	@mkdir -p $(COVERAGE_DIR)
	@rm -rf $(COVERAGE_RESULT)
	xcodebuild -project $(PROJECT) -scheme EqualizerAUM1 -configuration Debug \
		-destination '$(DEST)' -derivedDataPath $(DD) \
		-resultBundlePath $(COVERAGE_RESULT) -enableCodeCoverage YES \
		CODE_SIGNING_ALLOWED=NO \
		-only-testing:EqualizerAUM1RuntimeTests \
		-skip-testing:EqualizerAUM1RuntimeTests/EAUM1RuntimeSmokeTests/testTenThousandPublicationsRaceARealCallbackThreadWithoutLeaks \
		test
	@ruby scripts/check-m1-coverage.rb $(COVERAGE_RESULT)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DD) clean
	rm -rf $(BIN_DIR)
