# Wingman Plus — Theos build (macOS + roothide/theos fork)
# Injects ONLY into SpringBoard (see WingmanPlus.plist); never into a dating app.
THEOS_PACKAGE_SCHEME ?= roothide
# SpringBoard is an arm64e platform binary; the tweak must be arm64e with the matching ptrauth ABI.
# Theos + the roothide toolchain produce that correctly (a hand-rolled ld64.lld link did not).
ARCHS = arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WingmanPlus

WingmanPlus_FILES  = Tweak.x WPBubble.m WPCapture.m WPHost.m WPSheet.m WMAPIClient.m WMPrompts.m WMSettings.m WMApps.m WMOCR.m WMModels.m
WingmanPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WingmanPlus_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore Vision

include $(THEOS_MAKE_PATH)/tweak.mk
