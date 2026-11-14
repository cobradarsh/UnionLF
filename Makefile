# Dynamic Stage+ — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# Loads into SpringBoard AND apps (StageDuoPlus.plist filters on com.apple.UIKit), so it must
# load into arm64e platform processes: build on macOS with Xcode's clang, which tags the arm64e
# slice with the versioned ptrauth ABI (0x80000002). CI refuses to package anything else
# (tools/verify_arm64e.py) - the lesson from Wingman Plus.
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StageDuoPlus

StageDuoPlus_FILES = Tweak.m SDPCore.m SDPStage.m SDPButtons.m SDPPairsSheet.m SDPApp.m SDPDebug.m
StageDuoPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
StageDuoPlus_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
