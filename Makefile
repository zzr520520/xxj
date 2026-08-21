TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyAppWiper
MyAppWiper_FILES = src/Hooks.m src/WiperHelper.m src/WiperSnapshotManager.m src/LocationFaker.m src/NetworkFaker.m
MyAppWiper_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Wl,-sectcreate,__RESTRICT,__restrict,/dev/null
MyAppWiper_FRAMEWORKS = UIKit Security Foundation CoreFoundation MobileCoreServices CoreTelephony IOKit WebKit SystemConfiguration CoreLocation Metal StoreKit AdSupport
MyAppWiper_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += App
include $(THEOS_MAKE_PATH)/aggregate.mk