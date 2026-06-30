#import "BSCHTTPServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@interface BSCHTTPServer ()
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy) BSCStatusProvider statusProvider;
@property (nonatomic, copy) BSCSnapshotProvider snapshotProvider;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) BOOL running;
@end

@implementation BSCHTTPServer

- (instancetype)initWithPort:(uint16_t)port statusProvider:(BSCStatusProvider)statusProvider snapshotProvider:(BSCSnapshotProvider)snapshotProvider {
	self = [super init];
	if (self) {
		_port = port;
		_statusProvider = [statusProvider copy];
		_snapshotProvider = [snapshotProvider copy];
		_listenFD = -1;
	}
	return self;
}

- (BOOL)start:(NSError **)error {
	self.listenFD = socket(AF_INET, SOCK_STREAM, 0);
	if (self.listenFD < 0) {
		return [self fail:error message:@"HTTP socket() failed"];
	}

	int yes = 1;
	setsockopt(self.listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons(self.port);

	if (bind(self.listenFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		return [self fail:error message:@"HTTP bind() failed"];
	}
	if (listen(self.listenFD, 8) < 0) {
		return [self fail:error message:@"HTTP listen() failed"];
	}

	self.running = YES;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[self acceptLoop];
	});
	return YES;
}

- (BOOL)fail:(NSError **)error message:(NSString *)message {
	if (error) {
		*error = [NSError errorWithDomain:@"BSCHTTPServer" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
	}
	[self stop];
	return NO;
}

- (void)stop {
	self.running = NO;
	if (self.listenFD >= 0) {
		close(self.listenFD);
		self.listenFD = -1;
	}
}

- (void)acceptLoop {
	while (self.running) {
		int fd = accept(self.listenFD, NULL, NULL);
		if (fd < 0) {
			continue;
		}
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			[self handleClient:fd];
		});
	}
}

- (void)handleClient:(int)fd {
	@autoreleasepool {
		char buffer[2048];
		ssize_t count = recv(fd, buffer, sizeof(buffer) - 1, 0);
		if (count <= 0) {
			close(fd);
			return;
		}
		buffer[count] = '\0';
		NSString *request = [NSString stringWithUTF8String:buffer] ?: @"";
		NSString *line = [[request componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
		NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
		NSString *path = parts.count > 1 ? parts[1] : @"/";

		if ([path hasPrefix:@"/status"]) {
			[self serveStatus:fd];
		} else if ([path hasPrefix:@"/snapshot.jpg"]) {
			[self serveSnapshot:fd];
		} else if ([path hasPrefix:@"/stream.mjpg"]) {
			[self serveMJPEG:fd];
		} else {
			[self serveIndex:fd];
		}
		close(fd);
	}
}

- (void)serveIndex:(int)fd {
	NSDictionary *status = self.statusProvider ? self.statusProvider() : @{};
	NSString *rtspURL = status[@"rtspUrl"] ?: @"rtsp://0.0.0.0:8554/live";
	NSString *body = [NSString stringWithFormat:@"SecurityCam\n\n/status\n/snapshot.jpg\n/stream.mjpg\n%@\n", rtspURL];
	NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)[body dataUsingEncoding:NSUTF8StringEncoding].length];
	BSCWriteString(fd, header);
	BSCWriteString(fd, body);
}

- (void)serveStatus:(int)fd {
	NSDictionary *status = self.statusProvider ? self.statusProvider() : @{};
	NSData *body = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil] ?: [NSData data];
	NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
	BSCWriteString(fd, header);
	BSCWriteAll(fd, body.bytes, body.length);
}

- (void)serveSnapshot:(int)fd {
	NSData *jpeg = self.snapshotProvider ? self.snapshotProvider() : nil;
	if (!jpeg.length) {
		NSString *body = @"snapshot not ready\n";
		NSString *header = [NSString stringWithFormat:@"HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)[body dataUsingEncoding:NSUTF8StringEncoding].length];
		BSCWriteString(fd, header);
		BSCWriteString(fd, body);
		return;
	}

	NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", (unsigned long)jpeg.length];
	BSCWriteString(fd, header);
	BSCWriteAll(fd, jpeg.bytes, jpeg.length);
}

- (void)serveMJPEG:(int)fd {
	BSCWriteString(fd, @"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=securitycam\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
	while (self.running) {
		NSData *jpeg = self.snapshotProvider ? self.snapshotProvider() : nil;
		if (jpeg.length) {
			NSString *part = [NSString stringWithFormat:@"--securitycam\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n", (unsigned long)jpeg.length];
			if (!BSCWriteString(fd, part) || !BSCWriteAll(fd, jpeg.bytes, jpeg.length) || !BSCWriteString(fd, @"\r\n")) {
				break;
			}
		}
		usleep(500000);
	}
}

static BOOL BSCWriteString(int fd, NSString *string) {
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	return BSCWriteAll(fd, data.bytes, data.length);
}

static BOOL BSCWriteAll(int fd, const void *bytes, size_t length) {
	const uint8_t *cursor = (const uint8_t *)bytes;
	size_t remaining = length;
	while (remaining > 0) {
		ssize_t wrote = send(fd, cursor, remaining, 0);
		if (wrote <= 0) {
			return NO;
		}
		cursor += wrote;
		remaining -= (size_t)wrote;
	}
	return YES;
}

- (void)dealloc {
	[self stop];
}

@end
