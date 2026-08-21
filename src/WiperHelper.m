//
//  WiperHelper.m
//  AppWiper v2.08
//
//  Per-app full state wiper.  Built for Theos with -fobjc-arc.
//

#import "WiperHelper.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sqlite3.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <signal.h>
#import <sys/types.h>
#import <unistd.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <errno.h>

// Private: LSApplicationWorkspace for app container resolution.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (id)applicationForIdentifier:(NSString *)identifier;
@end

// ---------------------------------------------------------------------------
//  Internal helpers
// ---------------------------------------------------------------------------
@interface WiperHelper (Internal)
+ (NSURL *)dataContainerURLForBundleID:(NSString *)bundleID;
+ (NSURL *)scanDataContainerForBundleID:(NSString *)bundleID;
+ (NSURL *)bundleURLForBundleID:(NSString *)bundleID;
+ (NSString *)executableNameForBundleID:(NSString *)bundleID;
+ (pid_t)pidForBundleID:(NSString *)bundleID;
+ (void)killProcessForBundleID:(NSString *)bundleID;
+ (void)wipeUserDefaultsForBundleID:(NSString *)bundleID;
+ (void)wipeKeychainForBundleID:(NSString *)bundleID;
+ (void)wipeSandboxDirectoriesForBundleID:(NSString *)bundleID;
+ (BOOL)wipeTCCPermissionsForBundleID:(NSString *)bundleID;
+ (void)wipeCoreDuetAndBiomeForBundleID:(NSString *)bundleID;
+ (void)wipeAPNsTokenForBundleID:(NSString *)bundleID;
+ (void)wipeConfigFileForBundleID:(NSString *)bundleID;
+ (void)removeDirectoryAtPath:(NSString *)path;
+ (void)removeFileAtPath:(NSString *)path;
@end

// ---------------------------------------------------------------------------
//  Implementation
// ---------------------------------------------------------------------------
@implementation WiperHelper

#pragma mark - Config Path

// /var/mobile/Library/Preferences/AppWiper_<bundleID>.plist
+ (NSString *)getConfigPathForBundleID:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) {
        return nil;
    }
    NSString *fileName = [NSString stringWithFormat:@"AppWiper_%@.plist", bundleID];
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:fileName];
}

#pragma mark - Full Wipe Orchestrator

//
// performFullWipeForBundleID:
//   1. Force-kill the process.
//   2. Clear NSUserDefaults persistent domain.
//   3. Delete every keychain item owned by the app.
//   4. Deep-clean the sandbox data container.
//   5. Revoke TCC privacy authorisations.
//   6. Remove CoreDuet / Biome traces.
//   7. Reset the APNs push token.
//   8. Delete the AppWiper config file.
// Returns YES on a valid bundleID; individual failures are logged but do
// not abort the sequence.
//
+ (BOOL)performFullWipeForBundleID:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) {
        NSLog(@"[AppWiper] wipe: nil bundleID, aborting");
        return NO;
    }

    NSLog(@"[AppWiper] === Full wipe for %@ ===", bundleID);
    NSDate *start = [NSDate date];

    [self killProcessForBundleID:bundleID];
    usleep(150000); // let the kernel reap the process

    [self wipeUserDefaultsForBundleID:bundleID];
    [self wipeKeychainForBundleID:bundleID];
    [self wipeSandboxDirectoriesForBundleID:bundleID];
    [self wipeTCCPermissionsForBundleID:bundleID];
    [self wipeCoreDuetAndBiomeForBundleID:bundleID];
    [self wipeAPNsTokenForBundleID:bundleID];
    [self wipeConfigFileForBundleID:bundleID];

    NSLog(@"[AppWiper] === Wipe for %@ done in %.2fs ===",
          bundleID, -[start timeIntervalSinceNow]);
    return YES;
}

@end

// ---------------------------------------------------------------------------
//  Internal category
// ---------------------------------------------------------------------------
@implementation WiperHelper (Internal)

#pragma mark - Container & Bundle Resolution

