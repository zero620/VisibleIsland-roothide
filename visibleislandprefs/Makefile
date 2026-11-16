TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VisibleIslandPrefs

VisibleIslandPrefs_FILES = VISRootListController.m POSRootListController.m CLRRootListController.m NOTRootListController.m SCLRootListController.m
VisibleIslandPrefs_FRAMEWORKS = UIKit
VisibleIslandPrefs_PRIVATE_FRAMEWORKS = Preferences
VisibleIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles
VisibleIslandPrefs_CFLAGS = -fobjc-arc -fno-modules -Wno-deprecated-declarations -Wno-error

include $(THEOS_MAKE_PATH)/bundle.mk
