#import "BSCVideoEncoder.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

@interface BSCVideoEncoder () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) CVPixelBufferRef latestPixelBuffer;
@property (nonatomic, strong) NSData *lastSPS;
@property (nonatomic, strong) NSData *lastPPS;
@property (nonatomic, strong) NSData *previousMotionSignature;
@property (nonatomic, assign, readwrite) float motionScore;
@property (nonatomic, assign, readwrite, getter=isMotionDetected) BOOL motionDetected;
@property (nonatomic, assign, readwrite) NSTimeInterval lastMotionTime;
@property (nonatomic, assign, readwrite, getter=isCaptureRunning) BOOL captureRunning;
@property (nonatomic, readwrite, copy) NSString *lastCaptureEvent;
@property (nonatomic, assign) CFAbsoluteTime lastMotionSampleTime;
@end

@implementation BSCVideoEncoder

- (instancetype)initWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate {
	self = [super init];
	if (self) {
		_width = width;
		_height = height;
		_fps = fps;
		_bitrate = bitrate;
		_captureQueue = dispatch_queue_create("com.github.bryce.securitycam.capture", DISPATCH_QUEUE_SERIAL);
		_ciContext = [CIContext contextWithOptions:nil];
	}
	return self;
}

- (BOOL)start:(NSError **)error {
	AVAuthorizationStatus auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
	if (auth == AVAuthorizationStatusNotDetermined) {
		dispatch_semaphore_t sema = dispatch_semaphore_create(0);
		[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(__unused BOOL granted) {
			dispatch_semaphore_signal(sema);
		}];
		dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
		auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
	}
	if (auth != AVAuthorizationStatusAuthorized) {
		if (error) {
			*error = [NSError errorWithDomain:@"BSCVideoEncoder" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Camera permission is not authorized"}];
		}
		return NO;
	}

	AVCaptureDevice *camera = [self rearCamera];
	if (!camera) {
		if (error) {
			*error = [NSError errorWithDomain:@"BSCVideoEncoder" code:11 userInfo:@{NSLocalizedDescriptionKey: @"No rear camera was found"}];
		}
		return NO;
	}

	self.captureSession = [AVCaptureSession new];
	self.captureSession.sessionPreset = self.width >= 1920 ? AVCaptureSessionPreset1920x1080 : AVCaptureSessionPreset1280x720;
	[self installCaptureObservers];

	AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:error];
	if (!input || ![self.captureSession canAddInput:input]) {
		return NO;
	}
	[self.captureSession addInput:input];

	NSError *lockError = nil;
	if ([camera lockForConfiguration:&lockError]) {
		CMTime frameDuration = CMTimeMake(1, MAX(1, self.fps));
		camera.activeVideoMinFrameDuration = frameDuration;
		camera.activeVideoMaxFrameDuration = frameDuration;
		if ([camera isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
			camera.focusMode = AVCaptureFocusModeContinuousAutoFocus;
		}
		if ([camera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
			camera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
		}
		[camera unlockForConfiguration];
	}

	AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
	output.alwaysDiscardsLateVideoFrames = YES;
	output.videoSettings = @{
		(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
	};
	[output setSampleBufferDelegate:self queue:self.captureQueue];
	if (![self.captureSession canAddOutput:output]) {
		if (error) {
			*error = [NSError errorWithDomain:@"BSCVideoEncoder" code:12 userInfo:@{NSLocalizedDescriptionKey: @"Unable to add video data output"}];
		}
		return NO;
	}
	[self.captureSession addOutput:output];

	dispatch_async(self.captureQueue, ^{
		[self.captureSession startRunning];
		self.captureRunning = self.captureSession.isRunning;
		self.lastCaptureEvent = self.captureRunning ? @"capture started" : @"capture start requested";
	});
	return YES;
}

- (void)stop {
	dispatch_sync(self.captureQueue, ^{
		[self.captureSession stopRunning];
		self.captureRunning = NO;
		self.lastCaptureEvent = @"capture stopped";
		if (self.compressionSession) {
			VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
			VTCompressionSessionInvalidate(self.compressionSession);
			CFRelease(self.compressionSession);
			self.compressionSession = NULL;
		}
		@synchronized (self) {
			if (self.latestPixelBuffer) {
				CVPixelBufferRelease(self.latestPixelBuffer);
				self.latestPixelBuffer = NULL;
			}
		}
	});
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (AVCaptureDevice *)rearCamera {
	AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
																									 mediaType:AVMediaTypeVideo
																									  position:AVCaptureDevicePositionBack];
	return session.devices.firstObject;
}

- (void)installCaptureObservers {
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(captureSessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.captureSession];
	[center addObserver:self selector:@selector(captureSessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.captureSession];
	[center addObserver:self selector:@selector(captureSessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.captureSession];
}

- (void)captureSessionWasInterrupted:(NSNotification *)notification {
	self.captureRunning = NO;
	NSNumber *reason = notification.userInfo[AVCaptureSessionInterruptionReasonKey];
	self.lastCaptureEvent = [NSString stringWithFormat:@"capture interrupted reason=%@", reason ?: @"unknown"];
	NSLog(@"[SecurityCam] %@", self.lastCaptureEvent);
}

- (void)captureSessionInterruptionEnded:(__unused NSNotification *)notification {
	self.lastCaptureEvent = @"capture interruption ended";
	NSLog(@"[SecurityCam] capture interruption ended");
	[self restartCaptureSessionSoon];
}

- (void)captureSessionRuntimeError:(NSNotification *)notification {
	NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
	self.captureRunning = NO;
	self.lastCaptureEvent = [NSString stringWithFormat:@"capture runtime error %@", error.localizedDescription ?: @"unknown"];
	NSLog(@"[SecurityCam] %@", self.lastCaptureEvent);
	[self restartCaptureSessionSoon];
}

- (void)restartCaptureSessionSoon {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), self.captureQueue, ^{
		if (!self.captureSession || self.captureSession.isRunning) {
			self.captureRunning = self.captureSession.isRunning;
			return;
		}
		[self.captureSession startRunning];
		self.captureRunning = self.captureSession.isRunning;
		self.lastCaptureEvent = self.captureRunning ? @"capture restarted" : @"capture restart requested";
	});
}

- (void)captureOutput:(__unused AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(__unused AVCaptureConnection *)connection {
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (!pixelBuffer) {
		return;
	}

	@synchronized (self) {
		if (self.latestPixelBuffer) {
			CVPixelBufferRelease(self.latestPixelBuffer);
		}
		self.latestPixelBuffer = CVPixelBufferRetain(pixelBuffer);
	}

	[self updateMotionForPixelBuffer:pixelBuffer];

	if (!self.compressionSession) {
		[self createCompressionSessionForPixelBuffer:pixelBuffer];
	}
	if (!self.compressionSession) {
		return;
	}

	CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
	VTEncodeInfoFlags flags = 0;
	OSStatus status = VTCompressionSessionEncodeFrame(self.compressionSession, pixelBuffer, pts, kCMTimeInvalid, NULL, NULL, &flags);
	if (status != noErr) {
		NSLog(@"[SecurityCam] VTCompressionSessionEncodeFrame failed: %d", (int)status);
	}
}

- (void)createCompressionSessionForPixelBuffer:(CVPixelBufferRef)pixelBuffer {
	int sourceWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
	int sourceHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
	OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
												 sourceWidth,
												 sourceHeight,
												 kCMVideoCodecType_H264,
												 NULL,
												 NULL,
												 NULL,
												 BSCCompressionCallback,
												 (__bridge void *)self,
												 &_compressionSession);
	if (status != noErr || !self.compressionSession) {
	NSLog(@"[SecurityCam] VTCompressionSessionCreate failed: %d", (int)status);
		return;
	}

	VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
	VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
	VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(self.bitrate));
	VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(MAX(1, self.fps * 2)));
	VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(self.fps));
	VTCompressionSessionPrepareToEncodeFrames(self.compressionSession);
}

