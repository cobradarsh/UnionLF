# Shani — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# Loads into SpringBoard, an arm64e platform process: build on macOS with Xcode's clang, which
# tags the arm64e slice with the versioned ptrauth ABI (0x80000002). CI refuses to package
# anything else (tools/verify_dylib.py).
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Shani ShaniPrefs

Shani_FILES = Tweak.m ShaniCore.m ShaniStore.m ShaniEngine.m ShaniHooks.m ShaniUI.m ShaniDebug.m
Shani_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
Shani_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
# Nothing is hooked through a hooking library (ShaniHook in ShaniCore.m uses the runtime),
# so the dylib links iOS's own libraries only.
Shani_USE_SUBSTRATE = 0
Shani_LDFLAGS = -Wl,-dead_strip_dylibs

# ShaniPrefs goes into the Settings app (ShaniPrefs.plist): the Apps & Log screens of
# Settings → Shani. Its screens are PSViewControllers, so it links Settings' own framework.
ShaniPrefs_FILES = PrefsHelper.m ShaniCore.m ShaniStore.m
ShaniPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
ShaniPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
ShaniPrefs_PRIVATE_FRAMEWORKS = Preferences
ShaniPrefs_USE_SUBSTRATE = 0
ShaniPrefs_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
