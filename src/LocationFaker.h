#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface LocationFaker : NSObject

+ (void)setupLocationFakerWithLat:(double)lat lon:(double)lon radiusKm:(double)radius;
+ (void)stopFakingLocation;
+ (BOOL)isFakingLocation;

@end