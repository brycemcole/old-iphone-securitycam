#import <Foundation/Foundation.h>
#import "../shared/BSCModeState.h"
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <spawn.h>
#import <sys/wait.h>

static int BSCUsage(void);
static int BSCLaunchApp(void);
static int BSCLaunchAppWithSpringBoardServices(void);
static int BSCLockDevice(void);
static int BSCApplyProfile(NSString *profile, NSError **error);
static void BSCPrintServicePolicy(void);
static int BSCSpawnShell(NSString *command, BOOL waitForExit);
static BOOL BSCArgvContains(int argc, char *argv[], const char *needle);
static NSString *BSCLocalWiFiAddress(void);
extern char **environ;

int main(int argc, char *argv[]) {
	@autoreleasepool {
		if (argc < 2) {
			return BSCUsage();
		}

		NSString *command = [NSString stringWithUTF8String:argv[1]];
		NSError *error = nil;

		if ([command isEqualToString:@"on"]) {
			if (![BSCModeState setEnabled:YES reason:@"camera-mode on" error:&error]) {
				fprintf(stderr, "failed to enable camera mode: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			int launchResult = BSCLaunchApp();
			NSDictionary *state = [BSCModeState currentState];
			NSString *host = BSCLocalWiFiAddress();
			printf("camera mode enabled\n");
			printf("rtsp://%s:%ld/live\n", host.UTF8String, (long)([state[@"RTSPPort"] integerValue] ?: 8554));
			printf("http://%s:%ld/status\n", host.UTF8String, (long)([state[@"HTTPPort"] integerValue] ?: 8080));
			return launchResult;
		}

		if ([command isEqualToString:@"launch"]) {
			return BSCLaunchApp();
		}

		if ([command isEqualToString:@"lock"]) {
			return BSCLockDevice();
		}

		if ([command isEqualToString:@"optimize"]) {
			if (BSCApplyProfile(@"aggressive", &error) != 0) {
				fprintf(stderr, "failed to apply aggressive profile: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			printf("aggressive camera profile enabled\n");
			printf("restart camera mode to apply encoder changes\n");
			return 0;
		}

		if ([command isEqualToString:@"balanced"]) {
			if (BSCApplyProfile(@"balanced", &error) != 0) {
				fprintf(stderr, "failed to apply balanced profile: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			printf("balanced camera profile enabled\n");
			printf("restart camera mode to apply encoder changes\n");
			return 0;
		}

		if ([command isEqualToString:@"services"]) {
			BSCPrintServicePolicy();
			return 0;
		}

		if ([command isEqualToString:@"off"]) {
			if (![BSCModeState setEnabled:NO reason:@"camera-mode off" error:&error]) {
				fprintf(stderr, "failed to disable camera mode: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			BSCSpawnShell(@"killall SecurityCam >/dev/null 2>&1 || true", YES);
			printf("camera mode disabled\n");
			if (BSCArgvContains(argc, argv, "--respring")) {
				printf("respring requested\n");
				return BSCSpawnShell(@"sbreload >/dev/null 2>&1 || killall SpringBoard >/dev/null 2>&1", YES);
			}
			return 0;
		}

		if ([command isEqualToString:@"status"]) {
			NSDictionary *state = [BSCModeState currentState];
			NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
			NSString *text = json.length ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"{}";
			printf("%s\n", text.UTF8String);
			printf("process: ");
			fflush(stdout);
			BSCSpawnShell(@"ps ax | grep '[A]pplications/SecurityCam.app/SecurityCam' >/dev/null && echo running || echo stopped", YES);
			return 0;
		}

		if ([command isEqualToString:@"set"]) {
			if (argc < 4) {
				return BSCUsage();
			}
			NSMutableDictionary *state = [[BSCModeState currentState] mutableCopy];
			NSString *key = [NSString stringWithUTF8String:argv[2]];
			NSString *value = [NSString stringWithUTF8String:argv[3]];
			NSInteger integer = [value integerValue];
			state[key] = integer ? @(integer) : value;
			state[@"UpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);
			if (![BSCModeState writeState:state error:&error]) {
				fprintf(stderr, "failed to write state: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			[BSCModeState postChangedNotification];
			return 0;
		}

		return BSCUsage();
	}
}

static int BSCUsage(void) {
	fprintf(stderr,
			"usage:\n"
			"  camera-mode on\n"
			"  camera-mode off [--respring]\n"
			"  camera-mode launch\n"
			"  camera-mode lock\n"
			"  camera-mode optimize\n"
			"  camera-mode balanced\n"
			"  camera-mode services\n"
			"  camera-mode status\n"
			"  camera-mode set DesiredFPS 10\n"
			"  camera-mode set DesiredBitrate 1200000\n");
	return 64;
}

static int BSCApplyProfile(NSString *profile, NSError **error) {
	NSMutableDictionary *state = [[BSCModeState currentState] mutableCopy];
	if ([profile isEqualToString:@"aggressive"]) {
		state[@"DesiredWidth"] = @1280;
		state[@"DesiredHeight"] = @720;
		state[@"DesiredFPS"] = @10;
		state[@"DesiredBitrate"] = @1000000;
		state[@"PowerProfile"] = @"aggressive";
		state[@"ServicePolicy"] = @"camera-network-safe";
		state[@"KeepAliveMode"] = @"silent-audio";
		state[@"Reason"] = @"camera-mode optimize";
	} else {
		state[@"DesiredWidth"] = @1280;
		state[@"DesiredHeight"] = @720;
		state[@"DesiredFPS"] = @15;
		state[@"DesiredBitrate"] = @1500000;
		state[@"PowerProfile"] = @"balanced";
		state[@"ServicePolicy"] = @"camera-network-safe";
		state[@"KeepAliveMode"] = @"silent-audio";
		state[@"Reason"] = @"camera-mode balanced";
	}
	state[@"UpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);
	BOOL ok = [BSCModeState writeState:state error:error];
	if (ok) {
		[BSCModeState postChangedNotification];
	}
	return ok ? 0 : 1;
}

static void BSCPrintServicePolicy(void) {
	printf("disabled or inhibited by SecurityCam:\n");
	printf("- live preview rendering\n");
	printf("- audio capture and audio streaming\n");
	printf("- late video frame backlog\n");
	printf("- app background fetch\n");
	printf("- screen brightness while camera mode is active\n");
	printf("\nleft alive intentionally:\n");
	printf("- camera and mediaserver services\n");
	printf("- Wi-Fi, mDNS/Bonjour, and local networking\n");
	printf("- SpringBoard/backboardd for lock state and button escape\n");
	printf("- power management and thermal management\n");
	printf("- Scrypted/HomeKit on the server side\n");
	printf("\nThis release does not unload random Apple daemons because that is device- and jailbreak-specific and can break camera, Wi-Fi, or HomeKit discovery.\n");
}

static int BSCLaunchApp(void) {
	int result = BSCLaunchAppWithSpringBoardServices();
	if (result == 0) {
		return 0;
	}
	return BSCSpawnShell([NSString stringWithFormat:@"uiopen %@ >/dev/null 2>&1", BSCBundleIdentifier], YES);
}

static int BSCLaunchAppWithSpringBoardServices(void) {
	void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
	if (!handle) {
		return 1;
	}

	typedef int (*LaunchFunction)(NSString *bundleIdentifier, NSDictionary *appOptions, NSDictionary *launchOptions, BOOL suspended);
	LaunchFunction launch = (LaunchFunction)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
	if (!launch) {
		dlclose(handle);
		return 1;
	}

	NSMutableDictionary *appOptions = [NSMutableDictionary dictionary];
	appOptions[@"SBSApplicationLaunchOptionUnlockDeviceKey"] = @YES;

	int result = launch(BSCBundleIdentifier, appOptions, nil, NO);
	dlclose(handle);
	return result == 0 ? 0 : 1;
}

static int BSCLockDevice(void) {
	void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
	if (!handle) {
		fprintf(stderr, "SpringBoardServices unavailable: %s\n", dlerror());
		return 1;
	}

	typedef void (*LockFunction)(void);
	const char *symbols[] = {
		"SBSLockDevice",
		"SBSLockDeviceAndDimScreen",
		NULL
	};
	for (int i = 0; symbols[i]; i++) {
		LockFunction lock = (LockFunction)dlsym(handle, symbols[i]);
		if (lock) {
			lock();
			printf("lock requested with %s\n", symbols[i]);
			dlclose(handle);
			return 0;
		}
	}

	fprintf(stderr, "no supported lock symbol found\n");
	dlclose(handle);
	return 1;
}

static int BSCSpawnShell(NSString *command, BOOL waitForExit) {
	pid_t pid = 0;
	char *argv[] = {
		(char *)"/bin/sh",
		(char *)"-c",
		(char *)command.UTF8String,
		NULL
	};
	int spawnResult = posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
	if (spawnResult != 0) {
		return 1;
	}
	if (!waitForExit) {
		return 0;
	}
	int result = 0;
	if (waitpid(pid, &result, 0) < 0) {
		return 1;
	}
	if (!WIFEXITED(result)) {
		return 1;
	}
	return WEXITSTATUS(result);
}

static BOOL BSCArgvContains(int argc, char *argv[], const char *needle) {
	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], needle) == 0) {
			return YES;
		}
	}
	return NO;
}

static NSString *BSCLocalWiFiAddress(void) {
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) {
		return @"0.0.0.0";
	}

	NSString *address = @"0.0.0.0";
	for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
		if (!interface->ifa_addr || interface->ifa_addr->sa_family != AF_INET) {
			continue;
		}
		if (strcmp(interface->ifa_name, "en0") != 0) {
			continue;
		}
		char buffer[INET_ADDRSTRLEN] = {0};
		struct sockaddr_in *socketAddress = (struct sockaddr_in *)interface->ifa_addr;
		if (inet_ntop(AF_INET, &socketAddress->sin_addr, buffer, sizeof(buffer))) {
			address = [NSString stringWithUTF8String:buffer];
			break;
		}
	}
	freeifaddrs(interfaces);
	return address;
}
