# VidGrab — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# VidGrab.dylib goes into the apps listed in VidGrab.plist (plain arm64 processes), VidGrabSB.dylib
# into SpringBoard (arm64e): build on macOS with Xcode's clang, which tags the arm64e slice with the
# versioned ptrauth ABI (0x80000002). CI refuses to package anything else (tools/verify_dylib.py).
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VidGrab VidGrabSB

VG_WARN = -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable

VidGrab_FILES = VGMain.m VGCore.m VGPlaylist.m VGFetch.m VGTS.m VGMux.m VGJob.m VGCapture.m VGUI.m VGDeliver.m VGPicture.m VGDebug.m VGFinger.m 	VGSGifMaker.m VGSCommon.m VGSGifWriter.c
VidGrab_CFLAGS = -fobjc-arc $(VG_WARN)
VidGrab_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo AudioToolbox CoreGraphics QuartzCore Photos ImageIO Accelerate
# Hooks are made with the Objective-C runtime (VGHook in VGCore.m): the library links iOS's own
# libraries only, nothing from the jailbreak is pulled into the apps.
VidGrab_USE_SUBSTRATE = 0
VidGrab_LDFLAGS = -Wl,-dead_strip_dylibs

VidGrabSB_FILES = VidGrabSB.m
VidGrabSB_CFLAGS = -fobjc-arc $(VG_WARN)
VidGrabSB_FRAMEWORKS = Foundation
VidGrabSB_USE_SUBSTRATE = 0
VidGrabSB_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
