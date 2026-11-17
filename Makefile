# Chakra — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# Loads into SpringBoard, an arm64e platform process: build on macOS with Xcode's clang, which
# tags the arm64e slice with the versioned ptrauth ABI (0x80000002). CI refuses to package
# anything else (tools/verify_arm64e.py) - the lesson from Wingman Plus.
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Chakra

Chakra_FILES = Tweak.m ChakraCore.m ChakraGlyphs.m ChakraGlass.m ChakraItems.m ChakraActions.m ChakraLayout.m ChakraWheel.m ChakraBall.m ChakraEditor.m ChakraDebug.m
Chakra_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
Chakra_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
