#import "BSCModeState.h"
#import <notify.h>

NSString * const BSCBundleIdentifier = @"com.github.bryce.securitycam";
NSString * const BSCModePreferencePath = @"/var/mobile/Library/Preferences/com.github.bryce.securitycam.mode.plist";
const char *BSCModeChangedNotification = "com.github.bryce.securitycam.mode.changed";

@implementation BSCModeState

+ (NSDictionary *)currentState {
	NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:BSCModePreferencePath];
	return [state isKindOfClass:[NSDictionary class]] ? state : @{};
}

+ (BOOL)isEnabled {
	return [[self currentState][@"Enabled"] boolValue];
}

+ (BOOL)setEnabled:(BOOL)enabled reason:(NSString *)reason error:(NSError **)error {
	NSMutableDictionary *state = [[self currentState] mutableCopy];
	state[@"Enabled"] = @(enabled);
	state[@"Reason"] = reason ?: @"unspecified";
	state[@"UpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);

	if (enabled) {
		state[@"DesiredWidth"] = state[@"DesiredWidth"] ?: @1280;
		state[@"DesiredHeight"] = state[@"DesiredHeight"] ?: @720;
		state[@"DesiredFPS"] = state[@"DesiredFPS"] ?: @15;
		state[@"DesiredBitrate"] = state[@"DesiredBitrate"] ?: @1500000;
		state[@"RTSPPort"] = state[@"RTSPPort"] ?: @8554;
		state[@"HTTPPort"] = state[@"HTTPPort"] ?: @8080;
		state[@"PowerProfile"] = state[@"PowerProfile"] ?: @"balanced";
		state[@"ServicePolicy"] = state[@"ServicePolicy"] ?: @"camera-network-safe";
		state[@"KeepAliveMode"] = state[@"KeepAliveMode"] ?: @"silent-audio";
	}

	BOOL ok = [self writeState:state error:error];
	if (ok) {
		[self postChangedNotification];
	}
	return ok;
}

+ (BOOL)writeState:(NSDictionary *)state error:(NSError **)error {
	NSString *parent = [BSCModePreferencePath stringByDeletingLastPathComponent];
	if (![[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) {
		return NO;
	}

	NSDictionary *attributes = @{NSFilePosixPermissions: @0644};
	BOOL ok = [state writeToFile:BSCModePreferencePath atomically:YES];
	if (ok) {
		[[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:BSCModePreferencePath error:nil];
	} else if (error) {
		*error = [NSError errorWithDomain:@"BSCModeState" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write camera mode preference file"}];
	}
	return ok;
}

+ (void)postChangedNotification {
	notify_post(BSCModeChangedNotification);
}

@end