// Resolve the data-container URL via LSApplicationWorkspace, then fall back
// to scanning /var/mobile/Containers/Data/Application/.
+ (NSURL *)dataContainerURLForBundleID:(NSString *)bundleID {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (wsClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop
        if (workspace && [workspace respondsToSelector:@selector(applicationForIdentifier:)]) {
            id record = [workspace applicationForIdentifier:bundleID];
            if (record) {
                id val = [record valueForKey:@"dataContainerURL"];
                if ([val isKindOfClass:[NSURL class]]) return val;
                if ([val isKindOfClass:[NSString class]])
                    return [NSURL fileURLWithPath:val];
            }
        }
    }
    return [self scanDataContainerForBundleID:bundleID];
}

// Scan the data-container directory tree for a matching Metadata.plist.
+ (NSURL *)scanDataContainerForBundleID:(NSString *)bundleID {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return nil;

    for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *meta = [[root stringByAppendingPathComponent:entry]
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager/Metadata.plist"];
        if (![fm fileExistsAtPath:meta]) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *bid = d[@"MCMMetadataIdentifier"];
        if ([bid isEqualToString:bundleID])
            return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:entry]];
    }
    return nil;
}

// Resolve the .app bundle URL.
+ (NSURL *)bundleURLForBundleID:(NSString *)bundleID {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (wsClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop
        if (workspace && [workspace respondsToSelector:@selector(applicationForIdentifier:)]) {
            id record = [workspace applicationForIdentifier:bundleID];
            if (record) {
                id val = [record valueForKey:@"bundleURL"];
                if ([val isKindOfClass:[NSURL class]]) return val;
                if ([val isKindOfClass:[NSString class]])
                    return [NSURL fileURLWithPath:val];
            }
        }
    }
    // Fallback: scan known bundle roots for a matching Info.plist.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",
        @"/Applications",
    ];
    for (NSString *root in roots) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
        for (NSString *dir in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *appDir = [root stringByAppendingPathComponent:dir];
            for (NSString *entry in [fm contentsOfDirectoryAtPath:appDir error:nil]) {
                if (![entry hasSuffix:@".app"]) continue;
                NSString *appPath = [appDir stringByAppendingPathComponent:entry];
                NSDictionary *info =
                    [NSDictionary dictionaryWithContentsOfFile:
                        [appPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bid = info[@"CFBundleIdentifier"];
                if ([bid isEqualToString:bundleID])
                    return [NSURL fileURLWithPath:appPath];
            }
        }
    }
    return nil;
}

// Read CFBundleExecutable from the app's Info.plist.
+ (NSString *)executableNameForBundleID:(NSString *)bundleID {
    NSURL *url = [self bundleURLForBundleID:bundleID];
    if (!url) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [[url path] stringByAppendingPathComponent:@"Info.plist"]];
    return info[@"CFBundleExecutable"];
}

#pragma mark - 1. Process Kill

// Find the PID via libproc and SIGKILL it; fall back to killall -9.
+ (void)killProcessForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [1/8] Kill process: %@", bundleID);

    pid_t pid = [self pidForBundleID:bundleID];
    if (pid > 0) {
        NSLog(@"[AppWiper]   pid=%d, SIGKILL", pid);
        kill(pid, SIGKILL);
        return;
    }

    NSString *exec = [self executableNameForBundleID:bundleID];
    if (exec.length) {
        NSLog(@"[AppWiper]   killall -9 %@", exec);
        char *argv[] = {(char *)"/usr/bin/killall", "-9",
                        (char *)[exec UTF8String], NULL};
        pid_t child = 0;
        extern char **environ;
        posix_spawn(&child, "/usr/bin/killall", NULL, NULL, argv, environ);
        if (child > 0) waitpid(child, NULL, 0);
    }
}

// Use killall -9 fallback (libproc not available in iOS SDK).
+ (pid_t)pidForBundleID:(NSString *)bundleID {
    return 0;
}

#pragma mark - 2. NSUserDefaults

// Remove the persistent domain plus the on-disk plist.
+ (void)wipeUserDefaultsForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [2/8] NSUserDefaults: %@", bundleID);

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removePersistentDomainForName:bundleID];
    [ud synchronize];

    // Guarantee the preference plist is gone from the container.
    NSURL *container = [self dataContainerURLForBundleID:bundleID];
    if (container) {
        NSString *p = [[[[container path] stringByAppendingPathComponent:@"Library"]
                                                 stringByAppendingPathComponent:@"Preferences"]
                       stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        [self removeFileAtPath:p];
    }
}

#pragma mark - 3. Keychain

