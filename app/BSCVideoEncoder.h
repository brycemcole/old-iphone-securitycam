#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BSCVideoEncoderDelegate <NSObject>
- (void)videoEncoderDidUpdateSPS:(NSData *)sps pps:(NSData *)pps;
- (void)videoEncoderDidEncodeNALUnits:(NSArray<NSData *> *)nalUnits keyframe:(BOOL)keyframe pts:(CMTime)pts;
@end

@interface BSCVideoEncoder : NSObject

@property (nonatomic, weak) id<BSCVideoEncoderDelegate> delegate;
@property (nonatomic, readonly) float motionScore;
@property (nonatomic, readonly, getter=isMotionDetected) BOOL motionDetected;
@property (nonatomic, readonly) NSTimeInterval lastMotionTime;
@property (nonatomic, readonly, getter=isCaptureRunning) BOOL captureRunning;
@property (nonatomic, readonly, copy) NSString *lastCaptureEvent;

- (instancetype)initWithWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (nullable NSData *)latestJPEGSnapshot;

@end

NS_ASSUME_NONNULL_END
