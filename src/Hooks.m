//
//  Hooks.m
//  AppWiper v2.08
//
//  Core runtime hook bundle for AppWiper.  Impersonates the device
//  fingerprint, network identity, and location of a single target app
//  while leaving every other process on the device untouched.
//
//  Uses the classic CydiaSubstrate / MobileSubstrate C API:
//    - MSHookMessageEx  for Objective-C method swizzling.
//    - MSHookFunction   for C-function interception.
//  No Logos %hook directives are used.
//
//  Every hook is gated on `g_isTargetApp`; system daemons and the
//  SpringBoard whitelist bypass straight to the original implementation.
//
//  Built for Theos with -fobjc-arc.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CoreTelephony.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <StoreKit/StoreKit.h>
#import <AdSupport/AdSupport.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>
#import <mach/mach.h>
#import <math.h>
#import <errno.h>
#import <time.h>
#import <stdio.h>

#import <substrate.h>

#include "DeviceModels.h"
#include "WiperHelper.h"
#include "NetworkFaker.h"
#include "LocationFaker.h"

// ===========================================================================
//  Global state
// ===========================================================================

// The fully-resolved config plist for the target app, loaded once at
// constructor time and refreshed on demand.  nil in non-target processes.
NSDictionary *g_config = nil;

// YES only inside the single app that AppWiper is configured to spoof.
BOOL g_isTargetApp = NO;

// The raw target bundle identifier (read from the process Info.plist).
static NSString *g_targetBundleID = nil;

// The spoofed machine identifier selected for this app (e.g. "iPhone14,3").
static NSString *g_spoofMachine = nil;

// Cached descriptor resolved from g_spoofMachine via DeviceModels.
static NSDictionary *g_spoofDeviceInfo = nil;

// Cached IDFA / IDFV UUID strings so they stay stable across queries.
static NSString *g_spoofIDFA = nil;
static NSString *g_spoofIDFV = nil;

// Spoofed device name (e.g. "iPhone").
static NSString *g_spoofDeviceName = nil;

// Spoofed serial / UUID / UDID / ECID for IOKit.
static NSString *g_spoofSerial = nil;
static NSString *g_spoofPlatformUUID = nil;
static NSString *g_spoofUDID = nil;
static NSString *g_spoofECID = nil;

// Spoofed boot time (epoch seconds) for kern.boottime.
static uint64_t g_spoofBootTime = 0;

// Spoofed Wi-Fi BSSID / SSID.
static NSString *g_spoofBSSID = nil;
static NSString *g_spoofSSID = nil;

// Reachability flags preset (0 = airplane, etc.).
static SCNetworkReachabilityFlags g_spoofReachabilityFlags = 0;

// ===========================================================================
//  1. Process isolation
// ===========================================================================

// Bundle identifiers that must never be touched.  Hooking inside these
// would destabilise the system UI / package managers.
static NSSet *systemBlacklist(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.backboardd",
            @"com.apple.preferences",
            @"org.coolstar.sileo",
            @"org.coolstar.Sileo",
            @"com.saurik.Cydia",
            @"com.cydia.Cydia",
            @"com.apple.mobilesafari",
            @"com.apple.MobileStore",
            @"com.apple.appstore",
            @"com.apple.AppleIDSSOAccount",
            @"com.apple.Maps",
            @"com.apple.locationd",
        ]];
    });
    return s;
}

// Resolve the hosting process's own bundle identifier from its Info.plist.
static NSString *currentBundleID(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    return info[@"CFBundleIdentifier"];
}

// Returns YES only when this process is the single target app AND is not
// in the system blacklist.  Called once at constructor time to set
// g_isTargetApp, but also re-checked per-hook for safety.
static BOOL computeIsTargetApp(void) {
    NSString *bid = currentBundleID();
    if (!bid || bid.length == 0) {
        return NO; // a daemon with no bundle id is a system process
    }
    if ([systemBlacklist() containsObject:bid]) {
        return NO;
    }
    // Any process that loads a MobileSubstrate tweak is a user app by
    // default; confirm a config file exists for it.
    NSString *cfgPath = [WiperHelper getConfigPathForBundleID:bid];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cfgPath]) {
        return NO;
    }
    g_targetBundleID = [bid copy];
    return YES;
}

// ===========================================================================
//  2. Configuration loading
// ===========================================================================

// Read /var/mobile/Library/Preferences/AppWiper_<bundleID>.plist into the
// global g_config dictionary.  Safe to call repeatedly; the file is only
// re-read when its modification time changes.
static time_t g_lastConfigMtime = 0;

static void loadConfig(void) {
    if (!g_targetBundleID) {
        return;
    }
    NSString *path = [WiperHelper getConfigPathForBundleID:g_targetBundleID];

    struct stat st;
    if (stat([path UTF8String], &st) != 0) {
        return; // config vanished; keep stale copy
    }
    if (st.st_mtime == g_lastConfigMtime && g_config) {
        return; // unchanged
    }
    g_lastConfigMtime = st.st_mtime;

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!d) {
        return;
    }
    g_config = d;
    NSLog(@"[AppWiper] config loaded for %@ (%lu keys)",
          g_targetBundleID, (unsigned long)d.count);
}

// Convenience accessor with nil-safety.
static id cfgValue(NSString *key) {
    return g_config ? g_config[key] : nil;
}