// Delete all keychain items whose access group matches the bundleID.
+ (void)wipeKeychainForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [3/8] Keychain: %@", bundleID);

    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity,
    ];

    for (id cls in classes) {
        // Pass A: blanket delete by direct access group.
        NSDictionary *direct = @{
            (__bridge id)kSecClass:           cls,
            (__bridge id)kSecAttrAccessGroup:  bundleID,
        };
        SecItemDelete((__bridge CFDictionaryRef)direct);

        // Pass B: enumerate and delete matching items.
        NSDictionary *q = @{
            (__bridge id)kSecClass:               cls,
            (__bridge id)kSecReturnAttributes:     @(YES),
            (__bridge id)kSecMatchLimit:          (__bridge id)kSecMatchLimitAll,
        };
        CFTypeRef result = NULL;
        OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        if (s != errSecSuccess || !result) continue;

        NSArray *items = (__bridge_transfer NSArray *)result;
        NSUInteger deleted = 0;

        for (NSDictionary *item in items) {
            NSString *ag = item[(__bridge id)kSecAttrAccessGroup];
            if (![ag isKindOfClass:[NSString class]] || ag.length == 0) continue;
            if (![ag hasSuffix:bundleID]) continue;

            NSMutableDictionary *del = [NSMutableDictionary dictionary];
            del[(__bridge id)kSecClass] = cls;
            NSArray *keys = @[
                (__bridge id)kSecAttrAccessGroup,
                (__bridge id)kSecAttrService,
                (__bridge id)kSecAttrAccount,
                (__bridge id)kSecAttrServer,
                (__bridge id)kSecAttrLabel,
                (__bridge id)kSecAttrGeneric,
                (__bridge id)kSecAttrCreationDate,
            ];
            for (id k in keys) {
                id v = item[k];
                if (v) del[k] = v;
            }
            if (SecItemDelete((__bridge CFDictionaryRef)del) == errSecSuccess)
                deleted++;
        }
        if (deleted) NSLog(@"[AppWiper]   deleted %lu items (%@)", (unsigned long)deleted, cls);
    }
}

#pragma mark - 4. Sandbox Directories

// Deep-clean the data container: remove every well-known state directory.
+ (void)wipeSandboxDirectoriesForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [4/8] Sandbox: %@", bundleID);

    NSURL *container = [self dataContainerURLForBundleID:bundleID];
    if (!container) {
        NSLog(@"[AppWiper]   no container, skipping");
        return;
    }

    NSString *root = [container path];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[
        [root stringByAppendingPathComponent:@"Documents"],
        [root stringByAppendingPathComponent:@"Library/Caches"],
        [root stringByAppendingPathComponent:@"Library/Preferences"],
        [root stringByAppendingPathComponent:@"tmp"],
        [root stringByAppendingPathComponent:@"Library/WebKit"],
        [root stringByAppendingPathComponent:@"Library/Application Support"],
        [root stringByAppendingPathComponent:@"Library/Cookies"],
        [root stringByAppendingPathComponent:@"Library/Saved Application State"],
        [root stringByAppendingPathComponent:@"Library/HTTPStorages"],
    ];
    for (NSString *d in dirs) [self removeDirectoryAtPath:d];

    // Sweep stray top-level entries (preserve system dot-files).
    for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *p = [root stringByAppendingPathComponent:entry];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if ([a[NSFileType] isEqualToString:NSFileTypeDirectory])
            [self removeDirectoryAtPath:p];
        else
            [self removeFileAtPath:p];
    }
}

#pragma mark - 5. TCC Privacy Permissions

// Open TCC.db and DELETE rows whose client matches the bundleID or
// the "<TeamID>.<bundleID>" wildcard.
+ (BOOL)wipeTCCPermissionsForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [5/8] TCC: %@", bundleID);

    NSString *path = @"/private/var/mobile/Library/TCC/TCC.db";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = @"/private/var/protected/TCC/TCC.db";
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSLog(@"[AppWiper]   TCC.db not found");
            return NO;
        }
    }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2([path UTF8String], &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"[AppWiper]   open failed: %s", db ? sqlite3_errmsg(db) : "(null)");
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", NULL, NULL, NULL);

    BOOL ok = YES;
    ok &= [self tccDeleteIn:db sql:"DELETE FROM access WHERE client = ?1" bind:bundleID];
    ok &= [self tccDeleteIn:db sql:"DELETE FROM access WHERE client LIKE ?1"
                       bind:[NSString stringWithFormat:@"%%.%@", bundleID]];

    sqlite3_close(db);
    return ok;
}

