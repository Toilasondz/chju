TARGET := iphone:clang:14.5:14.0
ARCHS := arm64 arm64e
DEBUG := 0
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VideoStarTool

VideoStarTool_FILES = Tweak.xm
VideoStarTool_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
VideoStarTool_FRAMEWORKS = UIKit Foundation CoreGraphics Photos PhotosUI AVFoundation CoreMedia

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 VideoStar || true"
