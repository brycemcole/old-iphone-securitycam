#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface BSCModeController : NSObject

- (BOOL)start:(NSError **)error;
- (void)stop;
- (NSDictionary *)statusSnapshot;

@end

NS_ASSUME_NONNULL_END