// Execute a parameterised DELETE with a single text bind.
+ (BOOL)tccDeleteIn:(sqlite3 *)db sql:(const char *)sql bind:(NSString *)bind {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        NSLog(@"[AppWiper]   prepare failed: %s", sqlite3_errmsg(db));
        return NO;
    }
    sqlite3_bind_text(stmt, 1, [bind UTF8String], -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        NSLog(@"[AppWiper]   delete step failed: %s", sqlite3_errmsg(db));
        return NO;
    }
    return YES;
}

#pragma mark - 6. CoreDuet & Biome

// Remove per-app behavioural-learning data under CoreDuet/ and Biome/.
+ (void)wipeCoreDuetAndBiomeForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [6/8] CoreDuet/Biome: %@", bundleID);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *roots = @[
        @"/var/mobile/Library/CoreDuet",
        @"/var/mobile/Library/Biome",
        @"/var/mobile/Library/CoreDuet/Knowledge",
        @"/var/mobile/Library/Biome/streams",
    ];
    for (NSString *root in roots) {
        [self purgeContaining:bundleID atRoot:root fm:fm];
    }
}

// Recursively remove entries whose path contains the needle.
+ (void)purgeContaining:(NSString *)needle atRoot:(NSString *)root fm:(NSFileManager *)fm {
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return;

    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSMutableArray *toRemove = [NSMutableArray array];
    NSString *entry = nil;
    while ((entry = [en nextObject])) {
        if ([entry rangeOfString:needle].location != NSNotFound) {
            [toRemove addObject:[root stringByAppendingPathComponent:entry]];
        }
    }
    // Remove deepest first.
    [toRemove sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    for (NSString *p in toRemove) {
        [self removeDirectoryAtPath:p];
        [self removeFileAtPath:p];
    }
}

#pragma mark - 7. APNs Push Token

// Remove the push-notification registration entry for the app.
+ (void)wipeAPNsTokenForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [7/8] APNs: %@", bundleID);

    NSArray *paths = @[
        @"/var/mobile/Library/APNS/APNSSandboxedClients.plist",
        @"/var/mobile/Library/APNS/APNSClients.plist",
        @"/var/mobile/Library/Preferences/com.apple.APNS.plist",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if (![fm fileExistsAtPath:path]) continue;
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (![plist isKindOfClass:[NSDictionary class]]) continue;
        if (plist[bundleID]) {
            [plist removeObjectForKey:bundleID];
            [plist writeToFile:path atomically:YES];
            NSLog(@"[AppWiper]   removed entry from %@", path.lastPathComponent);
        }
    }

    // Per-app APNS directory inside the container.
    NSURL *container = [self dataContainerURLForBundleID:bundleID];
    if (container) {
        NSString *d = [[[container path] stringByAppendingPathComponent:@"Library"]
                       stringByAppendingPathComponent:@"APNS"];
        [self removeDirectoryAtPath:d];
    }
}

#pragma mark - 8. Config File

// Delete the AppWiper config plist and any snapshot directory.
+ (void)wipeConfigFileForBundleID:(NSString *)bundleID {
    NSLog(@"[AppWiper] [8/8] Config: %@", bundleID);
    [self removeFileAtPath:[self getConfigPathForBundleID:bundleID]];
    NSString *snapDir = [@"/var/mobile/Library/Preferences/AppWiper_Snapshots"
                            stringByAppendingPathComponent:bundleID];
    [self removeDirectoryAtPath:snapDir];
}

#pragma mark - Filesystem Primitives

+ (void)removeDirectoryAtPath:(NSString *)path {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return;
    NSError *e = nil;
    [fm removeItemAtPath:path error:&e];
    if (e) NSLog(@"[AppWiper]   rmdir %@: %@", path.lastPathComponent, e.localizedDescription);
}

+ (void)removeFileAtPath:(NSString *)path {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) return;
    NSError *e = nil;
    [fm removeItemAtPath:path error:&e];
    if (e) NSLog(@"[AppWiper]   rm %@: %@", path.lastPathComponent, e.localizedDescription);
}

@end
