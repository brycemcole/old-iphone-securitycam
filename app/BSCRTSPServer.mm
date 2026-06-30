#import "BSCRTSPServer.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

@interface BSCRTSPClient : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) uint16_t sequence;
@property (nonatomic, assign) uint32_t ssrc;
@property (nonatomic, copy) NSString *session;
@end

@implementation BSCRTSPClient
@end

@interface BSCRTSPServer ()
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableArray<BSCRTSPClient *> *clients;
@property (nonatomic, strong) NSData *sps;
@property (nonatomic, strong) NSData *pps;
@property (nonatomic, assign) uint32_t fallbackTimestamp;
@end

@implementation BSCRTSPServer

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

static void BSCConfigureClientSocket(int fd) {
	int yes = 1;
#ifdef SO_NOSIGPIPE
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
	struct timeval timeout;
	timeout.tv_sec = 2;
	timeout.tv_usec = 0;
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

- (instancetype)initWithPort:(uint16_t)port fps:(int)fps {
	self = [super init];
	if (self) {
		_port = port;
		_fps = MAX(1, fps);
		_listenFD = -1;
		_clients = [NSMutableArray array];
	}
	return self;
}

- (BOOL)start:(NSError **)error {
	signal(SIGPIPE, SIG_IGN);
	self.listenFD = socket(AF_INET, SOCK_STREAM, 0);
	if (self.listenFD < 0) {
		return [self fail:error message:@"RTSP socket() failed"];
	}

	int yes = 1;
	setsockopt(self.listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	BSCConfigureClientSocket(self.listenFD);

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons(self.port);

	if (bind(self.listenFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		return [self fail:error message:@"RTSP bind() failed"];
	}
	if (listen(self.listenFD, 4) < 0) {
		return [self fail:error message:@"RTSP listen() failed"];
	}

	self.running = YES;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[self acceptLoop];
	});
	return YES;
}

- (BOOL)fail:(NSError **)error message:(NSString *)message {
	if (error) {
		*error = [NSError errorWithDomain:@"BSCRTSPServer" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
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
	@synchronized (self.clients) {
		for (BSCRTSPClient *client in self.clients) {
			if (client.fd >= 0) {
				close(client.fd);
				client.fd = -1;
			}
		}
		[self.clients removeAllObjects];
	}
}

- (void)acceptLoop {
	while (self.running) {
		int fd = accept(self.listenFD, NULL, NULL);
		if (fd < 0) {
			continue;
		}
		BSCConfigureClientSocket(fd);
		BSCRTSPClient *client = [BSCRTSPClient new];
		client.fd = fd;
		client.session = [NSString stringWithFormat:@"%u", arc4random()];
		client.sequence = (uint16_t)(arc4random() & 0xffff);
		client.ssrc = arc4random();
		@synchronized (self.clients) {
			[self.clients addObject:client];
		}
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			[self handleClient:client];
		});
	}
}

- (void)handleClient:(BSCRTSPClient *)client {
	@autoreleasepool {
		NSMutableData *buffer = [NSMutableData data];
		while (self.running && client.fd >= 0) {
			char chunk[2048];
			ssize_t count = recv(client.fd, chunk, sizeof(chunk), 0);
			if (count <= 0) {
				break;
			}
			[buffer appendBytes:chunk length:(NSUInteger)count];
			NSString *raw = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
			NSRange end = [raw rangeOfString:@"\r\n\r\n"];
			if (!raw || end.location == NSNotFound) {
				continue;
			}
			NSString *request = [raw substringToIndex:end.location + 4];
			[buffer replaceBytesInRange:NSMakeRange(0, end.location + 4) withBytes:NULL length:0];
			if (![self handleRequest:request client:client]) {
				break;
			}
		}
		client.playing = NO;
		if (client.fd >= 0) {
			close(client.fd);
			client.fd = -1;
		}
		@synchronized (self.clients) {
			[self.clients removeObject:client];
		}
	}
}

- (BOOL)handleRequest:(NSString *)request client:(BSCRTSPClient *)client {
	NSArray<NSString *> *lines = [request componentsSeparatedByString:@"\r\n"];
	NSString *first = lines.firstObject ?: @"";
	NSString *method = [[first componentsSeparatedByString:@" "] firstObject] ?: @"";
	NSString *cseq = [self header:@"CSeq" lines:lines] ?: @"1";

	if ([method isEqualToString:@"OPTIONS"]) {
		return [self writeString:[NSString stringWithFormat:@"RTSP/1.0 200 OK\r\nCSeq: %@\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n", cseq] fd:client.fd];
	}
	if ([method isEqualToString:@"DESCRIBE"]) {
		NSString *sdp = [self sdp];
		NSString *response = [NSString stringWithFormat:
							  @"RTSP/1.0 200 OK\r\nCSeq: %@\r\nContent-Type: application/sdp\r\nContent-Length: %lu\r\n\r\n%@",
							  cseq, (unsigned long)[sdp dataUsingEncoding:NSUTF8StringEncoding].length, sdp];
		return [self writeString:response fd:client.fd];
	}
	if ([method isEqualToString:@"SETUP"]) {
		NSString *response = [NSString stringWithFormat:
							  @"RTSP/1.0 200 OK\r\nCSeq: %@\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=%08x\r\nSession: %@\r\n\r\n",
							  cseq, client.ssrc, client.session];
		return [self writeString:response fd:client.fd];
	}
	if ([method isEqualToString:@"PLAY"]) {
		client.playing = YES;
		NSString *response = [NSString stringWithFormat:@"RTSP/1.0 200 OK\r\nCSeq: %@\r\nSession: %@\r\nRTP-Info: url=rtsp://%@:%u/live/trackID=0\r\n\r\n", cseq, client.session, BSCLocalWiFiAddress(), self.port];
		return [self writeString:response fd:client.fd];
	}
	if ([method isEqualToString:@"TEARDOWN"]) {
		[self writeString:[NSString stringWithFormat:@"RTSP/1.0 200 OK\r\nCSeq: %@\r\nSession: %@\r\n\r\n", cseq, client.session] fd:client.fd];
		return NO;
	}

	return [self writeString:[NSString stringWithFormat:@"RTSP/1.0 405 Method Not Allowed\r\nCSeq: %@\r\n\r\n", cseq] fd:client.fd];
}

- (NSString *)header:(NSString *)name lines:(NSArray<NSString *> *)lines {
	NSString *prefix = [[name stringByAppendingString:@":"] lowercaseString];
	for (NSString *line in lines) {
		if ([[line lowercaseString] hasPrefix:prefix]) {
			return [[line substringFromIndex:name.length + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		}
	}
	return nil;
}

- (NSString *)sdp {
	NSString *fmtp = @"a=fmtp:96 packetization-mode=1;profile-level-id=42e01f\r\n";
	if (self.sps.length && self.pps.length) {
		fmtp = [NSString stringWithFormat:@"a=fmtp:96 packetization-mode=1;profile-level-id=42e01f;sprop-parameter-sets=%@,%@\r\n",
				[self.sps base64EncodedStringWithOptions:0],
				[self.pps base64EncodedStringWithOptions:0]];
	}
	return [NSString stringWithFormat:
			@"v=0\r\n"
			"o=- 0 0 IN IP4 0.0.0.0\r\n"
			"s=Old iPhone SecurityCam\r\n"
			"t=0 0\r\n"
			"a=control:*\r\n"
			"m=video 0 RTP/AVP/TCP 96\r\n"
			"a=rtpmap:96 H264/90000\r\n"
			"%@"
			"a=control:trackID=0\r\n", fmtp];
}

- (BOOL)writeString:(NSString *)string fd:(int)fd {
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

- (void)updateSPS:(NSData *)sps pps:(NSData *)pps {
	@synchronized (self) {
		self.sps = sps;
		self.pps = pps;
	}
}

- (void)broadcastNALUnits:(NSArray<NSData *> *)nalUnits keyframe:(BOOL)keyframe pts:(CMTime)pts {
	NSMutableArray<NSData *> *units = [NSMutableArray array];
	@synchronized (self) {
		if (keyframe && self.sps.length && self.pps.length) {
			[units addObject:self.sps];
			[units addObject:self.pps];
		}
	}
	[units addObjectsFromArray:nalUnits];
	if (!units.count) {
		return;
	}

	uint32_t timestamp = 0;
	if (CMTIME_IS_NUMERIC(pts)) {
		timestamp = (uint32_t)(CMTimeGetSeconds(pts) * 90000.0);
	}
	if (timestamp == 0) {
		self.fallbackTimestamp += (uint32_t)(90000 / MAX(1, self.fps));
		timestamp = self.fallbackTimestamp;
	}

	NSArray<BSCRTSPClient *> *clients = nil;
	@synchronized (self.clients) {
		clients = [self.clients copy];
	}
	for (BSCRTSPClient *client in clients) {
		if (!client.playing || client.fd < 0) {
			continue;
		}
		for (NSUInteger i = 0; i < units.count; i++) {
			BOOL marker = (i == units.count - 1);
			[self sendNALUnit:units[i] timestamp:timestamp marker:marker client:client];
		}
	}
}

- (void)sendNALUnit:(NSData *)nalu timestamp:(uint32_t)timestamp marker:(BOOL)marker client:(BSCRTSPClient *)client {
	const uint8_t *bytes = (const uint8_t *)nalu.bytes;
	NSUInteger length = nalu.length;
	if (length <= 0) {
		return;
	}

	const NSUInteger maxPayload = 1200;
	if (length <= maxPayload) {
		[self sendRTPPayload:bytes length:length timestamp:timestamp marker:marker client:client];
		return;
	}

	uint8_t nalHeader = bytes[0];
	uint8_t fuIndicator = (nalHeader & 0xe0) | 28;
	uint8_t nalType = nalHeader & 0x1f;
	NSUInteger offset = 1;
	while (offset < length) {
		NSUInteger chunk = MIN(maxPayload - 2, length - offset);
		BOOL start = (offset == 1);
		BOOL end = (offset + chunk >= length);
		uint8_t header[2] = {
			fuIndicator,
			(uint8_t)((start ? 0x80 : 0x00) | (end ? 0x40 : 0x00) | nalType)
		};
		NSMutableData *payload = [NSMutableData dataWithBytes:header length:2];
		[payload appendBytes:bytes + offset length:chunk];
		[self sendRTPPayload:(const uint8_t *)payload.bytes length:payload.length timestamp:timestamp marker:(marker && end) client:client];
		offset += chunk;
	}
}

- (void)sendRTPPayload:(const uint8_t *)payload length:(NSUInteger)payloadLength timestamp:(uint32_t)timestamp marker:(BOOL)marker client:(BSCRTSPClient *)client {
	uint8_t header[12];
	memset(header, 0, sizeof(header));
	header[0] = 0x80;
	header[1] = (uint8_t)(96 | (marker ? 0x80 : 0x00));
	uint16_t seq = htons(client.sequence++);
	uint32_t ts = htonl(timestamp);
	uint32_t ssrc = htonl(client.ssrc);
	memcpy(header + 2, &seq, sizeof(seq));
	memcpy(header + 4, &ts, sizeof(ts));
	memcpy(header + 8, &ssrc, sizeof(ssrc));

	uint16_t packetLength = (uint16_t)(sizeof(header) + payloadLength);
	uint8_t interleaved[4] = {'$', 0, (uint8_t)(packetLength >> 8), (uint8_t)(packetLength & 0xff)};
	NSMutableData *packet = [NSMutableData dataWithBytes:interleaved length:sizeof(interleaved)];
	[packet appendBytes:header length:sizeof(header)];
	[packet appendBytes:payload length:payloadLength];

	if (!BSCWriteAll(client.fd, packet.bytes, packet.length)) {
		client.playing = NO;
	}
}

- (void)dealloc {
	[self stop];
}

@end
