# Wingman — Theos build (macOS + roothide/theos fork)
# The RootHide scheme gives Architecture iphoneos-arm64e and the .jbroot
# install_name automatically. Needs the fork: github.com/roothide/theos
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Wingman

Wingman_FILES  = Tweak.x WMBubble.m WMCapture.m WMSheet.m WMAPIClient.m WMPrompts.m WMSettings.m WMApps.m WMQuickReplies.m WMOCR.m WMModels.m WMContacts.m
Wingman_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Wingman_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore Vision

include $(THEOS_MAKE_PATH)/tweak.mk
