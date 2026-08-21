//
//  NetworkFaker.m
//  AppWiper v2.08
//
//  Independent per-app network identity faker.  Writes a resolved carrier
//  / reachability profile into the target app's AppWiper config plist; the
//  tweak's CoreTelephony / SCNetworkReachability hooks read this profile
//  at runtime to spoof the network environment.
//
//  Seven preset modes are supported:
//    NO_SIM           — no SIM (carrier / MCC / MNC / radioTech all nil)
//    AIRPLANE_MODE    — everything nil, reachability flags = 0
//    WIFI_ONLY        — carrier nil, flags = Reachable
//    CHINA_MOBILE     — 中国移动, MCC 460, MNC 00, NRNSA
//    CHINA_UNICOM     — 中国联通, MCC 460, MNC 01
//    CHINA_TELECOM    — 中国电信, MCC 460, MNC 11
//    CHINA_BROADNET   — 中国广电, MCC 460, MNC 15, NR
//
//  Built for Theos with -fobjc-arc.
//

#import "NetworkFaker.h"

#import <Foundation/Foundation.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dispatch/dispatch.h>
#import "WiperHelper.h"

// ---------------------------------------------------------------------------
//  Configuration plist keys
// ---------------------------------------------------------------------------
// Keys written into the per-app AppWiper_<bundleID>.plist.  The runtime
// hooks inspect these to decide what network values to report.
static NSString *const kKeyBundleID        = @"bundleID";
static NSString *const kKeyMode            = @"mode";
static NSString *const kKeyNetworkFaking   = @"NetworkFaking";
static NSString *const kKeyCarrierName     = @"NetworkCarrierName";
static NSString *const kKeyMCC             = @"NetworkMCC";
static NSString *const kKeyMNC             = @"NetworkMNC";
static NSString *const kKeyRadioTech       = @"NetworkRadioTech";
static NSString *const kKeyReachabilityFlags = @"NetworkReachabilityFlags";

// ---------------------------------------------------------------------------
//  Mode name constants (as stored in the plist under kKeyMode)
// ---------------------------------------------------------------------------
NSString *const NetworkFakerModeNoSIM         = @"NO_SIM";
NSString *const NetworkFakerModeAirplane      = @"AIRPLANE_MODE";
NSString *const NetworkFakerModeWiFiOnly      = @"WIFI_ONLY";
NSString *const NetworkFakerModeChinaMobile   = @"CHINA_MOBILE";
NSString *const NetworkFakerModeChinaUnicom   = @"CHINA_UNICOM";
NSString *const NetworkFakerModeChinaTelecom  = @"CHINA_TELECOM";
NSString *const NetworkFakerModeChinaBroadnet = @"CHINA_BROADNET";

// ---------------------------------------------------------------------------
//  Static faking state (visible to the in-process hooks)
// ---------------------------------------------------------------------------
static BOOL       sNetworkFaking    = NO;   // currently spoofing?
static NSString  *sCurrentMode      = nil;  // last applied mode name
static NSString  *sCurrentBundleID  = nil;  // target bundle identifier

// All network-related keys that belong to a faker profile, used for bulk
// removal when resetting to default.
static NSArray<NSString *> *networkProfileKeys(void) {
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            kKeyNetworkFaking,
            kKeyMode,
            kKeyCarrierName,
            kKeyMCC,
            kKeyMNC,
            kKeyRadioTech,
            kKeyReachabilityFlags,
        ];
    });
    return keys;
}

// ---------------------------------------------------------------------------
//  Implementation
// ---------------------------------------------------------------------------
@implementation NetworkFaker

#pragma mark - Apply Config

