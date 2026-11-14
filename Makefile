# BluetoothNoClicks — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# Loads into SpringBoard, an arm64e platform process: build on macOS with Xcode's clang, which
# tags the arm64e slice with the versioned ptrauth ABI (0x80000002). CI refuses to package
# anything else (tools/verify_arm64e.py) - the lesson from Wingman Plus.
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluetoothNoClicks

BluetoothNoClicks_FILES = Tweak.m
BluetoothNoClicks_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
BluetoothNoClicks_FRAMEWORKS = Foundation AVFoundation AudioToolbox CallKit

include $(THEOS_MAKE_PATH)/tweak.mk
