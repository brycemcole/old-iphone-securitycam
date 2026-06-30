#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BSCBonjourServiceType;

@interface BSCBonjourPublisher : NSObject

@property (nonatomic, readonly, copy) NSString *serviceName;

- (void)startWithHTTPPort:(uint16_t)httpPort rtspPort:(uint16_t)rtspPort;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