//
// applyNetworkConfig:
//
// Accepts a dictionary describing the desired network persona for a target
// app and persists it into the app's AppWiper config plist so the tweak
// hooks can read it at runtime.
//
// Expected keys in `config`:
//   @ "bundleID"  — target app bundle identifier (required)
//   @ "mode"      — one of the seven NetworkFakerMode* constants
//
// If individual carrier keys (CarrierName / MCC / MNC / RadioTech /
// ReachabilityFlags) are present they override the mode defaults.
//
+ (void)applyNetworkConfig:(NSDictionary *)config {
    if (!config || config.count == 0) {
        NSLog(@"[AppWiper] NetworkFaker: empty config, ignoring");
        return;
    }

    NSString *bundleID = config[kKeyBundleID];
    if (!bundleID || bundleID.length == 0) {
        NSLog(@"[AppWiper] NetworkFaker: missing bundleID in config");
        return;
    }

    NSString *mode = config[kKeyMode];
    if (!mode || mode.length == 0) {
        NSLog(@"[AppWiper] NetworkFaker: missing mode, defaulting to NO_SIM");
        mode = NetworkFakerModeNoSIM;
    }

    // Resolve the mode into a profile dictionary, then apply caller overrides.
    NSMutableDictionary *profile = [NSMutableDictionary dictionaryWithDictionary:
                                        [self profileForMode:mode]];

    // Allow the caller to override any individual field.
    NSArray *overrideKeys = @[
        kKeyCarrierName, kKeyMCC, kKeyMNC,
        kKeyRadioTech, kKeyReachabilityFlags,
    ];
    for (NSString *key in overrideKeys) {
        id val = config[key];
        if (val && val != [NSNull null]) {
            profile[key] = val;
        }
    }

    // Mark the profile as actively faking.
    profile[kKeyNetworkFaking] = @(YES);
    profile[kKeyMode] = mode;

    // Persist into the per-app config plist (merge with any existing keys).
    NSString *plistPath = [self configPathForBundleID:bundleID];
    [self writeProfile:profile intoPlistAtPath:plistPath];

    // Update static state for the hooks to query.
    @synchronized([NetworkFaker class]) {
        sNetworkFaking = YES;
        sCurrentMode = mode;
        sCurrentBundleID = bundleID;
    }

    NSLog(@"[AppWiper] NetworkFaker: applied mode %@ for %@", mode, bundleID);
}

#pragma mark - Reset to Default

//
// resetToDefault
//
// Clears the network faker profile from the currently-targeted app's
// config plist and resets the static faking state.
//
+ (void)resetToDefault {
    NSString *bundleID = nil;
    @synchronized([NetworkFaker class]) {
        bundleID = [sCurrentBundleID copy];
    }

    if (bundleID && bundleID.length > 0) {
        NSString *plistPath = [self configPathForBundleID:bundleID];
        [self removeNetworkProfileFromPlistAtPath:plistPath];
        NSLog(@"[AppWiper] NetworkFaker: reset default for %@", bundleID);
    } else {
        NSLog(@"[AppWiper] NetworkFaker: no active target to reset");
    }

    @synchronized([NetworkFaker class]) {
        sNetworkFaking = NO;
        sCurrentMode = nil;
        sCurrentBundleID = nil;
    }
}

#pragma mark - Query State

//
// isFaking
//
// Returns whether a network persona is currently active.
//
+ (BOOL)isFaking {
    @synchronized([NetworkFaker class]) {
        return sNetworkFaking;
    }
}

#pragma mark - Mode Profile Resolution

