# Wingman Plus — Theos build (macOS + roothide/theos fork)
# Injects ONLY into SpringBoard (see WingmanPlus.plist); never into a dating app.
THEOS_PACKAGE_SCHEME ?= roothide
# SpringBoard is an arm64e PLATFORM binary built with the *versioned* ptrauth ABI
# (cpusubtype 0x80000002). dyld silently refuses an arm64e dylib tagged with the old
# "preview" ABI (0x00000002) into it - which is why every Linux-toolchain build
# installed but never loaded. Building on macOS with Xcode's clang (see the CI
# workflow) produces the versioned ABI, exactly like Snapper. Fat arm64+arm64e
# matches the known-good reference and is verified in CI before packaging.
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WingmanPlus

# WPScroll.m (HID swipe synthesis) is intentionally left OUT: cross-process touch
# injection from SpringBoard doesn't drive the app's scroll views on iOS 16, so we use
# user-driven scroll-capture instead (hold to start, flick, tap to finish). The file is
# kept in the tree for reference only.
WingmanPlus_FILES  = Tweak.x WPBubble.m WPCapture.m WPHost.m WPSheet.m WMAPIClient.m WMPrompts.m WMSettings.m WMApps.m WMOCR.m WMModels.m
WingmanPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WingmanPlus_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore Vision AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
