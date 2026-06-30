#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BSCBundleIdentifier;
extern NSString * const BSCModePreferencePath;
extern const char *BSCModeChangedNotification;

@interface BSCModeState : NSObject

+ (NSDictionary *)currentState;
+ (BOOL)isEnabled;
+ (BOOL)setEnabled:(BOOL)enabled reason:(NSString *)reason error:(NSError **)error;
+ (BOOL)writeState:(NSDictionary *)state error:(NSError **)error;
+ (void)postChangedNotification;

@end

NS_ASSUME_NONNULL_END
