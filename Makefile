APP_NAME := iOSCleanerInspector
BUNDLE_ID := com.a23bc.iOSCleanerInspector
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
PAYLOAD_DIR := $(BUILD_DIR)/Payload
TIPA := $(BUILD_DIR)/$(APP_NAME).tipa

SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := xcrun --sdk iphoneos clang
CFLAGS := -fobjc-arc -isysroot "$(SDK)" -miphoneos-version-min=15.0
LDFLAGS := -framework UIKit -framework Foundation

SOURCES := \
	iOSCleanerInspector/AppDelegate.m \
	iOSCleanerInspector/ViewController.m \
	iOSCleanerInspector/Scanner/Scanner.m \
	iOSCleanerInspector/Scanner/AppScanner.m \
	iOSCleanerInspector/Scanner/SystemScanner.m

.PHONY: all clean package

all: $(APP_DIR)/$(APP_NAME)

$(APP_DIR)/$(APP_NAME): $(SOURCES) iOSCleanerInspector/ViewController.h iOSCleanerInspector/Info.plist iOSCleanerInspector.entitlements build/embedded-entitlements.plist
	@mkdir -p "$(APP_DIR)"
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) \
		-Wl,-sectcreate,__TEXT,__entitlements,build/embedded-entitlements.plist \
		-o "$@"
	@cp iOSCleanerInspector/Info.plist "$(APP_DIR)/Info.plist"
	@cp iOSCleanerInspector/embedded.mobileprovision "$(APP_DIR)/embedded.mobileprovision" 2>/dev/null || true

build/embedded-entitlements.plist: iOSCleanerInspector.entitlements
	@mkdir -p "$(BUILD_DIR)"
	@cp "$<" "$@"

package: all
	@rm -rf "$(PAYLOAD_DIR)" "$(TIPA)"
	@mkdir -p "$(PAYLOAD_DIR)"
	@cp -R "$(APP_DIR)" "$(PAYLOAD_DIR)/"
	@cd "$(BUILD_DIR)" && zip -qry "$(APP_NAME).tipa" Payload
	@echo "Created $(TIPA)"

clean:
	@rm -rf "$(BUILD_DIR)"
