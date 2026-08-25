#import "BatteryData.h"
#import <UIKit/UIKit.h>
#import <sqlite3.h>
#import <MobileCoreServices/MobileCoreServices.h>

@implementation AppUsage
@end
@implementation HourlyUsage
@end

@interface BatteryData ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *batteryHistory;
@end

@implementation BatteryData

+ (instancetype)shared {
    static BatteryData *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [BatteryData new]; });
    return d;
}

// 找到最新的 Powerlog 数据库：递归扫描 Logs 目录，支持 .PLSQL / .PLSQL.gz / .powerlog
- (NSString *)latestPowerlogPath {
    NSMutableArray *candidates = [NSMutableArray array];
    NSArray *roots = @[
        @"/var/mobile/Library/Logs",
        @"/private/var/mobile/Library/Logs",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        for (NSString *rel in en) {
            NSString *lower = rel.lowercaseString;
            if ([lower hasSuffix:@".plsql"] || [lower hasSuffix:@".plsql.gz"] ||
                [lower hasSuffix:@".powerlog"] || [lower containsString:@"powerlog"]) {
                NSString *full = [root stringByAppendingPathComponent:rel];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
                    [candidates addObject:full];
                }
            }
        }
    }
    [candidates sortUsingSelector:@selector(compare:)];
    return candidates.lastObject;
}

// 读取当前电量（兜底，Powerlog 不可用时仍能显示）
- (NSInteger)currentBatteryLevelIOKit {
    UIDevice *dev = [UIDevice currentDevice];
    dev.batteryMonitoringEnabled = YES;
    float level = dev.batteryLevel;
    if (level < 0) return -1;
    return (NSInteger)(level * 100 + 0.5);
}

- (void)loadData {
    _errorMessage = nil;
    NSString *path = [self latestPowerlogPath];
    if (!path) {
        NSInteger ioLevel = [self currentBatteryLevelIOKit];
        NSMutableString *diag = [NSMutableString stringWithString:@"未找到 Powerlog 数据库。\n"];
        [diag appendFormat:@"iOS 版本：%@\n", [[UIDevice currentDevice] systemVersion]];
        [diag appendFormat:@"当前电量（IOKit）：%ld%%\n", (long)ioLevel];
        [diag appendString:@"已扫描的目录：\n"];
        NSArray *dirs = @[
            @"/var/mobile/Library/Logs/CrashReporter",
            @"/var/mobile/Library/Logs/Powerlog",
            @"/var/mobile/Library/Logs",
        ];
        for (NSString *dir in dirs) {
            BOOL isDir = NO;
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir];
            [diag appendFormat:@"%@：%@\n", dir, exists ? @"存在" : @"不存在"];
            if (exists) {
                NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
                [diag appendFormat:@"  文件数 %lu\n", (unsigned long)files.count];
                for (NSString *f in [files subarrayWithRange:NSMakeRange(0, MIN(files.count, 6))]) {
                    [diag appendFormat:@"  - %@\n", f];
                }
            }
        }
        _errorMessage = diag;
        return;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open([path UTF8String], &db) != SQLITE_OK) {
        _errorMessage = @"无法打开 Powerlog 数据库";
        return;
    }
    [self loadBatteryHistory:db];
    [self loadAppUsage:db];
    [self loadHourlyUsage:db];
    sqlite3_close(db);
}

// 电量历史：Level 是 0-1 的百分比
- (void)loadBatteryHistory:(sqlite3 *)db {
    _batteryHistory = [NSMutableArray array];
    const char *sql = "SELECT timestamp, Level, IsCharging, ExternalConnected FROM PLBatteryAgent_EventBackward_Battery ORDER BY timestamp ASC";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            double ts = sqlite3_column_double(stmt, 0);
            double level = sqlite3_column_double(stmt, 1);
            int charging = sqlite3_column_int(stmt, 2);
            int ext = sqlite3_column_int(stmt, 3);
            [_batteryHistory addObject:@{
                @"ts": @(ts),
                @"level": @(level),
                @"charging": @(charging),
                @"ext": @(ext),
            }];
        }
    }
    sqlite3_finalize(stmt);

    NSDictionary *last = _batteryHistory.lastObject;
    if (last) _currentLevel = (NSInteger)lround([last[@"level"] doubleValue] * 100);

    // 找上次充电结束：从最新往旧，找 充电状态 从 1 变 0 的点
    _lastChargeEnd = nil;
    _chargeEndLevel = 0;
    for (NSInteger i = _batteryHistory.count - 1; i >= 1; i--) {
        NSDictionary *cur = _batteryHistory[i];
        NSDictionary *prev = _batteryHistory[i - 1];
        BOOL wasCharging = [prev[@"charging"] boolValue] || [prev[@"ext"] boolValue];
        BOOL nowNot = ![cur[@"charging"] boolValue] && ![cur[@"ext"] boolValue];
        if (wasCharging && nowNot) {
            _lastChargeEnd = [NSDate dateWithTimeIntervalSince1970:[cur[@"ts"] doubleValue]];
            _chargeEndLevel = (NSInteger)lround([cur[@"level"] doubleValue] * 100);
            break;
        }
    }
    if (!_lastChargeEnd && _batteryHistory.count) {
        NSDictionary *first = _batteryHistory.firstObject;
        _lastChargeEnd = [NSDate dateWithTimeIntervalSince1970:[first[@"ts"] doubleValue]];
        _chargeEndLevel = (NSInteger)lround([first[@"level"] doubleValue] * 100);
    }
}