//
// profileForMode:
//
// Maps a mode name constant to a carrier / MCC / MNC / radio-tech /
// reachability-flags dictionary.  nil values are represented by the key
// being absent from the dictionary, so the hooks can distinguish
// "not present" from "explicitly nil".
//
+ (NSDictionary *)profileForMode:(NSString *)mode {
    // Convenience macros for building profiles concisely.
    #define PROF(carrier, mcc, mnc, radio, flags) \
        @{ \
            kKeyCarrierName: (carrier ?: [NSNull null]), \
            kKeyMCC:         (mcc ?: [NSNull null]), \
            kKeyMNC:         (mnc ?: [NSNull null]), \
            kKeyRadioTech:   (radio ?: [NSNull null]), \
            kKeyReachabilityFlags: @(flags), \
        }

    if ([mode isEqualToString:NetworkFakerModeNoSIM]) {
        // No SIM: carrier, MCC, MNC, radioTech all nil.
        return PROF(nil, nil, nil, nil, 0);
    }

    if ([mode isEqualToString:NetworkFakerModeAirplane]) {
        // Airplane mode: everything nil, flags = 0 (unreachable).
        return PROF(nil, nil, nil, nil, 0);
    }

    if ([mode isEqualToString:NetworkFakerModeWiFiOnly]) {
        // Wi-Fi only: no carrier info, but the network is reachable.
        return PROF(nil, nil, nil, nil, kSCNetworkReachabilityFlagsReachable);
    }

    if ([mode isEqualToString:NetworkFakerModeChinaMobile]) {
        // 中国移动: MCC 460, MNC 00, NR-NSA.
        return PROF(@"中国移动", @"460", @"00",
                    CTRadioAccessTechnologyNRNSA,
                    kSCNetworkReachabilityFlagsReachable);
    }

    if ([mode isEqualToString:NetworkFakerModeChinaUnicom]) {
        // 中国联通: MCC 460, MNC 01.
        return PROF(@"中国联通", @"460", @"01",
                    CTRadioAccessTechnologyNRNSA,
                    kSCNetworkReachabilityFlagsReachable);
    }

    if ([mode isEqualToString:NetworkFakerModeChinaTelecom]) {
        // 中国电信: MCC 460, MNC 11.
        return PROF(@"中国电信", @"460", @"11",
                    CTRadioAccessTechnologyNRNSA,
                    kSCNetworkReachabilityFlagsReachable);
    }

    if ([mode isEqualToString:NetworkFakerModeChinaBroadnet]) {
        // 中国广电: MCC 460, MNC 15, NR.
        return PROF(@"中国广电", @"460", @"15",
                    CTRadioAccessTechnologyNR,
                    kSCNetworkReachabilityFlagsReachable);
    }

    // Unknown mode — default to a reachable-but-blank profile.
    NSLog(@"[AppWiper] NetworkFaker: unknown mode %@, using default", mode);
    return PROF(nil, nil, nil, nil, kSCNetworkReachabilityFlagsReachable);

    #undef PROF
}

#pragma mark - Plist I/O Helpers

//
// configPathForBundleID:
//
// Returns the per-app AppWiper config plist path.
//
+ (NSString *)configPathForBundleID:(NSString *)bundleID {
    return [WiperHelper getConfigPathForBundleID:bundleID];
}

//
// writeProfile:intoPlistAtPath:
//
// Merge the given profile dictionary into the config plist, creating the
// file if it does not exist.
//
+ (void)writeProfile:(NSDictionary *)profile
     intoPlistAtPath:(NSString *)plistPath {
    if (!plistPath || plistPath.length == 0) {
        return;
    }

    // Load existing config (if any) and merge.
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (existing) {
            [config addEntriesFromDictionary:existing];
        }
    }

    // Apply the profile on top of existing config.
    [config addEntriesFromDictionary:profile];

    // Ensure the parent directory exists.
    NSString *parent = [plistPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:parent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[AppWiper] NetworkFaker: mkdir failed: %@",
              dirError.localizedDescription);
    }

    // Write atomically so a crash mid-write does not corrupt the file.
    [config writeToFile:plistPath atomically:YES];
}

//
// removeNetworkProfileFromPlistAtPath:
//
// Strip every network-faker key from the config plist, leaving any other
// AppWiper settings untouched.
//
+ (void)removeNetworkProfileFromPlistAtPath:(NSString *)plistPath {
    if (!plistPath || plistPath.length == 0) {
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        return;
    }

    NSMutableDictionary *config =
        [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!config) {
        return;
    }

    for (NSString *key in networkProfileKeys()) {
        [config removeObjectForKey:key];
    }

    [config writeToFile:plistPath atomically:YES];
}

@end
