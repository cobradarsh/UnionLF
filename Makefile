# Guest Mode — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# GuestMode.dylib goes into the Photos app and GuestModeSB.dylib into SpringBoard, arm64e processes: build on macOS with Xcode's clang,
# which tags the arm64e slice with the versioned ptrauth ABI (0x80000002). CI refuses to package
# anything else (tools/verify_dylib.py).
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GuestMode GuestModeSB

GuestMode_FILES = GMCore.m GMAuth.m GMButton.m GMGallery.m GMDebug.m
GuestMode_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
GuestMode_FRAMEWORKS = UIKit Foundation Photos PhotosUI AVKit AVFoundation CoreMedia LocalAuthentication CoreGraphics QuartzCore
# Nothing in Photos is hooked: the library links iOS's own libraries only.
GuestMode_USE_SUBSTRATE = 0
GuestMode_LDFLAGS = -Wl,-dead_strip_dylibs

# GuestModeSB goes into SpringBoard (GuestModeSB.plist): while Guest Mode is on in Photos it keeps
# the iPhone there. Its hooks are made with the Objective-C runtime; no hooking library is linked.
GuestModeSB_FILES = GMSpringBoard.m
GuestModeSB_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
GuestModeSB_FRAMEWORKS = UIKit Foundation CoreFoundation
GuestModeSB_USE_SUBSTRATE = 0
GuestModeSB_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