// 每 App 运行时间（前台/后台），作为耗电排行依据
- (void)loadAppUsage:(sqlite3 *)db {
    NSMutableArray *list = [NSMutableArray array];
    const char *sql = "SELECT BundleID, SUM(ScreenOnTime), SUM(BackgroundTime) FROM PLAppTimeService_Aggregate_AppRunTime GROUP BY BundleID";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *bid = (const char *)sqlite3_column_text(stmt, 0);
            if (!bid) continue;
            AppUsage *u = [AppUsage new];
            u.bundleId = [NSString stringWithUTF8String:bid];
            u.appName = [self appNameForBundleId:u.bundleId];
            u.screenOnTime = sqlite3_column_double(stmt, 1);
            u.backgroundTime = sqlite3_column_double(stmt, 2);
            [list addObject:u];
        }
    }
    sqlite3_finalize(stmt);

    _appUsages = [list sortedArrayUsingComparator:^NSComparisonResult(AppUsage *a, AppUsage *b) {
        double ta = a.screenOnTime + a.backgroundTime;
        double tb = b.screenOnTime + b.backgroundTime;
        return ta < tb ? NSOrderedDescending : (ta > tb ? NSOrderedAscending : NSOrderedSame);
    }];
}

// 每小时运行 App 数：按小时聚合不同 BundleID 数量
- (void)loadHourlyUsage:(sqlite3 *)db {
    NSMutableDictionary *hourly = [NSMutableDictionary dictionary];
    const char *sql = "SELECT timestamp, BundleID FROM PLAppTimeService_Aggregate_AppRunTime";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            double ts = sqlite3_column_double(stmt, 0);
            const char *bid = (const char *)sqlite3_column_text(stmt, 1);
            if (!bid) continue;
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *c = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour) fromDate:date];
            NSString *key = [NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld", (long)c.year, (long)c.month, (long)c.day, (long)c.hour];
            NSMutableSet *set = hourly[key];
            if (!set) { set = [NSMutableSet set]; hourly[key] = set; }
            [set addObject:[NSString stringWithUTF8String:bid]];
        }
    }
    sqlite3_finalize(stmt);

    NSArray *keys = [hourly.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSArray *recent = keys.count > 24 ? [keys subarrayWithRange:NSMakeRange(keys.count - 24, 24)] : keys;
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *key in recent) {
        HourlyUsage *h = [HourlyUsage new];
        h.label = key;
        h.appCount = ((NSSet *)hourly[key]).count;
        [result addObject:h];
    }
    _hourlyUsages = result;
}

- (NSString *)appNameForBundleId:(NSString *)bundleId {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass && [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
        NSString *name = [proxy performSelector:@selector(localizedName)];
        if (name.length) return name;
    }
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"com.apple.mobilesafari": @"Safari",
            @"com.apple.mobileslideshow": @"照片",
            @"com.apple.camera": @"相机",
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.mobilephone": @"电话",
            @"com.apple.MobileMail": @"邮件",
            @"com.apple.mobilemail": @"邮件",
            @"com.apple.Preferences": @"设置",
            @"com.apple.springboard": @"桌面",
            @"com.apple.WebKit.GPU": @"WebKit",
            @"com.apple.WebKit.WebContent": @"网页内容",
            @"com.apple.accounts": @"账户",
            @"com.apple.purplebuddy": @"激活",
            @"com.apple.mediaplaybackd": @"媒体播放",
            @"com.apple.locationd": @"定位服务",
            @"com.apple.identityservices.idstatus": @"iMessage",
            @"com.apple.apsd": @"推送服务",
            @"com.apple.audio.speech.speechrecognition": @"语音识别",
        };
    });
    if (map[bundleId]) return map[bundleId];
    return bundleId;
}

@end
