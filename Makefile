APP_NAME   = Shortlist
APP_BUNDLE = $(APP_NAME).app
BUILD_DIR  = .build/release

.PHONY: build run test clean

test:
	swift test

# Signing with a stable identity keeps the Keychain's "Always Allow" across rebuilds. An ad-hoc
# signature changes every build, and macOS then treats each build as a new app.
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)

# Builds Shortlist.app in the project folder. The bundle is assembled and signed in a
# /tmp stage, then copied back: this folder is cloud-synced, and the sync can tag files while
# codesign runs (the same reason Tucket's Makefile does it this way).
build:
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	$(eval STAGE := $(shell mktemp -d /tmp/shortlist-build.XXXXXX))
	@mkdir -p "$(STAGE)/$(APP_BUNDLE)/Contents/MacOS" "$(STAGE)/$(APP_BUNDLE)/Contents/Resources"
	@cp $(BUILD_DIR)/$(APP_NAME) "$(STAGE)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(STAGE)/$(APP_BUNDLE)/Contents/Info.plist"
	@xattr -cr "$(STAGE)/$(APP_BUNDLE)"
	@codesign --force --timestamp=none --sign "$(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)" "$(STAGE)/$(APP_BUNDLE)"
	@ditto "$(STAGE)/$(APP_BUNDLE)" $(APP_BUNDLE)
	@rm -rf "$(STAGE)"
	@echo "Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE)