static BOOL cfgBool(NSString *key) {
    id v = cfgValue(key);
    if ([v isKindOfClass:[NSNumber class]]) {
        return [v boolValue];
    }
    return NO;
}

static NSString *cfgString(NSString *key) {
    id v = cfgValue(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// Forward declarations for the random-value helpers used below.  These are
// plain C functions (not Objc methods), so they must be declared before use.
static NSString *self_realMachine(void);
static NSString *self_randomSerial(NSUInteger length);
static NSString *self_randomHex(NSUInteger length);

// ===========================================================================
//  3. Spoof-identity resolution
// ===========================================================================

// Populate the g_spoof* globals from the loaded config.  The user picks a
// target machine identifier in the config plist under the "spoof_machine"
// key; everything else is derived from the DeviceModels matrix or
// generated once and cached.
static void resolveSpoofIdentity(void) {
    g_spoofMachine = [cfgString(@"spoof_machine") copy];
    if (!g_spoofMachine) {
        // Default: keep the real machine so at least the hooks are inert.
        g_spoofMachine = [self_realMachine() copy];
    }
    g_spoofDeviceInfo = [DeviceModels deviceInfoForMachine:g_spoofMachine];

    // IDFA: prefer an explicit value in config, else generate a stable one.
    g_spoofIDFA = [cfgString(@"spoof_idfa") copy];
    if (!g_spoofIDFA) {
        g_spoofIDFA = [[NSUUID UUID] UUIDString];
    }

    g_spoofIDFV = [cfgString(@"spoof_idfv") copy];
    if (!g_spoofIDFV) {
        g_spoofIDFV = [[NSUUID UUID] UUIDString];
    }

    g_spoofDeviceName = [cfgString(@"spoof_device_name") copy];
    if (!g_spoofDeviceName) {
        g_spoofDeviceName = @"iPhone";
    }

    g_spoofSerial     = [cfgString(@"spoof_serial") copy];
    g_spoofPlatformUUID = [cfgString(@"spoof_platform_uuid") copy];
    g_spoofUDID       = [cfgString(@"spoof_udid") copy];
    g_spoofECID       = [cfgString(@"spoof_ecid") copy];

    if (!g_spoofSerial) {
        g_spoofSerial = self_randomSerial(12);
    }
    if (!g_spoofPlatformUUID) {
        g_spoofPlatformUUID = [[NSUUID UUID] UUIDString];
    }
    if (!g_spoofUDID) {
        g_spoofUDID = self_randomHex(40);
    }
    if (!g_spoofECID) {
        g_spoofECID = self_randomHex(16);
    }

    // Boot time: a random moment in the last 72h unless overridden.
    id bt = cfgValue(@"spoof_boottime");
    if ([bt isKindOfClass:[NSNumber class]]) {
        g_spoofBootTime = [bt unsignedLongLongValue];
    } else {
        g_spoofBootTime = (uint64_t)(time(NULL) - arc4random_uniform(72 * 3600));
    }

    // Wi-Fi.
    g_spoofBSSID = [cfgString(@"spoof_bssid") copy];
    if (!g_spoofBSSID) {
        g_spoofBSSID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                        arc4random_uniform(256) & 0xFE, arc4random_uniform(256),
                        arc4random_uniform(256), arc4random_uniform(256),
                        arc4random_uniform(256), arc4random_uniform(256)];
    }
    g_spoofSSID = [cfgString(@"spoof_ssid") copy];
    if (!g_spoofSSID) {
        g_spoofSSID = @"TP-LINK_5G";
    }

    // Reachability flags from NetworkFaker profile, if any.
    id rf = cfgValue(@"NetworkReachabilityFlags");
    if ([rf isKindOfClass:[NSNumber class]]) {
        g_spoofReachabilityFlags = (SCNetworkReachabilityFlags)[rf integerValue];
    } else {
        g_spoofReachabilityFlags = kSCNetworkReachabilityFlagsReachable;
    }
}

// Random-value helpers (forward-declared above so resolveSpoofIdentity
// can call them).  All return autoreleased NSStrings under ARC.
static NSString *self_realMachine(void) {
    size_t size = 64;
    char buf[64] = {0};
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) != 0) {
        return @"iPhone14,5";
    }
    return [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
}

static NSString *self_randomSerial(NSUInteger length) {
    // 0-9, A-Z excluding O/0/I/1 confusion.
    static const char alphabet[] = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    NSUInteger n = sizeof(alphabet) - 1;
    char *p = (char *)malloc(length + 1);
    for (NSUInteger i = 0; i < length; i++) {
        p[i] = alphabet[arc4random_uniform((uint32_t)n)];
    }
    p[length] = '\0';
    NSString *s = [NSString stringWithCString:p encoding:NSUTF8StringEncoding];
    free(p);
    return s;
}

static NSString *self_randomHex(NSUInteger length) {
    static const char hex[] = "0123456789abcdef";
    char *p = (char *)malloc(length + 1);
    for (NSUInteger i = 0; i < length; i++) {
        p[i] = hex[arc4random_uniform(16)];
    }
    p[length] = '\0';
    NSString *s = [NSString stringWithCString:p encoding:NSUTF8StringEncoding];
    free(p);
    return s;
}

