#import "BSCModeController.h"
#import "BSCBonjourPublisher.h"
#import "BSCVideoEncoder.h"
#import "BSCRTSPServer.h"
#import "BSCHTTPServer.h"
#import "../shared/BSCModeState.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <UIKit/UIKit.h>

@interface BSCModeController () <BSCVideoEncoderDelegate>
@property (nonatomic, strong) BSCVideoEncoder *encoder;
@property (nonatomic, strong) BSCRTSPServer *rtspServer;
@property (nonatomic, strong) BSCHTTPServer *httpServer;
@property (nonatomic, strong) BSCBonjourPublisher *bonjourPublisher;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSDate *lastNetworkChangeAt;
@property (nonatomic, copy) NSString *lastAdvertisedHost;
@property (nonatomic, assign) NSInteger rtspPort;
@property (nonatomic, assign) NSInteger httpPort;
@property (nonatomic, assign) NSInteger desiredWidth;
@property (nonatomic, assign) NSInteger desiredHeight;
@property (nonatomic, assign) NSInteger desiredFPS;
@property (nonatomic, assign) NSInteger desiredBitrate;
@property (nonatomic, assign) NSUInteger encodedFrames;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, assign) BOOL thermalPaused;
@property (nonatomic, strong) NSDate *lastThermalPauseAt;
@property (nonatomic, strong) dispatch_source_t networkMonitorTimer;
@property (nonatomic, strong) dispatch_source_t encoderWatchdogTimer;
@property (nonatomic, assign) NSUInteger lastWatchdogEncodedFrames;
@property (nonatomic, strong) NSDate *lastEncodedFrameAt;
@property (nonatomic, strong) NSDate *lastEncoderRestartAt;
@property (nonatomic, assign) NSUInteger encoderRestartCount;
@end

@implementation BSCModeController

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

- (BOOL)start:(NSError **)error {
	NSDictionary *state = [BSCModeState currentState];
	NSInteger width = [state[@"DesiredWidth"] integerValue] ?: 1280;
	NSInteger height = [state[@"DesiredHeight"] integerValue] ?: 720;
	NSInteger fps = [state[@"DesiredFPS"] integerValue] ?: 15;
	NSInteger bitrate = [state[@"DesiredBitrate"] integerValue] ?: 1500000;
	NSInteger rtspPort = [state[@"RTSPPort"] integerValue] ?: 8554;
	NSInteger httpPort = [state[@"HTTPPort"] integerValue] ?: 8080;
	self.desiredWidth = width;
	self.desiredHeight = height;
	self.desiredFPS = fps;
	self.desiredBitrate = bitrate;
	self.rtspPort = rtspPort;
	self.httpPort = httpPort;

	self.startedAt = [NSDate date];
	self.rtspServer = [[BSCRTSPServer alloc] initWithPort:(uint16_t)rtspPort fps:(int)fps];
	if (![self.rtspServer start:error]) {
		return NO;
	}

	__weak typeof(self) weakSelf = self;
	self.httpServer = [[BSCHTTPServer alloc] initWithPort:(uint16_t)httpPort statusProvider:^NSDictionary *{
		return [weakSelf statusSnapshot] ?: @{};
	} snapshotProvider:^NSData *{
		return [weakSelf.encoder latestJPEGSnapshot] ?: [NSData data];
	}];
	if (![self.httpServer start:error]) {
		return NO;
	}

	if (![self startEncoder:error]) {
		[self.httpServer stop];
		[self.rtspServer stop];
		return NO;
	}

	self.bonjourPublisher = [BSCBonjourPublisher new];
	[self.bonjourPublisher startWithHTTPPort:(uint16_t)httpPort rtspPort:(uint16_t)rtspPort];
	self.lastAdvertisedHost = BSCLocalWiFiAddress();
	[self startNetworkMonitor];
	[self startEncoderWatchdog];

	NSLog(@"[SecurityCam] camera mode active rtsp=%ld http=%ld %ldx%ld@%ld bitrate=%ld",
		  (long)rtspPort, (long)httpPort, (long)width, (long)height, (long)fps, (long)bitrate);
	return YES;
}

- (BOOL)startEncoder:(NSError **)error {
	self.encoder = [[BSCVideoEncoder alloc] initWithWidth:(int)self.desiredWidth
													height:(int)self.desiredHeight
													   fps:(int)self.desiredFPS
												   bitrate:(int)self.desiredBitrate];
	self.encoder.delegate = self;
	BOOL ok = [self.encoder start:error];
	if (ok) {
		self.thermalPaused = NO;
		self.lastEncodedFrameAt = [NSDate date];
		self.lastWatchdogEncodedFrames = self.encodedFrames;
	}
	return ok;
}

