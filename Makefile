# Atelier — Theos build (macOS + roothide/theos fork, see .github/workflows/build.yml)
#
# Loads into SpringBoard, an arm64e platform process: build on macOS with Xcode's clang, which
# tags the arm64e slice with the versioned ptrauth ABI (0x80000002). CI refuses to package
# anything else (tools/verify_arm64e.py) - the lesson from Wingman Plus.
THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Atelier

Atelier_FILES = Tweak.m AtelierCore.m AtelierScenes.m AtelierLayout.m AtelierBench.m AtelierSheets.m AtelierTrigger.m AtelierDebug.m
Atelier_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable
Atelier_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
# Nothing is hooked through a hooking library (AtelierHook in AtelierCore.m uses the runtime),
# so the dylib links iOS's own libraries only.
Atelier_USE_SUBSTRATE = 0
Atelier_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
