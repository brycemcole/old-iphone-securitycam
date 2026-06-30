#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSDictionary *_Nonnull (^BSCStatusProvider)(void);
typedef NSData *_Nonnull (^BSCSnapshotProvider)(void);

@interface BSCHTTPServer : NSObject

- (instancetype)initWithPort:(uint16_t)port statusProvider:(BSCStatusProvider)statusProvider snapshotProvider:(BSCSnapshotProvider)snapshotProvider;
- (BOOL)start:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