// ===========================================================================
//  4. IDFA spoofing  (ASIdentifierManager -advertisingIdentifier)
// ===========================================================================

// Original IMP for -[ASIdentifierManager advertisingIdentifier].
static NSUUID *(*orig_advertisingIdentifier)(id, SEL);

static NSUUID *hook_advertisingIdentifier(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofIDFA) {
        return orig_advertisingIdentifier(self, _cmd);
    }
    return [[NSUUID alloc] initWithUUIDString:g_spoofIDFA];
}

// ===========================================================================
//  5. UIDevice spoofing  (identifierForVendor / name / systemVersion / model)
// ===========================================================================

static NSUUID  *(*orig_uidev_idfv)(id, SEL);
static NSString *(*orig_uidev_name)(id, SEL);
static NSString *(*orig_uidev_sysver)(id, SEL);
static NSString *(*orig_uidev_model)(id, SEL);
static NSString *(*orig_uidev_locmodel)(id, SEL);

static NSUUID *hook_uidev_idfv(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofIDFV) {
        return orig_uidev_idfv(self, _cmd);
    }
    return [[NSUUID alloc] initWithUUIDString:g_spoofIDFV];
}

static NSString *hook_uidev_name(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceName) {
        return orig_uidev_name(self, _cmd);
    }
    return g_spoofDeviceName;
}

static NSString *hook_uidev_systemVersion(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_uidev_sysver(self, _cmd);
    }
    // Match the iOS version that ships on the spoofed device family by
    // defaulting to the running system version unless overridden.
    NSString *v = cfgString(@"spoof_system_version");
    return v ?: orig_uidev_sysver(self, _cmd);
}

static NSString *hook_uidev_model(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_uidev_model(self, _cmd);
    }
    // e.g. "iPhone" — the marketing family prefix.
    return @"iPhone";
}

static NSString *hook_uidev_localizedModel(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_uidev_locmodel(self, _cmd);
    }
    return g_spoofDeviceInfo[@"marketing_name"] ?: @"iPhone";
}

// ===========================================================================
//  6. IOKit hardware fingerprint
//     MSHookFunction IORegistryEntryCreateCFProperty
// ===========================================================================

static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(
    io_registry_entry_t entry, const char *key,
    CFAllocatorRef allocator, uint32_t options);

// Map an IOKit key to its spoofed value.
static CFTypeRef spoofIOKitValue(const char *key) {
    if (!g_isTargetApp) {
        return NULL;
    }
    if (!key) {
        return NULL;
    }
    NSString *k = [NSString stringWithCString:key encoding:NSUTF8StringEncoding];

    // Serial number (multiple key variants seen in the wild).
    if ([k isEqualToString:@"IOPlatformSerialNumber"] ||
        [k isEqualToString:@"serial-number"] ||
        [k isEqualToString:@"SERIAL"]) {
        return (__bridge_retained CFTypeRef)g_spoofSerial;
    }
    // Platform UUID.
    if ([k isEqualToString:@"IOPlatformUUID"] ||
        [k isEqualToString:@"platform-uuid"]) {
        return (__bridge_retained CFTypeRef)g_spoofPlatformUUID;
    }
    // Unique device identifier (UDID).
    if ([k isEqualToString:@"unique-device-id"] ||
        [k isEqualToString:@"UniqueDeviceID"]) {
        return (__bridge_retained CFTypeRef)g_spoofUDID;
    }
    // ECID (epoch chip ID).
    if ([k isEqualToString:@"ecid"] ||
        [k isEqualToString:@"IOPlatformECID"]) {
        return (__bridge_retained CFTypeRef)g_spoofECID;
    }
    // Board ID / model code.
    if ([k isEqualToString:@"model"] ||
        [k isEqualToString:@"ProductType"] ||
        [k isEqualToString:@"hw-model"]) {
        NSString *m = g_spoofDeviceInfo[@"hw_model"];
        if (m) {
            return (__bridge_retained CFTypeRef)m;
        }
    }
    // Board identifier.
    if ([k isEqualToString:@"board-id"] ||
        [k isEqualToString:@"target-type"]) {
        return (__bridge_retained CFTypeRef)g_spoofMachine;
    }
    // Battery serial (covered as a bonus).
    if ([k isEqualToString:@"BatterySerialNumber"] ||
        [k isEqualToString:@"battery-data"]) {
        return (__bridge_retained CFTypeRef)self_randomSerial(12);
    }
    // Design capacity / cycle count: leave real values, they are not
    // strongly identifying, but we still mask the serial above.
    return NULL;
}

