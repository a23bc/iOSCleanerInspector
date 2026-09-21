APP_NAME := iOSCleanerInspector
BUNDLE_ID := com.a23bc.iOSCleanerInspector
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
PAYLOAD_DIR := $(BUILD_DIR)/Payload
TIPA := $(BUILD_DIR)/$(APP_NAME).tipa
ENTITLEMENTS := $(APP_NAME).entitlements

# Never rm -rf: stale artifacts are moved here instead of being deleted.
TRASH_DIR := .trash/$(shell date +%Y%m%d%H%M%S)

SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang
CFLAGS := -fobjc-arc -isysroot "$(SDK)" -miphoneos-version-min=15.0
LDFLAGS := -framework UIKit -framework Foundation
CODESIGN := codesign --force --sign - --generate-entitlement-der --timestamp=none

SOURCES := \
	iOSCleanerInspector/AppDelegate.m \
	iOSCleanerInspector/ViewController.m \
	iOSCleanerInspector/Scanner/Scanner.m \
	iOSCleanerInspector/Scanner/AppScanner.m \
	iOSCleanerInspector/Scanner/SystemScanner.m

.PHONY: all clean sign verify package

all: $(APP_DIR)/$(APP_NAME)

$(APP_DIR)/$(APP_NAME): $(SOURCES) iOSCleanerInspector/ViewController.h iOSCleanerInspector/Info.plist $(ENTITLEMENTS) build/embedded-entitlements.plist
	@mkdir -p "$(APP_DIR)"
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) \
		-Wl,-sectcreate,__TEXT,__entitlements,build/embedded-entitlements.plist \
		-o "$@"
	@cp iOSCleanerInspector/Info.plist "$(APP_DIR)/Info.plist"
	@cp iOSCleanerInspector/embedded.mobileprovision "$(APP_DIR)/embedded.mobileprovision" 2>/dev/null || true

build/embedded-entitlements.plist: $(ENTITLEMENTS)
	@mkdir -p "$(BUILD_DIR)"
	@cp "$<" "$@"

# The -sectcreate section alone is not enough: iOS only honours entitlements
# that live inside an actual code signature, and TrollStore keeps whatever
# entitlements it finds there when it re-signs on device. Do both.
sign: all
	$(CODESIGN) --entitlements "$(ENTITLEMENTS)" "$(APP_DIR)"

verify: sign
	@codesign --verify --verbose=2 "$(APP_DIR)"
	@codesign --display --verbose=2 "$(APP_DIR)"
# NOT "codesign --entitlements :-" : that form is deprecated.
	@codesign --display --entitlements "$(BUILD_DIR)/granted.plist" --xml "$(APP_DIR)"
	@/usr/libexec/PlistBuddy -c "Print" "$(BUILD_DIR)/granted.plist"

package: verify
	@mkdir -p "$(TRASH_DIR)"
	@[ ! -e "$(PAYLOAD_DIR)" ] || mv "$(PAYLOAD_DIR)" "$(TRASH_DIR)/"
	@[ ! -e "$(TIPA)" ] || mv "$(TIPA)" "$(TRASH_DIR)/"
	@mkdir -p "$(PAYLOAD_DIR)"
	@cp -R "$(APP_DIR)" "$(PAYLOAD_DIR)/"
	@cd "$(BUILD_DIR)" && zip -qry "$(APP_NAME).tipa" Payload
	@echo "Created $(TIPA)"

clean:
	@mkdir -p "$(TRASH_DIR)"
	@[ ! -e "$(BUILD_DIR)" ] || mv "$(BUILD_DIR)" "$(TRASH_DIR)"
	@echo "Moved $(BUILD_DIR) to $(TRASH_DIR)"
