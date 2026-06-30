#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSCRTSPServer : NSObject

- (instancetype)initWithPort:(uint16_t)port fps:(int)fps;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)updateSPS:(NSData *)sps pps:(NSData *)pps;
- (void)broadcastNALUnits:(NSArray<NSData *> *)nalUnits keyframe:(BOOL)keyframe pts:(CMTime)pts;

@end

NS_ASSUME_NONNULL_END