static CFTypeRef hook_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, const char *key,
    CFAllocatorRef allocator, uint32_t options) {
    CFTypeRef spoofed = spoofIOKitValue(key);
    if (spoofed) {
        return spoofed;
    }
    return orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

// ===========================================================================
//  7. Sysctl spoofing
//     MSHookFunction sysctlbyname
// ===========================================================================

static int (*orig_sysctlbyname)(
    const char *name, void *oldp, size_t *oldlenp,
    const void *newp, size_t newlen);

static int hook_sysctlbyname(
    const char *name, void *oldp, size_t *oldlenp,
    const void *newp, size_t newlen) {

    if (!g_isTargetApp || !name) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }

    // hw.machine -> spoofed identifier string.
    if (strcmp(name, "hw.machine") == 0) {
        if (oldp && oldlenp) {
            const char *m = [g_spoofMachine UTF8String];
            size_t need = strlen(m) + 1;
            if (*oldlenp >= need) {
                memcpy(oldp, m, need);
                *oldlenp = need;
                return 0;
            }
            *oldlenp = need; // tell caller how much space we need
            return 0;
        }
        if (oldlenp) {
            *oldlenp = [g_spoofMachine length] + 1;
        }
        return 0;
    }

    // hw.memsize -> spoofed physmem.
    if (strcmp(name, "hw.memsize") == 0 && g_spoofDeviceInfo) {
        uint64_t mem = [g_spoofDeviceInfo[@"physmem"] unsignedLongLongValue];
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            *(uint64_t *)oldp = mem;
            *oldlenp = sizeof(uint64_t);
            return 0;
        }
        if (oldlenp) {
            *oldlenp = sizeof(uint64_t);
        }
        return 0;
    }

    // hw.ncpu / hw.logicalcpu / hw.physicalcpu -> spoofed core count.
    if ((strcmp(name, "hw.ncpu") == 0 ||
         strcmp(name, "hw.logicalcpu") == 0 ||
         strcmp(name, "hw.logicalcpu_max") == 0 ||
         strcmp(name, "hw.physicalcpu") == 0 ||
         strcmp(name, "hw.physicalcpu_max") == 0) && g_spoofDeviceInfo) {
        uint32_t cores = (uint32_t)[g_spoofDeviceInfo[@"cpu_cores"] unsignedIntValue];
        // A10 reports 4 logical / 4 physical; older dual-core report 2.
        if (oldp && oldlenp && *oldlenp >= sizeof(uint32_t)) {
            *(uint32_t *)oldp = cores;
            *oldlenp = sizeof(uint32_t);
            return 0;
        }
        if (oldlenp) {
            *oldlenp = sizeof(uint32_t);
        }
        return 0;
    }

    // kern.boottime -> spoofed timeval.
    if (strcmp(name, "kern.boottime") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(struct timeval)) {
            struct timeval tv;
            tv.tv_sec = (long)g_spoofBootTime;
            tv.tv_usec = 0;
            *(struct timeval *)oldp = tv;
            *oldlenp = sizeof(struct timeval);
            return 0;
        }
        if (oldlenp) {
            *oldlenp = sizeof(struct timeval);
        }
        return 0;
    }

    // hw.model -> spoofed board code.
    if (strcmp(name, "hw.model") == 0 && g_spoofDeviceInfo) {
        NSString *m = g_spoofDeviceInfo[@"hw_model"];
        if (oldp && oldlenp) {
            const char *c = [m UTF8String];
            size_t need = strlen(c) + 1;
            if (*oldlenp >= need) {
                memcpy(oldp, c, need);
                *oldlenp = need;
                return 0;
            }
            *oldlenp = need;
            return 0;
        }
        if (oldlenp) {
            *oldlenp = [m length] + 1;
        }
        return 0;
    }

    // Fall through to the real call for everything else (hw.byteorder, etc.).
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ===========================================================================
//  8. UIScreen  (bounds / scale / nativeScale / maximumFramesPerSecond)
// ===========================================================================

static CGRect (*orig_screen_bounds)(id, SEL);
static CGFloat (*orig_screen_scale)(id, SEL);
static CGFloat (*orig_screen_nativeScale)(id, SEL);
static NSInteger (*orig_screen_maxFPS)(id, SEL);

static CGRect hook_screen_bounds(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_screen_bounds(self, _cmd);
    }
    CGFloat w = [g_spoofDeviceInfo[@"pt_width"] doubleValue];
    CGFloat h = [g_spoofDeviceInfo[@"pt_height"] doubleValue];
    return CGRectMake(0, 0, w, h);
}

static CGFloat hook_screen_scale(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_screen_scale(self, _cmd);
    }
    return [g_spoofDeviceInfo[@"scale"] doubleValue];
}

static CGFloat hook_screen_nativeScale(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_screen_nativeScale(self, _cmd);
    }
    return [g_spoofDeviceInfo[@"scale"] doubleValue];
}

static NSInteger hook_screen_maxFPS(id self, SEL _cmd) {
    if (!g_isTargetApp || !g_spoofDeviceInfo) {
        return orig_screen_maxFPS(self, _cmd);
    }
    return [g_spoofDeviceInfo[@"max_fps"] integerValue];
}

// ===========================================================================
//  9. GPS location  (CLLocationManager -location)
//
//  Applies a micro-metre-grade jitter so the spoofed coordinate drifts
//  naturally around the configured centre, defeating naive "exactly the
//  same reading" heuristics.
// ===========================================================================

static CLLocation *(*orig_clmgr_location)(id, SEL);

// Convert metres of offset to degrees (approx, valid for small deltas).
static double metersToDegreesLat(double meters) {
    return meters / 111320.0; // 1 deg lat ~ 111.32 km
}
static double metersToDegreesLon(double meters, double lat) {
    double cosLat = cos(lat * M_PI / 180.0);
    if (cosLat < 1e-6) {
        cosLat = 1e-6;
    }
    return meters / (111320.0 * cosLat);
}