- (void)updateMotionForPixelBuffer:(CVPixelBufferRef)pixelBuffer {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - self.lastMotionSampleTime < 0.5) {
		return;
	}
	self.lastMotionSampleTime = now;

	const size_t gridX = 16;
	const size_t gridY = 12;
	const size_t sampleCount = gridX * gridY;
	uint8_t samples[sampleCount];
	memset(samples, 0, sizeof(samples));

	CVReturn lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
	if (lockStatus != kCVReturnSuccess) {
		return;
	}

	size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
	size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
	size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
	uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
	if (base && width > gridX && height > gridY) {
		size_t index = 0;
		for (size_t y = 0; y < gridY; y++) {
			size_t py = ((y + 1) * height) / (gridY + 1);
			uint8_t *row = base + (py * bytesPerRow);
			for (size_t x = 0; x < gridX; x++) {
				size_t px = ((x + 1) * width) / (gridX + 1);
				samples[index++] = row[px];
			}
		}
	}
	CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

	NSData *signature = [NSData dataWithBytes:samples length:sizeof(samples)];
	NSData *previous = self.previousMotionSignature;
	self.previousMotionSignature = signature;
	if (previous.length != sizeof(samples)) {
		return;
	}

	const uint8_t *prev = (const uint8_t *)previous.bytes;
	unsigned int totalDelta = 0;
	unsigned int changedSamples = 0;
	for (size_t i = 0; i < sampleCount; i++) {
		unsigned int delta = samples[i] > prev[i] ? samples[i] - prev[i] : prev[i] - samples[i];
		totalDelta += delta;
		if (delta >= 18) {
			changedSamples += 1;
		}
	}

	float averageDelta = (float)totalDelta / (float)sampleCount;
	float changedRatio = (float)changedSamples / (float)sampleCount;
	BOOL detected = (averageDelta >= 8.0f && changedRatio >= 0.18f) || averageDelta >= 13.0f;

	@synchronized (self) {
		self.motionScore = averageDelta;
		if (detected) {
			self.motionDetected = YES;
			self.lastMotionTime = now;
		} else if (self.motionDetected && now - self.lastMotionTime > 10.0) {
			self.motionDetected = NO;
		}
	}
}

