ARCHS = arm64
TARGET = iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SecurityCam
SecurityCam_FILES = \
	app/main.m \
	app/BSCSecurityCamAppDelegate.mm \
	app/BSCModeController.mm \
	app/BSCBonjourPublisher.mm \
	app/BSCVideoEncoder.mm \
	app/BSCRTSPServer.mm \
	app/BSCHTTPServer.mm \
	shared/BSCModeState.m
SecurityCam_FRAMEWORKS = UIKit Foundation AVFoundation VideoToolbox CoreMedia CoreVideo CoreImage
SecurityCam_CFLAGS = -fobjc-arc -fno-objc-msgsend-selector-stubs
SecurityCam_CODESIGN_FLAGS = -Sentitlements.plist
SecurityCam_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

TOOL_NAME = camera-mode securitycamd
camera-mode_FILES = tools/camera-mode.m shared/BSCModeState.m
camera-mode_FRAMEWORKS = Foundation
camera-mode_CFLAGS = -fobjc-arc -fno-objc-msgsend-selector-stubs

securitycamd_FILES = daemon/securitycamd.m shared/BSCModeState.m
securitycamd_FRAMEWORKS = Foundation
securitycamd_CFLAGS = -fobjc-arc -fno-objc-msgsend-selector-stubs

include $(THEOS_MAKE_PATH)/tool.mk

TWEAK_NAME = SecurityCamEscape
SecurityCamEscape_FILES = tweak/Tweak.xm shared/BSCModeState.m
SecurityCamEscape_FRAMEWORKS = UIKit Foundation
SecurityCamEscape_CFLAGS = -fobjc-arc -fno-objc-msgsend-selector-stubs

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "uicache -p /Applications/SecurityCam.app >/dev/null 2>&1 || true"
	install.exec "launchctl unload /Library/LaunchDaemons/com.github.bryce.securitycamd.plist >/dev/null 2>&1 || true"
	install.exec "launchctl load /Library/LaunchDaemons/com.github.bryce.securitycamd.plist >/dev/null 2>&1 || true"
