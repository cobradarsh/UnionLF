include $(THEOS)/makefiles/common.mk

# Built as a .bundle here; the top-level Makefile renames it to .appex after staging
# (iOS loads app extensions only from PlugIns/*.appex).
BUNDLE_NAME = WingmanKeyboard

WingmanKeyboard_FILES = KeyboardViewController.m
WingmanKeyboard_FRAMEWORKS = UIKit Foundation
WingmanKeyboard_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# Live inside the container app's PlugIns folder.
WingmanKeyboard_INSTALL_PATH = /Applications/WingmanKB.app/PlugIns

include $(THEOS_MAKE_PATH)/bundle.mk
