export TARGET := iphone:clang:latest:14.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarCheckPlugin

CarCheckPlugin_FILES = Source/Tweak.x Source/CarCheckFloatingView.m
CarCheckPlugin_CFLAGS = -fobjc-arc
CarCheckPlugin_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk