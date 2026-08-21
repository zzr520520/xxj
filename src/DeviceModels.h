//
//  DeviceModels.h
//  AppWiper v2.08
//
//  Static hardware-parameter matrix for every iPhone from the iPhone 6
//  family through the iPhone 16 Pro Max.  Resolves a raw `hw.machine`
//  identifier (e.g. "iPhone7,2") into a fully-populated device descriptor
//  covering CPU, memory, display geometry, refresh rate, and Metal/GPU
//  family so the runtime hooks can impersonate any supported handset.
//
//  Fields per model
//  ----------------
//    marketing_name  Human-readable model, e.g. "iPhone 13 Pro Max".
//    hw_machine      sysctlbyname("hw.machine") value, e.g. "iPhone14,3".
//    hw_model        Board / hardware-model code (IORegistry "model"), e.g. "N61".
//    soc             Apple silicon generation, e.g. "A15".
//    cpu_cores       Logical CPU core count (sysctl hw.ncpu).
//    physmem         Physical RAM in bytes (sysctl hw.memsize).
//    pt_width        Native interface width in points (UIScreen bounds).
//    pt_height       Native interface height in points.
//    px_width        Physical pixel width.
//    px_height       Physical pixel height.
//    scale           UIScreen scale factor (2.0 / 3.0).
//    max_fps         maximumFramesPerSecond (60 or 120 ProMotion).
//    metal_family    MTLDevice.name family, e.g. "Apple15".
//    gpu_name        GPU core identifier, e.g. "G15".
//
//  Built for Theos with -fobjc-arc.
//

#import <Foundation/Foundation.h>

@interface DeviceModels : NSObject

// Look up the descriptor for a raw machine identifier (e.g. "iPhone14,3").
// Returns nil when the identifier is unknown to this matrix.
+ (NSDictionary *)deviceInfoForMachine:(NSString *)machine;

// All machine identifiers known to this matrix (unsorted insertion order).
+ (NSArray<NSString *> *)allMachineIdentifiers;

// Resolve marketing name -> machine identifier (reverse lookup).
+ (NSString *)machineForMarketingName:(NSString *)name;

@end

// ---------------------------------------------------------------------------
//  Implementation
//
//  The implementation lives in this header because the tweak is compiled as a
//  single translation unit (Hooks.m is the only .m that imports it), so there
//  is no risk of duplicate symbols.  The backing dictionary is built once via
//  dispatch_once and keyed by the hw_machine string.
// ---------------------------------------------------------------------------
@implementation DeviceModels

