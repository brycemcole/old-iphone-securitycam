#import <UIKit/UIKit.h>
#import "../shared/BSCModeState.h"
#import <spawn.h>

extern char **environ;

static void BSCSpawnShellAsync(NSString *command) {
	pid_t pid = 0;
	char *argv[] = {
		(char *)"/bin/sh",
		(char *)"-c",
		(char *)command.UTF8String,
		NULL
	};
	posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
}

static NSMutableArray<NSDictionary *> *BSCButtonEvents(void) {
	static NSMutableArray<NSDictionary *> *events = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		events = [NSMutableArray array];
	});
	return events;
}

static BOOL BSCIsSecurityCamProcess(void) {
	return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:BSCBundleIdentifier];
}

static BOOL BSCShouldForceForegroundForCamera(void) {
	return BSCIsSecurityCamProcess() && [BSCModeState isEnabled];
}

static void BSCRecordButton(NSString *button) {
	if (![BSCModeState isEnabled]) {
		return;
	}

	NSDate *now = [NSDate date];
	NSMutableArray<NSDictionary *> *events = BSCButtonEvents();
	[events addObject:@{@"button": button, @"time": now}];

	NSTimeInterval window = 2.5;
	NSIndexSet *oldIndexes = [events indexesOfObjectsPassingTest:^BOOL(NSDictionary *event, __unused NSUInteger idx, __unused BOOL *stop) {
		return [now timeIntervalSinceDate:event[@"time"]] > window;
	}];
	[events removeObjectsAtIndexes:oldIndexes];

	if (events.count < 3) {
		return;
	}

	NSArray<NSString *> *tail = @[
		events[events.count - 3][@"button"],
		events[events.count - 2][@"button"],
		events[events.count - 1][@"button"]
	];
	BOOL upDownUp = [tail[0] isEqualToString:@"up"] && [tail[1] isEqualToString:@"down"] && [tail[2] isEqualToString:@"up"];
	BOOL downUpDown = [tail[0] isEqualToString:@"down"] && [tail[1] isEqualToString:@"up"] && [tail[2] isEqualToString:@"down"];
	if (!upDownUp && !downUpDown) {
		return;
	}

	[events removeAllObjects];
	NSLog(@"[SecurityCamEscape] hardware escape combo detected");
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BSCSpawnShellAsync(@"/usr/bin/camera-mode off --respring >/dev/null 2>&1");
	});
}

%hook SBVolumeControl

- (void)increaseVolume {
	BSCRecordButton(@"up");
	%orig;
}

- (void)decreaseVolume {
	BSCRecordButton(@"down");
	%orig;
}

%end

%hook UIApplication

- (UIApplicationState)applicationState {
	if (BSCShouldForceForegroundForCamera()) {
		return UIApplicationStateActive;
	}
	return %orig;
}

- (BOOL)isSuspended {
	if (BSCShouldForceForegroundForCamera()) {
		return NO;
	}
	return %orig;
}

%end

%hook FBSSceneSettings

- (BOOL)isBackgrounded {
	if (BSCShouldForceForegroundForCamera()) {
		return NO;
	}
	return %orig;
}

- (BOOL)isEffectivelyBackgrounded {
	if (BSCShouldForceForegroundForCamera()) {
		return NO;
	}
	return %orig;
}

%end

%ctor {
	NSLog(@"[SecurityCamEscape] loaded");
}
