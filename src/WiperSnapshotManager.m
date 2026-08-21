//
//  WiperSnapshotManager.m
//  AppWiper v2.08 — config snapshot save/load/list/delete/apply.
//  Built for Theos with -fobjc-arc.
//

#import "WiperSnapshotManager.h"
#import "WiperHelper.h"

@implementation WiperSnapshotManager

// /var/mobile/Library/Preferences/AppWiper_Snapshots/<bundleID>/
+ (NSString *)snapshotDirForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    return [@"/var/mobile/Library/Preferences/AppWiper_Snapshots"
                stringByAppendingPathComponent:bundleID];
}

// List saved snapshot names (without .plist extension).
+ (NSArray<NSString *> *)savedSnapshotsForBundleID:(NSString *)bundleID {
    NSString *dir = [self snapshotDirForBundleID:bundleID];
    if (!dir) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return @[];
    NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *e in entries) {
        if ([e hasSuffix:@".plist"])
            [names addObject:[e stringByDeletingPathExtension]];
    }
    return [names copy];
}

// Load a named snapshot as a dictionary.
+ (NSDictionary *)loadSnapshot:(NSString *)snapshotName
                     forBundleID:(NSString *)bundleID {
    if (!snapshotName.length || !bundleID.length) return nil;
    NSString *path = [[self snapshotDirForBundleID:bundleID]
        stringByAppendingPathComponent:[snapshotName stringByAppendingPathExtension:@"plist"]];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

// Copy the current config file into a new named snapshot.
+ (BOOL)saveCurrentConfigAsSnapshot:(NSString *)snapshotName
                         forBundleID:(NSString *)bundleID {
    if (!snapshotName.length || !bundleID.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [WiperHelper getConfigPathForBundleID:bundleID];
    if (!src || ![fm fileExistsAtPath:src]) return NO;
    NSString *dir = [self snapshotDirForBundleID:bundleID];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:
                        [snapshotName stringByAppendingPathExtension:@"plist"]];
    [fm removeItemAtPath:dst error:nil];
    return [fm copyItemAtPath:src toPath:dst error:nil];
}

// Delete a named snapshot.
+ (BOOL)deleteSnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    if (!snapshotName.length || !bundleID.length) return NO;
    NSString *path = [[self snapshotDirForBundleID:bundleID]
        stringByAppendingPathComponent:[snapshotName stringByAppendingPathExtension:@"plist"]];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// Copy a snapshot over the current config file (replaces live config).
+ (BOOL)applySnapshot:(NSString *)snapshotName forBundleID:(NSString *)bundleID {
    if (!snapshotName.length || !bundleID.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [[self snapshotDirForBundleID:bundleID]
        stringByAppendingPathComponent:[snapshotName stringByAppendingPathExtension:@"plist"]];
    if (![fm fileExistsAtPath:src]) return NO;
    NSString *dst = [WiperHelper getConfigPathForBundleID:bundleID];
    if (!dst) return NO;
    [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dst error:nil];
    return [fm copyItemAtPath:src toPath:dst error:nil];
}

@end