// Build (once) and return the immutable model database.
+ (NSDictionary *)_modelDatabase {
    static NSDictionary *db = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{

        // Physmem constants (bytes): 1G / 2G / 3G / 4G / 6G / 8G.
        // Commonly reported by sysctlbyname("hw.memsize").
        #define P_1G  1073741824U
        #define P_2G  2147483648U
        #define P_3G  3221225472U
        #define P_4G  4294967296U
        #define P_6G  6442450944U
        #define P_8G  8589934592U

        db = @{

            // ---- iPhone 6 / 6 Plus (A8, 1 GB, 60 Hz) ----
            @"iPhone7,2": @{@"marketing_name":@"iPhone 6",@"hw_machine":@"iPhone7,2",@"hw_model":@"N61",@"soc":@"A8",
                @"cpu_cores":@2,@"physmem":@(P_1G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple4",@"gpu_name":@"G6430"},
            @"iPhone7,1": @{@"marketing_name":@"iPhone 6 Plus",@"hw_machine":@"iPhone7,1",@"hw_model":@"N56",@"soc":@"A8",
                @"cpu_cores":@2,@"physmem":@(P_1G),@"pt_width":@414,@"pt_height":@736,@"px_width":@1080,@"px_height":@1920,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple4",@"gpu_name":@"GX6450"},

            // ---- iPhone 6s / 6s Plus / SE1 (A9, 2 GB, 60 Hz) ----
            @"iPhone8,1": @{@"marketing_name":@"iPhone 6s",@"hw_machine":@"iPhone8,1",@"hw_model":@"N71",@"soc":@"A9",
                @"cpu_cores":@2,@"physmem":@(P_2G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple7",@"gpu_name":@"GT7600"},
            @"iPhone8,2": @{@"marketing_name":@"iPhone 6s Plus",@"hw_machine":@"iPhone8,2",@"hw_model":@"N66",@"soc":@"A9",
                @"cpu_cores":@2,@"physmem":@(P_2G),@"pt_width":@414,@"pt_height":@736,@"px_width":@1080,@"px_height":@1920,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple7",@"gpu_name":@"GT7600"},
            @"iPhone8,4": @{@"marketing_name":@"iPhone SE (1st generation)",@"hw_machine":@"iPhone8,4",@"hw_model":@"N69",@"soc":@"A9",
                @"cpu_cores":@2,@"physmem":@(P_2G),@"pt_width":@320,@"pt_height":@568,@"px_width":@640,@"px_height":@1136,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple7",@"gpu_name":@"GT7600"},

            // ---- iPhone 7 / 7 Plus (A10 Fusion, 2/3 GB, 60 Hz) ----
            @"iPhone9,1": @{@"marketing_name":@"iPhone 7",@"hw_machine":@"iPhone9,1",@"hw_model":@"D10",@"soc":@"A10",
                @"cpu_cores":@4,@"physmem":@(P_2G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple7",@"gpu_name":@"GT7600 Plus"},
            @"iPhone9,2": @{@"marketing_name":@"iPhone 7 Plus",@"hw_machine":@"iPhone9,2",@"hw_model":@"D11",@"soc":@"A10",
                @"cpu_cores":@4,@"physmem":@(P_3G),@"pt_width":@414,@"pt_height":@736,@"px_width":@1080,@"px_height":@1920,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple7",@"gpu_name":@"GT7600 Plus"},

            // ---- iPhone 8 / 8 Plus / X (A11 Bionic, 2/3 GB, 60 Hz) ----
            @"iPhone10,1": @{@"marketing_name":@"iPhone 8",@"hw_machine":@"iPhone10,1",@"hw_model":@"D20",@"soc":@"A11",
                @"cpu_cores":@6,@"physmem":@(P_2G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11"},
            @"iPhone10,2": @{@"marketing_name":@"iPhone 8 Plus",@"hw_machine":@"iPhone10,2",@"hw_model":@"D21",@"soc":@"A11",
                @"cpu_cores":@6,@"physmem":@(P_3G),@"pt_width":@414,@"pt_height":@736,@"px_width":@1080,@"px_height":@1920,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11"},
            @"iPhone10,3": @{@"marketing_name":@"iPhone X",@"hw_machine":@"iPhone10,3",@"hw_model":@"D22",@"soc":@"A11",
                @"cpu_cores":@6,@"physmem":@(P_3G),@"pt_width":@375,@"pt_height":@812,@"px_width":@1125,@"px_height":@2436,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11"},

            // ---- iPhone XR / XS / XS Max (A12 Bionic, 3/4 GB, 60 Hz) ----
            @"iPhone11,8": @{@"marketing_name":@"iPhone XR",@"hw_machine":@"iPhone11,8",@"hw_model":@"N84",@"soc":@"A12",
                @"cpu_cores":@6,@"physmem":@(P_3G),@"pt_width":@414,@"pt_height":@896,@"px_width":@828,@"px_height":@1792,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11P"},
            @"iPhone11,2": @{@"marketing_name":@"iPhone XS",@"hw_machine":@"iPhone11,2",@"hw_model":@"D32",@"soc":@"A12",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@375,@"pt_height":@812,@"px_width":@1125,@"px_height":@2436,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11P"},
            @"iPhone11,4": @{@"marketing_name":@"iPhone XS Max",@"hw_machine":@"iPhone11,4",@"hw_model":@"D33",@"soc":@"A12",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@414,@"pt_height":@896,@"px_width":@1242,@"px_height":@2688,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple11",@"gpu_name":@"G11P"},

            // ---- iPhone 11 / 11 Pro / 11 Pro Max / SE2 (A13, 3/4 GB, 60 Hz) ----
            @"iPhone12,1": @{@"marketing_name":@"iPhone 11",@"hw_machine":@"iPhone12,1",@"hw_model":@"N104",@"soc":@"A13",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@414,@"pt_height":@896,@"px_width":@828,@"px_height":@1792,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple13",@"gpu_name":@"G13P"},
            @"iPhone12,3": @{@"marketing_name":@"iPhone 11 Pro",@"hw_machine":@"iPhone12,3",@"hw_model":@"D201",@"soc":@"A13",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@375,@"pt_height":@812,@"px_width":@1125,@"px_height":@2436,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple13",@"gpu_name":@"G13P"},
            @"iPhone12,5": @{@"marketing_name":@"iPhone 11 Pro Max",@"hw_machine":@"iPhone12,5",@"hw_model":@"D211",@"soc":@"A13",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@414,@"pt_height":@896,@"px_width":@1242,@"px_height":@2688,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple13",@"gpu_name":@"G13P"},
            @"iPhone12,8": @{@"marketing_name":@"iPhone SE (2nd generation)",@"hw_machine":@"iPhone12,8",@"hw_model":@"D229",@"soc":@"A13",
                @"cpu_cores":@6,@"physmem":@(P_3G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple13",@"gpu_name":@"G13P"},

            // ---- iPhone 12 series (A14, 4/6 GB, 60 Hz) ----
            @"iPhone13,1": @{@"marketing_name":@"iPhone 12 mini",@"hw_machine":@"iPhone13,1",@"hw_model":@"D52",@"soc":@"A14",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@360,@"pt_height":@780,@"px_width":@1080,@"px_height":@2340,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple14",@"gpu_name":@"G14P"},
            @"iPhone13,2": @{@"marketing_name":@"iPhone 12",@"hw_machine":@"iPhone13,2",@"hw_model":@"D53",@"soc":@"A14",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@390,@"pt_height":@844,@"px_width":@1170,@"px_height":@2532,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple14",@"gpu_name":@"G14P"},
            @"iPhone13,3": @{@"marketing_name":@"iPhone 12 Pro",@"hw_machine":@"iPhone13,3",@"hw_model":@"D54",@"soc":@"A14",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@390,@"pt_height":@844,@"px_width":@1170,@"px_height":@2532,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple14",@"gpu_name":@"G14P"},
            @"iPhone13,4": @{@"marketing_name":@"iPhone 12 Pro Max",@"hw_machine":@"iPhone13,4",@"hw_model":@"D54p",@"soc":@"A14",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@428,@"pt_height":@926,@"px_width":@1284,@"px_height":@2778,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple14",@"gpu_name":@"G14P"},

            // ---- iPhone 13 series (A15, 4/6 GB, 120 Hz ProMotion on Pro) ----
            @"iPhone14,4": @{@"marketing_name":@"iPhone 13 mini",@"hw_machine":@"iPhone14,4",@"hw_model":@"D69",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@360,@"pt_height":@780,@"px_width":@1080,@"px_height":@2340,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G15"},
            @"iPhone14,5": @{@"marketing_name":@"iPhone 13",@"hw_machine":@"iPhone14,5",@"hw_model":@"D63",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@390,@"pt_height":@844,@"px_width":@1170,@"px_height":@2532,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G15"},
            @"iPhone14,2": @{@"marketing_name":@"iPhone 13 Pro",@"hw_machine":@"iPhone14,2",@"hw_model":@"D64",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@390,@"pt_height":@844,@"px_width":@1170,@"px_height":@2532,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple15",@"gpu_name":@"G15"},
            @"iPhone14,3": @{@"marketing_name":@"iPhone 13 Pro Max",@"hw_machine":@"iPhone14,3",@"hw_model":@"D64p",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@428,@"pt_height":@926,@"px_width":@1284,@"px_height":@2778,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple15",@"gpu_name":@"G15"},

            // ---- iPhone SE3 / 14 / 14 Plus (A15, 3/6 GB, 60 Hz) ----
            @"iPhone14,6": @{@"marketing_name":@"iPhone SE (3rd generation)",@"hw_machine":@"iPhone14,6",@"hw_model":@"D109",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_4G),@"pt_width":@375,@"pt_height":@667,@"px_width":@750,@"px_height":@1334,
                @"scale":@2.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G15"},
            @"iPhone14,7": @{@"marketing_name":@"iPhone 14",@"hw_machine":@"iPhone14,7",@"hw_model":@"D27",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@390,@"pt_height":@844,@"px_width":@1170,@"px_height":@2532,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G15"},
            @"iPhone14,8": @{@"marketing_name":@"iPhone 14 Plus",@"hw_machine":@"iPhone14,8",@"hw_model":@"D28",@"soc":@"A15",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@428,@"pt_height":@926,@"px_width":@1284,@"px_height":@2778,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G15"},

            // ---- iPhone 14 Pro / Pro Max (A16, 6 GB, 120 Hz ProMotion) ----
            @"iPhone15,2": @{@"marketing_name":@"iPhone 14 Pro",@"hw_machine":@"iPhone15,2",@"hw_model":@"D73",@"soc":@"A16",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@393,@"pt_height":@852,@"px_width":@1179,@"px_height":@2556,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple15",@"gpu_name":@"G16"},
            @"iPhone15,3": @{@"marketing_name":@"iPhone 14 Pro Max",@"hw_machine":@"iPhone15,3",@"hw_model":@"D74",@"soc":@"A16",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@430,@"pt_height":@932,@"px_width":@1290,@"px_height":@2796,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple15",@"gpu_name":@"G16"},

            // ---- iPhone 15 / 15 Plus (A16, 6 GB, 60 Hz) ----
            @"iPhone15,4": @{@"marketing_name":@"iPhone 15",@"hw_machine":@"iPhone15,4",@"hw_model":@"D37",@"soc":@"A16",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@393,@"pt_height":@852,@"px_width":@1179,@"px_height":@2556,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G16"},
            @"iPhone15,5": @{@"marketing_name":@"iPhone 15 Plus",@"hw_machine":@"iPhone15,5",@"hw_model":@"D38",@"soc":@"A16",
                @"cpu_cores":@6,@"physmem":@(P_6G),@"pt_width":@430,@"pt_height":@932,@"px_width":@1290,@"px_height":@2796,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple15",@"gpu_name":@"G16"},

            // ---- iPhone 15 Pro / Pro Max (A17 Pro, 8 GB, 120 Hz ProMotion) ----
            @"iPhone16,1": @{@"marketing_name":@"iPhone 15 Pro",@"hw_machine":@"iPhone16,1",@"hw_model":@"D83",@"soc":@"A17 Pro",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@393,@"pt_height":@852,@"px_width":@1179,@"px_height":@2556,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple17",@"gpu_name":@"G17"},
            @"iPhone16,2": @{@"marketing_name":@"iPhone 15 Pro Max",@"hw_machine":@"iPhone16,2",@"hw_model":@"D84",@"soc":@"A17 Pro",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@430,@"pt_height":@932,@"px_width":@1290,@"px_height":@2796,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple17",@"gpu_name":@"G17"},

            // ---- iPhone 16 / 16 Plus (A18, 8 GB, 60 Hz) ----
            @"iPhone17,3": @{@"marketing_name":@"iPhone 16",@"hw_machine":@"iPhone17,3",@"hw_model":@"D47",@"soc":@"A18",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@393,@"pt_height":@852,@"px_width":@1179,@"px_height":@2556,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple17",@"gpu_name":@"G18"},
            @"iPhone17,4": @{@"marketing_name":@"iPhone 16 Plus",@"hw_machine":@"iPhone17,4",@"hw_model":@"D48",@"soc":@"A18",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@430,@"pt_height":@932,@"px_width":@1290,@"px_height":@2796,
                @"scale":@3.0,@"max_fps":@60,@"metal_family":@"Apple17",@"gpu_name":@"G18"},

            // ---- iPhone 16 Pro / Pro Max (A18 Pro, 8 GB, 120 Hz ProMotion) ----
            @"iPhone17,1": @{@"marketing_name":@"iPhone 16 Pro",@"hw_machine":@"iPhone17,1",@"hw_model":@"D94",@"soc":@"A18 Pro",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@402,@"pt_height":@874,@"px_width":@2622,@"px_height":@1206,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple18",@"gpu_name":@"G18 Pro"},
            @"iPhone17,2": @{@"marketing_name":@"iPhone 16 Pro Max",@"hw_machine":@"iPhone17,2",@"hw_model":@"D97",@"soc":@"A18 Pro",
                @"cpu_cores":@6,@"physmem":@(P_8G),@"pt_width":@440,@"pt_height":@956,@"px_width":@2868,@"px_height":@1320,
                @"scale":@3.0,@"max_fps":@120,@"metal_family":@"Apple18",@"gpu_name":@"G18 Pro"},
        };

        #undef P_1G
        #undef P_2G
        #undef P_3G
        #undef P_4G
        #undef P_6G
        #undef P_8G
    });
    return db;
}

// Public: resolve machine identifier -> descriptor dictionary.
+ (NSDictionary *)deviceInfoForMachine:(NSString *)machine {
    if (!machine || machine.length == 0) {
        return nil;
    }
    NSDictionary *db = [self _modelDatabase];
    NSDictionary *info = db[machine];
    if (!info) {
        NSLog(@"[AppWiper] DeviceModels: unknown machine %@", machine);
    }
    return info;
}

// Public: all known machine identifiers in insertion order.
+ (NSArray<NSString *> *)allMachineIdentifiers {
    return [[self _modelDatabase] allKeys];
}

// Public: reverse lookup marketing name -> machine identifier.
+ (NSString *)machineForMarketingName:(NSString *)name {
    if (!name || name.length == 0) {
        return nil;
    }
    NSDictionary *db = [self _modelDatabase];
    __block NSString *result = nil;
    [db enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *info, BOOL *stop) {
        if ([name isEqualToString:info[@"marketing_name"]]) {
            result = key;
            *stop = YES;
        }
    }];
    return result;
}

@end
