# IWantTranslucent Lean: Theos build (macOS + roothide/theos, see .github/workflows/build.yml)
#
# The library goes into every process that has UIKit: SpringBoard and Apple's apps are arm64e,
# App Store apps are arm64, so both slices are needed. The arm64e one has to carry the versioned
# ptrauth ABI (0x80000002), which only Xcode's clang produces; tools/verify_dylib.py refuses
# anything else, and anything that links more than the system's own libraries.
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IWantTranslucent

IWantTranslucent_FILES = Tweak.m
IWantTranslucent_CFLAGS = -fobjc-arc
IWantTranslucent_FRAMEWORKS = UIKit Foundation
# Methods are swapped with the Objective-C runtime itself: no hooking library is used or linked.
IWantTranslucent_USE_SUBSTRATE = 0
IWantTranslucent_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