- (void)stop {
	if (self.encoderWatchdogTimer) {
		dispatch_source_cancel(self.encoderWatchdogTimer);
		self.encoderWatchdogTimer = nil;
	}
	if (self.networkMonitorTimer) {
		dispatch_source_cancel(self.networkMonitorTimer);
		self.networkMonitorTimer = nil;
	}
	[self.bonjourPublisher stop];
	[self.encoder stop];
	[self.httpServer stop];
	[self.rtspServer stop];
}

- (void)startNetworkMonitor {
	if (self.networkMonitorTimer) {
		return;
	}

	dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
	self.networkMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(self.networkMonitorTimer,
							  dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
							  10 * NSEC_PER_SEC,
							  2 * NSEC_PER_SEC);
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(self.networkMonitorTimer, ^{
		[weakSelf refreshNetworkAdvertisementIfNeeded];
	});
	dispatch_resume(self.networkMonitorTimer);
}

- (void)startEncoderWatchdog {
	if (self.encoderWatchdogTimer) {
		return;
	}

	dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
	self.encoderWatchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(self.encoderWatchdogTimer,
							  dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
							  20 * NSEC_PER_SEC,
							  3 * NSEC_PER_SEC);
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(self.encoderWatchdogTimer, ^{
		[weakSelf checkEncoderProgress];
	});
	dispatch_resume(self.encoderWatchdogTimer);
}

- (void)checkEncoderProgress {
	if (self.thermalPaused || ![BSCModeState isEnabled]) {
		return;
	}

	NSUInteger currentFrames = self.encodedFrames;
	BOOL frameAdvanced = currentFrames > self.lastWatchdogEncodedFrames;
	self.lastWatchdogEncodedFrames = currentFrames;
	if (frameAdvanced) {
		return;
	}

	NSTimeInterval secondsSinceFrame = self.lastEncodedFrameAt ? [[NSDate date] timeIntervalSinceDate:self.lastEncodedFrameAt] : 999.0;
	if (secondsSinceFrame < 25.0) {
		return;
	}

	NSString *event = self.encoder.lastCaptureEvent ?: @"unknown";
	NSString *reason = [NSString stringWithFormat:@"frame watchdog: no encoded frames for %.0fs, captureRunning=%@, lastCaptureEvent=%@",
						secondsSinceFrame,
						[self.encoder isCaptureRunning] ? @"true" : @"false",
						event];
	[self restartEncoderForReason:reason];
}

- (void)restartEncoderForReason:(NSString *)reason {
	self.encoderRestartCount += 1;
	self.lastEncoderRestartAt = [NSDate date];
	self.lastError = reason;
	NSLog(@"[SecurityCam] %@", reason);

	[self.encoder stop];
	self.encoder = nil;

	NSError *error = nil;
	if (![self startEncoder:&error]) {
		self.lastError = [NSString stringWithFormat:@"%@; restart failed: %@", reason, error.localizedDescription ?: @"unknown"];
		NSLog(@"[SecurityCam] %@", self.lastError);
		return;
	}

	self.lastError = [NSString stringWithFormat:@"%@; encoder restarted", reason];
	NSLog(@"[SecurityCam] %@", self.lastError);
}

- (void)refreshNetworkAdvertisementIfNeeded {
	NSString *host = BSCLocalWiFiAddress();
	if (!host.length || [host isEqualToString:@"0.0.0.0"]) {
		return;
	}
	if ([host isEqualToString:self.lastAdvertisedHost]) {
		[self enforceThermalGuardrails];
		return;
	}

	NSString *previous = self.lastAdvertisedHost ?: @"unknown";
	self.lastAdvertisedHost = host;
	self.lastNetworkChangeAt = [NSDate date];
	NSLog(@"[SecurityCam] network address changed %@ -> %@, refreshing Bonjour", previous, host);
	[self.bonjourPublisher startWithHTTPPort:(uint16_t)self.httpPort rtspPort:(uint16_t)self.rtspPort];
	[self enforceThermalGuardrails];
}

- (void)enforceThermalGuardrails {
	if (@available(iOS 11.0, *)) {
		NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
		if (state == NSProcessInfoThermalStateCritical && !self.thermalPaused) {
			self.thermalPaused = YES;
			self.lastThermalPauseAt = [NSDate date];
			self.lastError = @"thermal critical: encoder paused until device cools";
			NSLog(@"[SecurityCam] %@", self.lastError);
			[self.encoder stop];
			self.encoder = nil;
			return;
		}

		if (self.thermalPaused && (state == NSProcessInfoThermalStateNominal || state == NSProcessInfoThermalStateFair)) {
			[self restartEncoderForReason:@"thermal recovered"];
			return;
		}

		if (state == NSProcessInfoThermalStateSerious) {
			self.lastError = @"thermal serious: keep camera running, consider lowering fps or bitrate";
		}
	}
}

