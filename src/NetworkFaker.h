#import <Foundation/Foundation.h>

@interface NetworkFaker : NSObject

+ (void)applyNetworkConfig:(NSDictionary *)config;
+ (void)resetToDefault;
+ (BOOL)isFaking;

@end