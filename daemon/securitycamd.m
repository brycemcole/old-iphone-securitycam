#import <Foundation/Foundation.h>
#import "../shared/BSCModeState.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <spawn.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <unistd.h>

static void BSCEnsureLaunched(void);
static BOOL BSCProcessRunning(void);
static BOOL BSCStatusHealthy(NSInteger port);
static int BSCSpawnShell(NSString *command, BOOL waitForExit);
extern char **environ;

static NSUInteger BSCFailedHealthChecks = 0;
static NSDate *BSCLastLaunchAt = nil;

int main(__unused int argc, __unused char *argv[]) {
	@autoreleasepool {
		NSLog(@"[securitycamd] started");
		while (1) {
			@autoreleasepool {
				if ([BSCModeState isEnabled]) {
					BSCEnsureLaunched();
				}
			}
			sleep(8);
		}
	}
	return 0;
}

static void BSCEnsureLaunched(void) {
	if (BSCProcessRunning()) {
		NSDictionary *state = [BSCModeState currentState];
		NSInteger httpPort = [state[@"HTTPPort"] integerValue] ?: 8080;
		NSTimeInterval secondsSinceLaunch = BSCLastLaunchAt ? [[NSDate date] timeIntervalSinceDate:BSCLastLaunchAt] : 60.0;
		if (secondsSinceLaunch < 20.0) {
			return;
		}
		if (BSCStatusHealthy(httpPort)) {
			BSCFailedHealthChecks = 0;
			return;
		}
		BSCFailedHealthChecks += 1;
		NSLog(@"[securitycamd] status check failed %lu time(s)", (unsigned long)BSCFailedHealthChecks);
		if (BSCFailedHealthChecks < 3) {
			return;
		}
		NSLog(@"[securitycamd] restarting unhealthy SecurityCam");
		BSCSpawnShell(@"killall SecurityCam >/dev/null 2>&1 || true", YES);
		BSCFailedHealthChecks = 0;
		BSCLastLaunchAt = [NSDate date];
		BSCSpawnShell([NSString stringWithFormat:@"uiopen %@ >/dev/null 2>&1", BSCBundleIdentifier], YES);
		return;
	}
	NSLog(@"[securitycamd] launching SecurityCam");
	BSCFailedHealthChecks = 0;
	BSCLastLaunchAt = [NSDate date];
	BSCSpawnShell([NSString stringWithFormat:@"uiopen %@ >/dev/null 2>&1", BSCBundleIdentifier], YES);
}

static BOOL BSCProcessRunning(void) {
	return BSCSpawnShell(@"ps ax | grep '[A]pplications/SecurityCam.app/SecurityCam' >/dev/null 2>&1", YES) == 0;
}

static BOOL BSCStatusHealthy(NSInteger port) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		return NO;
	}

	struct timeval timeout;
	timeout.tv_sec = 2;
	timeout.tv_usec = 0;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		close(fd);
		return NO;
	}

	const char *request = "GET /status HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
	ssize_t sent = send(fd, request, strlen(request), 0);
	if (sent <= 0) {
		close(fd);
		return NO;
	}

	char buffer[4096] = {0};
	ssize_t received = recv(fd, buffer, sizeof(buffer) - 1, 0);
	close(fd);
	if (received <= 0) {
		return NO;
	}

	NSString *response = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)received encoding:NSUTF8StringEncoding];
	return [response containsString:@"200 OK"] && [response containsString:BSCBundleIdentifier];
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