- (NSDictionary *)statusSnapshot {
	NSMutableDictionary *status = [NSMutableDictionary dictionary];
	NSDictionary *state = [BSCModeState currentState];
	[UIDevice currentDevice].batteryMonitoringEnabled = YES;
	status[@"enabled"] = @([BSCModeState isEnabled]);
	status[@"bundleIdentifier"] = BSCBundleIdentifier;
	status[@"uptimeSeconds"] = self.startedAt ? @([[NSDate date] timeIntervalSinceDate:self.startedAt]) : @0;
	status[@"encodedFrames"] = @(self.encodedFrames);
	status[@"captureRunning"] = @([self.encoder isCaptureRunning]);
	status[@"lastCaptureEvent"] = self.encoder.lastCaptureEvent ?: @"";
	status[@"thermalPaused"] = @(self.thermalPaused);
	status[@"lastThermalPauseAt"] = self.lastThermalPauseAt ? @([self.lastThermalPauseAt timeIntervalSince1970]) : @0;
	status[@"lastEncodedFrameAt"] = self.lastEncodedFrameAt ? @([self.lastEncodedFrameAt timeIntervalSince1970]) : @0;
	status[@"lastEncoderRestartAt"] = self.lastEncoderRestartAt ? @([self.lastEncoderRestartAt timeIntervalSince1970]) : @0;
	status[@"encoderRestartCount"] = @(self.encoderRestartCount);
	status[@"frameWatchdog"] = @{
		@"lastSampledFrames": @(self.lastWatchdogEncodedFrames),
		@"enabled": @YES
	};
	status[@"motionDetected"] = @([self.encoder isMotionDetected]);
	status[@"motionScore"] = @(self.encoder.motionScore);
	status[@"lastMotionTime"] = @(self.encoder.lastMotionTime);
	NSString *host = BSCLocalWiFiAddress();
	status[@"host"] = host;
	status[@"rtspUrl"] = [NSString stringWithFormat:@"rtsp://%@:%@/live", host, state[@"RTSPPort"] ?: @8554];
	status[@"httpStatusUrl"] = [NSString stringWithFormat:@"http://%@:%@/status", host, state[@"HTTPPort"] ?: @8080];
	status[@"httpSnapshotUrl"] = [NSString stringWithFormat:@"http://%@:%@/snapshot.jpg", host, state[@"HTTPPort"] ?: @8080];
	status[@"bonjourServiceType"] = BSCBonjourServiceType;
	status[@"bonjourServiceName"] = self.bonjourPublisher.serviceName ?: @"";
	status[@"lastNetworkChangeAt"] = self.lastNetworkChangeAt ? @([self.lastNetworkChangeAt timeIntervalSince1970]) : @0;
	status[@"thermalState"] = [self thermalStateString];
	status[@"lowPowerMode"] = @([[NSProcessInfo processInfo] isLowPowerModeEnabled]);
	status[@"batteryMonitoringEnabled"] = @([UIDevice currentDevice].batteryMonitoringEnabled);
	status[@"batteryLevel"] = @([UIDevice currentDevice].batteryLevel);
	status[@"batteryState"] = @([UIDevice currentDevice].batteryState);
	status[@"screenBrightness"] = @([UIScreen mainScreen].brightness);
	status[@"powerProfile"] = state[@"PowerProfile"] ?: @"balanced";
	status[@"servicePolicy"] = state[@"ServicePolicy"] ?: @"camera-network-safe";
	status[@"keepAliveMode"] = state[@"KeepAliveMode"] ?: @"silent-audio";
	status[@"desired"] = @{
		@"width": state[@"DesiredWidth"] ?: @1280,
		@"height": state[@"DesiredHeight"] ?: @720,
		@"fps": state[@"DesiredFPS"] ?: @15,
		@"bitrate": state[@"DesiredBitrate"] ?: @1500000
	};
	if (self.lastError) {
		status[@"lastError"] = self.lastError;
	}
	return status;
}

- (NSString *)thermalStateString {
	if (@available(iOS 11.0, *)) {
		switch ([NSProcessInfo processInfo].thermalState) {
			case NSProcessInfoThermalStateNominal: return @"nominal";
			case NSProcessInfoThermalStateFair: return @"fair";
			case NSProcessInfoThermalStateSerious: return @"serious";
			case NSProcessInfoThermalStateCritical: return @"critical";
		}
	}
	return @"unknown";
}

- (void)videoEncoderDidUpdateSPS:(NSData *)sps pps:(NSData *)pps {
	[self.rtspServer updateSPS:sps pps:pps];
}

- (void)videoEncoderDidEncodeNALUnits:(NSArray<NSData *> *)nalUnits keyframe:(BOOL)keyframe pts:(CMTime)pts {
	self.encodedFrames += 1;
	self.lastEncodedFrameAt = [NSDate date];
	[self.rtspServer broadcastNALUnits:nalUnits keyframe:keyframe pts:pts];
}

@end
