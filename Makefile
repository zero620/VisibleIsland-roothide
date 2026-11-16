TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VisibleIsland
VisibleIsland_FILES = Tweak.x
VisibleIsland_CFLAGS = -fobjc-arc -fno-modules -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-error
VisibleIsland_FRAMEWORKS = UIKit Foundation
VisibleIsland_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += visibleislandprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
