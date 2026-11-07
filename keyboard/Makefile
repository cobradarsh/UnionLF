# Wingman Keyboard - a container app (WingmanKB.app) that hosts a custom keyboard
# extension (WingmanKeyboard.appex in its PlugIns). Separate package from the tweak so
# it can never destabilise the working SpringBoard dylib.
#
# Built on macOS with Xcode clang (same reason as the tweak: versioned arm64e ABI).
THEOS_PACKAGE_SCHEME ?= roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

# Build the extension first, then the app it lives in.
SUBPROJECTS = keyboardext app

include $(THEOS_MAKE_PATH)/aggregate.mk

# Theos builds the extension as WingmanKeyboard.bundle; iOS loads app extensions only
# from PlugIns/*.appex, so rename the staged bundle after everything is staged.
after-stage::
	@d=`find "$(THEOS_STAGING_DIR)" -name 'WingmanKeyboard.bundle' -type d 2>/dev/null | head -1`; \
	if [ -n "$$d" ]; then mv "$$d" "$${d%.bundle}.appex" && echo "renamed appex: $${d%.bundle}.appex"; \
	else echo "WARN: WingmanKeyboard.bundle not found in staging"; fi