// Produce a jittered coordinate around (lat, lon) within +/- radius meters.
static CLLocation *jitteredLocation(CLLocationCoordinate2D centre) {
    // Read the configured centre / radius from g_config.
    double baseLat = [cfgValue(@"spoof_lat") doubleValue];
    double baseLon = [cfgValue(@"spoof_lon") doubleValue];
    double radius  = [cfgValue(@"spoof_radius_m") doubleValue];

    if (baseLat == 0.0 && baseLon == 0.0) {
        // No explicit GPS config: use the real location with a tiny nudge.
        baseLat = centre.latitude;
        baseLon = centre.longitude;
    }
    if (radius <= 0.0) {
        radius = 15.0; // default 15 m wandering radius
    }

    // Uniform random offset inside a disc of `radius` metres.
    double r = radius * sqrt((double)arc4random_uniform(1000000) / 1000000.0);
    double theta = ((double)arc4random_uniform(3600000) / 1000000.0) * M_PI / 180.0;
    double dLat = metersToDegreesLat(r * sin(theta));
    double dLon = metersToDegreesLon(r * cos(theta), baseLat);

    CLLocationCoordinate2D coord;
    coord.latitude = baseLat + dLat;
    coord.longitude = baseLon + dLon;

    // Altitude: small drift around a plausible value.
    double alt = 50.0 + arc4random_uniform(100);
    CLLocationAccuracy hacc = 5.0 + arc4random_uniform(10);
    CLLocationAccuracy vacc = 10.0 + arc4random_uniform(20);

    // Use the current time so the fix looks authentic.
    NSDate *ts = [NSDate date];

    return [[CLLocation alloc] initWithCoordinate:coord
                                          altitude:alt
                                horizontalAccuracy:hacc
                                  verticalAccuracy:vacc
                                 course:-1.0
                                  speed:-1.0
                              timestamp:ts];
}

static CLLocation *hook_clmgr_location(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_clmgr_location(self, _cmd);
    }
    CLLocation *real = orig_clmgr_location(self, _cmd);
    if (!real) {
        return jitteredLocation(kCLLocationCoordinate2DInvalid);
    }
    if (!cfgBool(@"spoof_location")) {
        return real;
    }
    return jitteredLocation(real.coordinate);
}

// ===========================================================================
//  10. CoreTelephony
//      CTTelephonyNetworkInfo / CTCarrier
// ===========================================================================

// Modern (iOS 16+) API: -[CTCarrier subscriberCellularProvider] and the
// CTTelephonyNetworkInfo service-provider methods.  We hook the CTCarrier
// accessors so an app reading carrier name / mcc / mnc / voip gets the
// persona we configured.

static NSString *(*orig_carrier_carrierName)(id, SEL);
static NSString *(*orig_carrier_mobileCC)(id, SEL);
static NSString *(*orig_carrier_mobileNC)(id, SEL);
static NSString *(*orig_carrier_isoCountryCode)(id, SEL);
static BOOL     (*orig_carrier_allowsVOIP)(id, SEL);

static NSString *hook_carrier_carrierName(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_carrier_carrierName(self, _cmd);
    }
    // Airplane / no-SIM modes report nil.
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return nil;
    }
    return cfgString(@"NetworkCarrierName") ?: orig_carrier_carrierName(self, _cmd);
}

static NSString *hook_carrier_mcc(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_carrier_mobileCC(self, _cmd);
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return nil;
    }
    return cfgString(@"NetworkMCC") ?: orig_carrier_mobileCC(self, _cmd);
}

static NSString *hook_carrier_mnc(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_carrier_mobileNC(self, _cmd);
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return nil;
    }
    return cfgString(@"NetworkMNC") ?: orig_carrier_mobileNC(self, _cmd);
}

static NSString *hook_carrier_iso(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_carrier_isoCountryCode(self, _cmd);
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return nil;
    }
    // Derive ISO country code from MCC.
    NSString *mcc = cfgString(@"NetworkMCC");
    if ([mcc isEqualToString:@"460"]) {
        return @"cn";
    }
    return orig_carrier_isoCountryCode(self, _cmd);
}

static BOOL hook_carrier_voip(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_carrier_allowsVOIP(self, _cmd);
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return NO;
    }
    return YES;
}

// Hook -[CTTelephonyNetworkInfo serviceSubscriberCellularProviders] /
// -[CTTelephonyNetworkInfo currentRadioAccessTechnology] to report the
// spoofed radio technology.
static NSString *(*orig_ctni_radioTech)(id, SEL);

static NSString *hook_ctni_radioTech(id self, SEL _cmd) {
    if (!g_isTargetApp) {
        return orig_ctni_radioTech(self, _cmd);
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"] || [m isEqualToString:@"NO_SIM"]) {
        return nil;
    }
    return cfgString(@"NetworkRadioTech") ?: orig_ctni_radioTech(self, _cmd);
}

// ===========================================================================
//  11. SystemConfiguration
//      MSHookFunction SCNetworkReachabilityGetFlags
// ===========================================================================

static Boolean (*orig_SCNetworkReachabilityGetFlags)(
    SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags);

