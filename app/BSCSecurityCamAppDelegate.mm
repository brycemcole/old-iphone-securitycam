#import "BSCSecurityCamAppDelegate.h"
#import "BSCModeController.h"
#import "../shared/BSCModeState.h"
#import <AVFoundation/AVFoundation.h>

@interface BSCBlackViewController : UIViewController
@end

@implementation BSCBlackViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor blackColor];
}

- (BOOL)prefersStatusBarHidden {
	return YES;
}

@end

@interface BSCSecurityCamAppDelegate ()
@property (nonatomic, strong) BSCModeController *modeController;
@property (nonatomic, assign) CGFloat originalBrightness;
@property (nonatomic, strong) AVAudioEngine *keepAliveAudioEngine;
@property (nonatomic, strong) AVAudioSourceNode *silenceSourceNode;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation BSCSecurityCamAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.window.rootViewController = [BSCBlackViewController new];
	self.window.backgroundColor = [UIColor blackColor];
	[self.window makeKeyAndVisible];

	self.originalBrightness = [UIScreen mainScreen].brightness;
	[application setIdleTimerDisabled:YES];
	[UIScreen mainScreen].brightness = 0.0;
	self.backgroundTask = UIBackgroundTaskInvalid;
	[self startBackgroundKeepAlive];

	NSMutableDictionary *state = [[BSCModeState currentState] mutableCopy];
	state[@"OriginalBrightness"] = @(self.originalBrightness);
	state[@"LastAppLaunchAt"] = @([[NSDate date] timeIntervalSince1970]);
	[BSCModeState writeState:state error:nil];

	self.modeController = [[BSCModeController alloc] init];
	NSError *error = nil;
	if (![self.modeController start:&error]) {
		NSLog(@"[SecurityCam] failed to start: %@", error);
	}

	return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	[self beginBackgroundTask:application];
	[self startBackgroundKeepAlive];
	[UIScreen mainScreen].brightness = 0.0;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	[application setIdleTimerDisabled:YES];
	[UIScreen mainScreen].brightness = 0.0;
	[self startBackgroundKeepAlive];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	[self.modeController stop];
	[self stopBackgroundKeepAlive];
	[self endBackgroundTask:application];
	[application setIdleTimerDisabled:NO];
	if (![BSCModeState isEnabled]) {
		[UIScreen mainScreen].brightness = MAX(0.1, self.originalBrightness);
	}
}

- (void)beginBackgroundTask:(UIApplication *)application {
	if (self.backgroundTask != UIBackgroundTaskInvalid) {
		return;
	}

	__weak typeof(self) weakSelf = self;
	self.backgroundTask = [application beginBackgroundTaskWithName:@"SecurityCamKeepAlive" expirationHandler:^{
		__strong typeof(weakSelf) strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		[strongSelf endBackgroundTask:application];
		[strongSelf beginBackgroundTask:application];
	}];
}

- (void)endBackgroundTask:(UIApplication *)application {
	if (self.backgroundTask == UIBackgroundTaskInvalid) {
		return;
	}
	[application endBackgroundTask:self.backgroundTask];
	self.backgroundTask = UIBackgroundTaskInvalid;
}

- (void)startBackgroundKeepAlive {
	if (self.keepAliveAudioEngine.isRunning) {
		return;
	}

	NSError *sessionError = nil;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback
			 withOptions:AVAudioSessionCategoryOptionMixWithOthers
				   error:&sessionError];
	[session setActive:YES error:&sessionError];
	if (sessionError) {
		NSLog(@"[SecurityCam] keepalive audio session error: %@", sessionError);
	}

	AVAudioEngine *engine = [AVAudioEngine new];
	AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:8000 channels:1];
	AVAudioSourceNode *source = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(__unused BOOL *isSilence,
																									   __unused const AudioTimeStamp *timestamp,
																									   __unused AVAudioFrameCount frameCount,
																									   AudioBufferList *outputData) {
		for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
			memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
		}
		if (isSilence) {
			*isSilence = YES;
		}
		return noErr;
	}];
	[engine attachNode:source];
	[engine connect:source to:engine.mainMixerNode format:format];
	engine.mainMixerNode.outputVolume = 0.0;

	NSError *engineError = nil;
	if (![engine startAndReturnError:&engineError]) {
		NSLog(@"[SecurityCam] keepalive audio engine failed: %@", engineError);
		return;
	}
	self.keepAliveAudioEngine = engine;
	self.silenceSourceNode = source;
}

- (void)stopBackgroundKeepAlive {
	[self.keepAliveAudioEngine stop];
	self.keepAliveAudioEngine = nil;
	self.silenceSourceNode = nil;
	[[AVAudioSession sharedInstance] setActive:NO withOptions:0 error:nil];
}

@end