static void BSCCompressionCallback(void *outputCallbackRefCon,
								   __unused void *sourceFrameRefCon,
								   OSStatus status,
								   __unused VTEncodeInfoFlags infoFlags,
								   CMSampleBufferRef sampleBuffer) {
	if (status != noErr || !sampleBuffer) {
		return;
	}
	BSCVideoEncoder *encoder = (__bridge BSCVideoEncoder *)outputCallbackRefCon;
	[encoder handleEncodedSampleBuffer:sampleBuffer];
}

- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
	BOOL keyframe = YES;
	CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
	if (attachments && CFArrayGetCount(attachments)) {
		CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
		keyframe = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
	}

	CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
	if (format) {
		const uint8_t *sps = NULL;
		const uint8_t *pps = NULL;
		size_t spsSize = 0;
		size_t ppsSize = 0;
		size_t count = 0;
		OSStatus spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &count, NULL);
		OSStatus ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &ppsSize, &count, NULL);
		if (spsStatus == noErr && ppsStatus == noErr && sps && pps) {
			NSData *spsData = [NSData dataWithBytes:sps length:spsSize];
			NSData *ppsData = [NSData dataWithBytes:pps length:ppsSize];
			if (![spsData isEqualToData:self.lastSPS] || ![ppsData isEqualToData:self.lastPPS]) {
				self.lastSPS = spsData;
				self.lastPPS = ppsData;
				[self.delegate videoEncoderDidUpdateSPS:spsData pps:ppsData];
			}
		}
	}

	CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
	if (!blockBuffer) {
		return;
	}

	size_t length = 0;
	char *dataPointer = NULL;
	OSStatus pointerStatus = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &length, &dataPointer);
	if (pointerStatus != noErr || !dataPointer || length < 5) {
		return;
	}

	NSMutableArray<NSData *> *nalUnits = [NSMutableArray array];
	size_t offset = 0;
	while (offset + 4 <= length) {
		uint32_t nalLength = 0;
		memcpy(&nalLength, dataPointer + offset, 4);
		nalLength = CFSwapInt32BigToHost(nalLength);
		offset += 4;
		if (nalLength == 0 || offset + nalLength > length) {
			break;
		}
		[nalUnits addObject:[NSData dataWithBytes:dataPointer + offset length:nalLength]];
		offset += nalLength;
	}

	if (nalUnits.count) {
		[self.delegate videoEncoderDidEncodeNALUnits:nalUnits keyframe:keyframe pts:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
	}
}

- (NSData *)latestJPEGSnapshot {
	CVPixelBufferRef pixelBuffer = NULL;
	@synchronized (self) {
		if (self.latestPixelBuffer) {
			pixelBuffer = CVPixelBufferRetain(self.latestPixelBuffer);
		}
	}
	if (!pixelBuffer) {
		return nil;
	}

	CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
	CGImageRef cgImage = [self.ciContext createCGImage:image fromRect:image.extent];
	CVPixelBufferRelease(pixelBuffer);
	if (!cgImage) {
		return nil;
	}

	UIImage *uiImage = [UIImage imageWithCGImage:cgImage];
	NSData *jpeg = UIImageJPEGRepresentation(uiImage, 0.72);
	CGImageRelease(cgImage);
	return jpeg;
}

- (void)dealloc {
	[self stop];
}

@end
