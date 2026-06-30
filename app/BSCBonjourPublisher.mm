#import "BSCBonjourPublisher.h"
#import <unistd.h>

NSString * const BSCBonjourServiceType = @"_oldiphonecam._tcp.";

@interface BSCBonjourPublisher () <NSNetServiceDelegate>
@property (nonatomic, readwrite, copy) NSString *serviceName;
@property (nonatomic, strong) NSArray<NSNetService *> *services;
@property (nonatomic, assign) uint16_t httpPort;
@property (nonatomic, assign) uint16_t rtspPort;
@end

@implementation BSCBonjourPublisher

- (void)startWithHTTPPort:(uint16_t)httpPort rtspPort:(uint16_t)rtspPort {
	self.httpPort = httpPort;
	self.rtspPort = rtspPort;
	[self stop];

	NSString *name = [self defaultServiceName];
	self.serviceName = name;

	NSData *httpTXT = [NSNetService dataFromTXTRecordDictionary:@{
		@"id": [@"com.github.bryce.securitycam" dataUsingEncoding:NSUTF8StringEncoding],
		@"kind": [@"old-iphone-securitycam" dataUsingEncoding:NSUTF8StringEncoding],
		@"rtspPort": [[NSString stringWithFormat:@"%u", rtspPort] dataUsingEncoding:NSUTF8StringEncoding],
		@"rtspPath": [@"/live" dataUsingEncoding:NSUTF8StringEncoding],
		@"statusPath": [@"/status" dataUsingEncoding:NSUTF8StringEncoding],
		@"snapshotPath": [@"/snapshot.jpg" dataUsingEncoding:NSUTF8StringEncoding],
		@"mjpegPath": [@"/stream.mjpg" dataUsingEncoding:NSUTF8StringEncoding],
	}];
	NSData *rtspTXT = [NSNetService dataFromTXTRecordDictionary:@{
		@"id": [@"com.github.bryce.securitycam" dataUsingEncoding:NSUTF8StringEncoding],
		@"path": [@"/live" dataUsingEncoding:NSUTF8StringEncoding],
		@"httpPort": [[NSString stringWithFormat:@"%u", httpPort] dataUsingEncoding:NSUTF8StringEncoding],
	}];

	NSNetService *camera = [[NSNetService alloc] initWithDomain:@"local."
														   type:BSCBonjourServiceType
														   name:name
														   port:(int)httpPort];
	NSNetService *http = [[NSNetService alloc] initWithDomain:@"local."
														 type:@"_http._tcp."
														 name:name
														 port:(int)httpPort];
	NSNetService *rtsp = [[NSNetService alloc] initWithDomain:@"local."
														 type:@"_rtsp._tcp."
														 name:name
														 port:(int)rtspPort];
	for (NSNetService *service in @[camera, http, rtsp]) {
		service.delegate = self;
		if (service == rtsp) {
			[service setTXTRecordData:rtspTXT];
		} else {
			[service setTXTRecordData:httpTXT];
		}
		[service publish];
	}
	self.services = @[camera, http, rtsp];
}

- (void)stop {
	for (NSNetService *service in self.services) {
		service.delegate = nil;
		[service stop];
	}
	self.services = @[];
}

- (NSString *)defaultServiceName {
	char hostname[256] = {0};
	if (gethostname(hostname, sizeof(hostname) - 1) == 0 && hostname[0]) {
		NSString *host = [NSString stringWithUTF8String:hostname] ?: @"iPhone";
		return [NSString stringWithFormat:@"Old iPhone SecurityCam %@", host];
	}
	return @"Old iPhone SecurityCam";
}

- (void)netServiceDidPublish:(NSNetService *)sender {
	NSLog(@"[SecurityCam] Bonjour published %@ %@ port=%ld", sender.type, sender.name, (long)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
	NSLog(@"[SecurityCam] Bonjour publish failed %@ %@ error=%@", sender.type, sender.name, errorDict);
}

- (void)dealloc {
	[self stop];
}

@end