static Boolean hook_SCNetworkReachabilityGetFlags(
    SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ok = orig_SCNetworkReachabilityGetFlags(target, flags);
    if (!g_isTargetApp || !flags) {
        return ok;
    }
    // In airplane mode, report no connectivity at all.
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"]) {
        *flags = 0;
        return ok;
    }
    if ([m isEqualToString:@"WIFI_ONLY"]) {
        // Reachable via Wi-Fi, not via cellular — drop the WWAN bit.
        *flags = kSCNetworkReachabilityFlagsReachable;
        *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
        return ok;
    }
    if (cfgBool(@"NetworkFaking")) {
        *flags = g_spoofReachabilityFlags;
        // Strip the WWAN bit in Wi-Fi-only mode.
        if ([m isEqualToString:@"WIFI_ONLY"]) {
            *flags &= ~kSCNetworkReachabilityFlagsIsWWAN;
        }
    }
    return ok;
}

// ===========================================================================
//  12. Wi-Fi  (CNCopySupportedInterfaces / CNCopyCurrentNetworkInfo)
// ===========================================================================

static CFArrayRef (*orig_CNcopySupportedInterfaces)(void);
static CFDictionaryRef (*orig_CNcopyCurrentNetworkInfo)(CFStringRef interfaceName);

static CFArrayRef hook_CNcopySupportedInterfaces(void) {
    CFArrayRef real = orig_CNcopySupportedInterfaces();
    if (!g_isTargetApp) {
        return real;
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"]) {
        // No interfaces at all.
        if (real) {
            CFRelease(real);
        }
        return NULL;
    }
    return real;
}

static CFDictionaryRef hook_CNcopyCurrentNetworkInfo(CFStringRef interfaceName) {
    CFDictionaryRef real = orig_CNcopyCurrentNetworkInfo(interfaceName);
    if (!g_isTargetApp) {
        return real;
    }
    NSString *m = cfgString(@"mode");
    if ([m isEqualToString:@"AIRPLANE_MODE"]) {
        if (real) {
            CFRelease(real);
        }
        return NULL;
    }
    // Synthesise a Wi-Fi info dict with our spoofed BSSID / SSID.
    NSDictionary *spoof = @{
        @"BSSID": g_spoofBSSID ?: @"02:00:00:00:00:00",
        @"SSID":  g_spoofSSID ?: @"WLAN",
        @"SSIDDATA": [g_spoofSSID dataUsingEncoding:NSUTF8StringEncoding] ?: [@"WLAN" dataUsingEncoding:NSUTF8StringEncoding],
    };
    // Drop the original (Copy semantics: orig returned +1) to avoid a leak.
    if (real) {
        CFRelease(real);
    }
    return (__bridge_retained CFTypeRef)spoof;
}

// ===========================================================================
//  13. Jailbreak-detection bypass
//      MSHookFunction stat / lstat / access
// ===========================================================================

// Paths whose existence leaks a jailbreak.  We make them "not found".
static BOOL isJailbreakPath(const char *path) {
    if (!path) {
        return NO;
    }
    static NSArray<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Installer.app",
            @"/Library/MobileSubstrate/MobileSubstrate.dylib",
            @"/bin/bash",
            @"/bin/su",
            @"/usr/bin/sshd",
            @"/usr/sbin/sshd",
            @"/usr/libexec/sftp-server",
            @"/usr/bin/ssh",
            @"/etc/apt",
            @"/private/var/lib/apt",
            @"/var/lib/apt",
            @"/usr/sbin/sshd",
            @"/private/var/lib/cydia",
            @"/var/lib/cydia",
            @"/var/cache/apt",
            @"/var/log/syslog",
            @"/usr/bin/cycript",
            @"/usr/local/bin/cycript",
            @"/var/jb",            // rootless jailbreak root
            @"/var/LIY",           // legacy checkra1n / palera1n marker
            @"/var/checkra1n.dmg",
            @"/private/preboot",
            @"/jb",
            @"/.bootstrapped",
        ];
    });

    // Fast path: exact match against the static list.
    NSString *p = [NSString stringWithCString:path encoding:NSUTF8StringEncoding];
    if (!p) {
        return NO;
    }
    for (NSString *blocked in paths) {
        if ([p isEqualToString:blocked]) {
            return YES;
        }
        // Also catch "/var/jb/..." sub-paths.
        if ([p hasPrefix:[blocked stringByAppendingString:@"/"]]) {
            return YES;
        }
    }

    // Heuristic: any path containing common jailbreak artefacts.
    static NSArray<NSString *> *needles = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        needles = @[ @"cydia", @"sileo", @"substrate", @"palera1n",
                     @"checkra1n", @"unc0ver", @"electra", @"taurine",
                     @"odyssey", @"/var/jb", @"/var/LIY", @".appinst" ];
    });
    NSString *lower = [p lowercaseString];
    for (NSString *n in needles) {
        if ([lower containsString:n]) {
            return YES;
        }
    }
    return NO;
}

static int (*orig_stat)(const char *path, struct stat *buf);
static int (*orig_lstat)(const char *path, struct stat *buf);
static int (*orig_access)(const char *path, int amode);

static int hook_stat(const char *path, struct stat *buf) {
    if (g_isTargetApp && isJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_stat(path, buf);
}

static int hook_lstat(const char *path, struct stat *buf) {
    if (g_isTargetApp && isJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_lstat(path, buf);
}

static int hook_access(const char *path, int amode) {
    if (g_isTargetApp && isJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, amode);
}

// Also neutralise fopen for the same paths (bonus).
static FILE *(*orig_fopen)(const char *path, const char *mode);
static FILE *hook_fopen(const char *path, const char *mode) {
    if (g_isTargetApp && isJailbreakPath(path)) {
        errno = ENOENT;
        return NULL;
    }
    return orig_fopen(path, mode);
}

// ===========================================================================
//  14. StoreKit  (SKPaymentQueue -addPayment:)
// ===========================================================================

static void (*orig_addPayment)(id, SEL, SKPayment *);

static void hook_addPayment(id self, SEL _cmd, SKPayment *payment) {
    if (!g_isTargetApp) {
        orig_addPayment(self, _cmd, payment);
        return;
    }
    // Unless an explicit "allow_iap" flag is set, silently drop the
    // purchase so the app cannot charge the device owner.
    if (cfgBool(@"allow_iap")) {
        orig_addPayment(self, _cmd, payment);
        return;
    }
    NSLog(@"[AppWiper] IAP blocked: %@", payment.productIdentifier ?: @"(unknown)");
    // The payment is never queued, so SKPaymentQueue will simply report no
    // transactions for this product to any registered observer.  Apps that
    // poll the queue will not hang indefinitely.
}

// ===========================================================================
//  15. User-Agent  (NSUserDefaults -stringForKey:)
// ===========================================================================

static NSString *(*orig_stringForKey)(id, SEL, NSString *);

static NSString *hook_stringForKey(id self, SEL _cmd, NSString *key) {
    NSString *val = orig_stringForKey(self, _cmd, key);

    if (!g_isTargetApp || !key) {
        return val;
    }

    // Intercept the keys apps commonly use to cache a custom UA.
    if ([key isEqualToString:@"UserAgent"] ||
        [key isEqualToString:@"userAgent"] ||
        [key isEqualToString:@"UAString"]) {
        NSString *ua = cfgString(@"spoof_user_agent");
        if (ua) {
            return ua;
        }
    }

    // Apps that fingerprint via NSUserDefaults bundle id presence.
    if ([key isEqualToString:@"SBFormattedPhoneNumber"] ||
        [key isEqualToString:@"DeviceName"]) {
        return g_spoofDeviceName ?: val;
    }

    return val;
}

// ===========================================================================
//  16. Initialisation / constructor
// ===========================================================================

// Install a single MSHookMessageEx and stash the original IMP.
static void installMethodHook(Class cls, const char *selName,
                              IMP replacement, IMP *origPtr) {
    SEL sel = sel_registerName(selName);
    if (!sel) {
        NSLog(@"[AppWiper] sel_registerName failed for %s", selName);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, origPtr);
}

// The tweak entry point.  Equivalent to a Logos %ctor.
__attribute__((constructor)) static void AppWiperInit(void) {
    // --- 1. Decide whether we are the target app ---
    g_isTargetApp = computeIsTargetApp();
    if (!g_isTargetApp) {
        // System process / unconfigured app: install nothing so we impose
        // zero overhead on the rest of the OS.
        return;
    }

    @autoreleasepool {
        // --- 2. Load the config plist ---
        loadConfig();
        if (!g_config) {
            NSLog(@"[AppWiper] no config for %@ — hooks inactive", g_targetBundleID);
            g_isTargetApp = NO; // nothing to spoof
            return;
        }

        // --- 3. Resolve the full spoof identity ---
        resolveSpoofIdentity();

        NSLog(@"[AppWiper] === active for %@ | machine=%@ ===",
              g_targetBundleID, g_spoofMachine);

        // --- 4. IDFA ---
        Class asmgr = objc_getClass("ASIdentifierManager");
        if (asmgr) {
            installMethodHook(asmgr, "advertisingIdentifier",
                              (IMP)hook_advertisingIdentifier,
                              (IMP *)&orig_advertisingIdentifier);
        }

        // --- 5. UIDevice ---
        Class uid = objc_getClass("UIDevice");
        if (uid) {
            installMethodHook(uid, "identifierForVendor",
                              (IMP)hook_uidev_idfv,
                              (IMP *)&orig_uidev_idfv);
            installMethodHook(uid, "name",
                              (IMP)hook_uidev_name,
                              (IMP *)&orig_uidev_name);
            installMethodHook(uid, "systemVersion",
                              (IMP)hook_uidev_systemVersion,
                              (IMP *)&orig_uidev_sysver);
            installMethodHook(uid, "model",
                              (IMP)hook_uidev_model,
                              (IMP *)&orig_uidev_model);
            installMethodHook(uid, "localizedModel",
                              (IMP)hook_uidev_localizedModel,
                              (IMP *)&orig_uidev_locmodel);
        }

        // --- 6. IOKit IORegistryEntryCreateCFProperty ---
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (iokit) {
            void *sym = dlsym(iokit, "IORegistryEntryCreateCFProperty");
            if (sym) {
                MSHookFunction(sym,
                                (void *)hook_IORegistryEntryCreateCFProperty,
                                (void **)&orig_IORegistryEntryCreateCFProperty);
            }
        }

        // --- 7. sysctlbyname ---
        MSHookFunction((void *)sysctlbyname,
                       (void *)hook_sysctlbyname,
                       (void **)&orig_sysctlbyname);

        // --- 8. UIScreen ---
        Class screen = objc_getClass("UIScreen");
        if (screen) {
            installMethodHook(screen, "bounds",
                              (IMP)hook_screen_bounds,
                              (IMP *)&orig_screen_bounds);
            installMethodHook(screen, "scale",
                              (IMP)hook_screen_scale,
                              (IMP *)&orig_screen_scale);
            installMethodHook(screen, "nativeScale",
                              (IMP)hook_screen_nativeScale,
                              (IMP *)&orig_screen_nativeScale);
            installMethodHook(screen, "maximumFramesPerSecond",
                              (IMP)hook_screen_maxFPS,
                              (IMP *)&orig_screen_maxFPS);
        }

        // --- 9. CLLocationManager ---
        Class clm = objc_getClass("CLLocationManager");
        if (clm) {
            installMethodHook(clm, "location",
                              (IMP)hook_clmgr_location,
                              (IMP *)&orig_clmgr_location);
        }

        // --- 10. CoreTelephony / CTCarrier ---
        Class carrier = objc_getClass("CTCarrier");
        if (carrier) {
            installMethodHook(carrier, "carrierName",
                              (IMP)hook_carrier_carrierName,
                              (IMP *)&orig_carrier_carrierName);
            installMethodHook(carrier, "mobileCountryCode",
                              (IMP)hook_carrier_mcc,
                              (IMP *)&orig_carrier_mobileCC);
            installMethodHook(carrier, "mobileNetworkCode",
                              (IMP)hook_carrier_mnc,
                              (IMP *)&orig_carrier_mobileNC);
            installMethodHook(carrier, "isoCountryCode",
                              (IMP)hook_carrier_iso,
                              (IMP *)&orig_carrier_isoCountryCode);
            installMethodHook(carrier, "allowsVOIP",
                              (IMP)hook_carrier_voip,
                              (IMP *)&orig_carrier_allowsVOIP);
        }
        Class ctni = objc_getClass("CTTelephonyNetworkInfo");
        if (ctni) {
            installMethodHook(ctni, "currentRadioAccessTechnology",
                              (IMP)hook_ctni_radioTech,
                              (IMP *)&orig_ctni_radioTech);
        }

        // --- 11. SCNetworkReachabilityGetFlags ---
        void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (sc) {
            void *sym = dlsym(sc, "SCNetworkReachabilityGetFlags");
            if (sym) {
                MSHookFunction(sym,
                                (void *)hook_SCNetworkReachabilityGetFlags,
                                (void **)&orig_SCNetworkReachabilityGetFlags);
            }
        }

        // --- 12. Wi-Fi CN* helpers ---
        void *cnc = dlopen("/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN", RTLD_LAZY);
        // The CaptiveNetwork symbols actually live in SystemConfiguration.
        void *cnsym1 = dlsym(sc ? sc : RTLD_DEFAULT, "CNCopySupportedInterfaces");
        void *cnsym2 = dlsym(sc ? sc : RTLD_DEFAULT, "CNCopyCurrentNetworkInfo");
        if (cnsym1) {
            MSHookFunction(cnsym1,
                           (void *)hook_CNcopySupportedInterfaces,
                           (void **)&orig_CNcopySupportedInterfaces);
        }
        if (cnsym2) {
            MSHookFunction(cnsym2,
                           (void *)hook_CNcopyCurrentNetworkInfo,
                           (void **)&orig_CNcopyCurrentNetworkInfo);
        }
        (void)cnc;

        // --- 13. Jailbreak-detection bypass (stat / lstat / access / fopen) ---
        MSHookFunction((void *)stat,
                       (void *)hook_stat,
                       (void **)&orig_stat);
        MSHookFunction((void *)lstat,
                       (void *)hook_lstat,
                       (void **)&orig_lstat);
        MSHookFunction((void *)access,
                       (void *)hook_access,
                       (void **)&orig_access);
        MSHookFunction((void *)fopen,
                       (void *)hook_fopen,
                       (void **)&orig_fopen);

        // --- 14. StoreKit addPayment: ---
        Class queue = objc_getClass("SKPaymentQueue");
        if (queue) {
            installMethodHook(queue, "addPayment:",
                              (IMP)hook_addPayment,
                              (IMP *)&orig_addPayment);
        }

        // --- 15. NSUserDefaults stringForKey: ---
        Class ud = objc_getClass("NSUserDefaults");
        if (ud) {
            installMethodHook(ud, "stringForKey:",
                              (IMP)hook_stringForKey,
                              (IMP *)&orig_stringForKey);
        }

        // --- Optional: wire the LocationFaker helper if configured ---
        double lat = [cfgValue(@"spoof_lat") doubleValue];
        double lon = [cfgValue(@"spoof_lon") doubleValue];
        double rad = [cfgValue(@"spoof_radius_m") doubleValue];
        if (lat != 0.0 || lon != 0.0) {
            [LocationFaker setupLocationFakerWithLat:lat lon:lon radiusKm:rad / 1000.0];
        }

        // --- Optional: apply the NetworkFaker profile if present ---
        if (cfgBool(@"NetworkFaking")) {
            [NetworkFaker applyNetworkConfig:g_config];
        }

        NSLog(@"[AppWiper] === all hooks installed for %@ ===", g_targetBundleID);
    }
}
