#import "StorageManager.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const kSuiteName = @"com.ntm.notifymanager";
static NSString *const kConfigChangedNotification = @"com.ntm.notifymanager.configChanged";

@implementation StorageManager {
    NSUserDefaults *_prefs;
    NSMutableDictionary *_cache;
    id _bbGateway;
}

+ (NSString *)suiteName { return kSuiteName; }

+ (instancetype)shared {
    static StorageManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        _cache = [NSMutableDictionary dictionary];
        // BBSettingsGateway 懒加载，不阻塞启动
    }
    return self;
}

/// 懒加载 BBSettingsGateway（仅当需要同步时创建）
- (id)_bbGateway {
    if (!_bbGateway) {
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard", RTLD_NOW);
            cls = NSClassFromString(@"BBSettingsGateway");
        }
        if (cls) _bbGateway = [[cls alloc] init];
    }
    return _bbGateway;
}

#pragma mark - Dimensions

- (NSArray<NSDictionary *> *)allDims {
    return @[
        @{@"key": @"lock",   @"title": @"锁定屏幕"},
        @{@"key": @"nc",     @"title": @"通知中心"},
        @{@"key": @"banner", @"title": @"横幅"},
        @{@"key": @"sound",  @"title": @"声音"},
        @{@"key": @"badge",  @"title": @"标记"},
    ];
}

- (NSString *)dimKeyAtIndex:(NSInteger)index {
    return [self allDims][index][@"key"];
}

- (NSString *)dimTitleAtIndex:(NSInteger)index {
    return [self allDims][index][@"title"];
}

#pragma mark - Read / Write

- (NSString *)_keyForApp:(NSString *)appId dim:(NSString *)dim {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}

- (NSString *)_netKeyForApp:(NSString *)appId {
    return [NSString stringWithFormat:@"NTM_net_%@", appId];
}

- (BOOL)readEnabledForApp:(NSString *)appId dim:(NSString *)dim {
    if (!appId.length) return YES;
    NSString *key = [self _keyForApp:appId dim:dim];
    @synchronized(_cache) {
        NSNumber *cached = _cache[key];
        if (cached) return [cached boolValue];
    }
    id val = [_prefs objectForKey:key];
    BOOL v = val ? [val boolValue] : YES;
    @synchronized(_cache) {
        _cache[key] = @(v);
    }
    return v;
}

- (void)writeEnabled:(BOOL)enabled forApp:(NSString *)appId dim:(NSString *)dim {
    NSString *key = [self _keyForApp:appId dim:dim];
    [_prefs setBool:enabled forKey:key];
    @synchronized(_cache) {
        _cache[key] = @(enabled);
    }
    [_prefs synchronize];
    [self postConfigChanged];
    // 同步到系统通知设置
    if ([dim isEqualToString:@"en"] || [dim isEqualToString:@"lock"] ||
        [dim isEqualToString:@"nc"] || [dim isEqualToString:@"banner"] ||
        [dim isEqualToString:@"sound"] || [dim isEqualToString:@"badge"]) {
        [self syncSystemNotificationAsync:appId];
    }
}

- (BOOL)readMasterForApp:(NSString *)appId {
    return [self readEnabledForApp:appId dim:@"en"];
}

- (void)writeMaster:(BOOL)enabled forApp:(NSString *)appId {
    NSString *key = [self _keyForApp:appId dim:@"en"];
    [_prefs setBool:enabled forKey:key];
    @synchronized(_cache) {
        _cache[key] = @(enabled);
    }
    // 总开关联动所有子开关
    for (NSDictionary *d in [self allDims]) {
        NSString *dk = [self _keyForApp:appId dim:d[@"key"]];
        [_prefs setBool:enabled forKey:dk];
        _cache[dk] = @(enabled);
    }
    [_prefs synchronize];
    [self postConfigChanged];
    [self syncSystemNotificationAsync:appId];
}

- (NSInteger)readNetPolicyForApp:(NSString *)appId {
    id v = [_prefs objectForKey:[self _netKeyForApp:appId]];
    return v ? [v integerValue] : 0;
}

- (void)writeNetPolicy:(NSInteger)policy forApp:(NSString *)appId {
    [_prefs setInteger:policy forKey:[self _netKeyForApp:appId]];
    [_prefs synchronize];
    [self syncSystemCellularAsync:appId policy:policy];
}

- (void)postConfigChanged {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kConfigChangedNotification,
        NULL, NULL, YES);
}

- (void)resetApp:(NSString *)appId {
    [_prefs setBool:YES forKey:[self _keyForApp:appId dim:@"en"]];
    for (NSDictionary *d in [self allDims]) {
        [_prefs setBool:YES forKey:[self _keyForApp:appId dim:d[@"key"]]];
    }
    @synchronized(_cache) { [_cache removeAllObjects]; }
    [_prefs synchronize];
    [self postConfigChanged];
    [self syncSystemNotificationAsync:appId];
}

#pragma mark - Batch

- (void)batchWrite:(BOOL)enabled forApps:(NSArray<NSString *> *)appIds netPolicy:(NSInteger)netPolicy {
    // 批量写入 NSUserDefaults（主线程，极快）
    NSMutableDictionary *bulk = [NSMutableDictionary dictionary];
    for (NSString *aid in appIds) {
        bulk[[self _keyForApp:aid dim:@"en"]] = @(enabled);
        for (NSDictionary *d in [self allDims]) {
            bulk[[self _keyForApp:aid dim:d[@"key"]]] = @(enabled);
        }
        bulk[[self _netKeyForApp:aid]] = @(netPolicy);
    }
    [_prefs setValuesForKeysWithDictionary:bulk];
    @synchronized(_cache) { [_cache removeAllObjects]; }
    // synchronize + postNotification + 系统同步 全部异步到后台
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [_prefs synchronize];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kConfigChangedNotification,
            NULL, NULL, YES);
        // 并行同步 BBSettingsGateway（每个 App 独立 XPC 调用）
        [appIds enumerateObjectsWithOptions:NSEnumerationConcurrent
                                 usingBlock:^(NSString *aid, NSUInteger idx, BOOL *stop) {
            [self syncSystemNotificationForApp:aid];
            [self syncSystemCellularForApp:aid];
        }];
    });
}

- (NSDictionary *)snapshotForApps:(NSArray<NSDictionary *> *)apps {
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (NSDictionary *app in apps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @([self readMasterForApp:aid]);
        for (NSDictionary *dim in [self allDims]) {
            d[dim[@"key"]] = @([self readEnabledForApp:aid dim:dim[@"key"]]);
        }
        d[@"net"] = @([self readNetPolicyForApp:aid]);
        snap[aid] = d;
    }
    return snap;
}

- (void)restoreSnapshot:(NSDictionary *)snapshot {
    NSMutableDictionary *bulk = [NSMutableDictionary dictionary];
    for (NSString *aid in snapshot) {
        NSDictionary *d = snapshot[aid];
        id en = d[@"en"];
        if (en) bulk[[self _keyForApp:aid dim:@"en"]] = en;
        for (NSDictionary *dim in [self allDims]) {
            id v = d[dim[@"key"]];
            if (v) bulk[[self _keyForApp:aid dim:dim[@"key"]]] = v;
        }
        id net = d[@"net"];
        if (net) bulk[[self _netKeyForApp:aid]] = net;
    }
    [_prefs setValuesForKeysWithDictionary:bulk];
    NSArray *changedIds = [snapshot allKeys];
    @synchronized(_cache) { [_cache removeAllObjects]; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [_prefs synchronize];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kConfigChangedNotification,
            NULL, NULL, YES);
        [changedIds enumerateObjectsWithOptions:NSEnumerationConcurrent
                                    usingBlock:^(NSString *aid, NSUInteger idx, BOOL *stop) {
            [self syncSystemNotificationForApp:aid];
            id net = snapshot[aid][@"net"];
            if (net) [self syncSystemCellularForApp:aid];
        }];
    });
}

#pragma mark - Import / Export

- (NSArray *)exportConfigForAllApps:(NSArray<NSDictionary *> *)allApps {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *app in allApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"appId"] = aid;
        d[@"name"] = app[@"name"];
        d[@"en"] = @([self readMasterForApp:aid]);
        NSMutableDictionary *dims = [NSMutableDictionary dictionary];
        for (NSDictionary *dim in [self allDims]) dims[dim[@"key"]] = @([self readEnabledForApp:aid dim:dim[@"key"]]);
        d[@"dims"] = dims;
        d[@"net"] = @([self readNetPolicyForApp:aid]);
        [arr addObject:d];
    }
    return arr;
}

- (NSInteger)importConfig:(NSArray *)config {
    NSMutableDictionary *bulk = [NSMutableDictionary dictionary];
    NSMutableArray *changedIds = [NSMutableArray array];
    for (NSDictionary *d in config) {
        NSString *aid = d[@"appId"];
        if (!aid.length) continue;
        id en = d[@"en"];
        if (en) bulk[[self _keyForApp:aid dim:@"en"]] = en;
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in dims) {
                bulk[[self _keyForApp:aid dim:k]] = dims[k];
            }
        }
        id net = d[@"net"];
        if (net) bulk[[self _netKeyForApp:aid]] = net;
        [changedIds addObject:aid];
    }
    [_prefs setValuesForKeysWithDictionary:bulk];
    @synchronized(_cache) { [_cache removeAllObjects]; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [_prefs synchronize];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kConfigChangedNotification,
            NULL, NULL, YES);
        [changedIds enumerateObjectsWithOptions:NSEnumerationConcurrent
                                    usingBlock:^(NSString *aid, NSUInteger idx, BOOL *stop) {
            [self syncSystemNotificationForApp:aid];
            [self syncSystemCellularForApp:aid];
        }];
    });
    return changedIds.count;
}

#pragma mark - 系统同步：BBSettingsGateway（通知设置）

- (void)syncSystemNotificationAsync:(NSString *)appId {
    if (!appId.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self syncSystemNotificationForApp:appId];
    });
}

- (void)syncSystemNotificationForApp:(NSString *)appId {
    if (!appId.length) return;
    @try {
        id gateway = [self _bbGateway];
        if (!gateway) return;
        id info = [gateway performSelector:@selector(sectionInfoForSectionID:) withObject:appId];
        if (!info) return;

        BOOL en = [self readEnabledForApp:appId dim:@"en"];
        BOOL lock = [self readEnabledForApp:appId dim:@"lock"];
        BOOL nc = [self readEnabledForApp:appId dim:@"nc"];
        BOOL banner = [self readEnabledForApp:appId dim:@"banner"];
        BOOL anyVisible = lock || nc || banner;
        BOOL sound = en && anyVisible && [self readEnabledForApp:appId dim:@"sound"];
        BOOL badge = en && anyVisible && [self readEnabledForApp:appId dim:@"badge"];

        [info setValue:@(en) forKey:@"allowsNotifications"];
        [info setValue:@(lock) forKey:@"showsInLockScreen"];
        [info setValue:@(nc) forKey:@"showsInNotificationCenter"];
        [info setValue:@(banner ? 1 : 0) forKey:@"alertType"];
        // 声音/角标必须通过 pushSettings 位掩码控制
        NSUInteger push = 0;
        if (sound) push |= 18;  // bit1+bit4
        if (badge) push |= 9;   // bit0+bit3
        if (banner) push |= 36; // bit2+bit5
        [info setValue:@(push) forKey:@"pushSettings"];

        SEL setSel = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gateway respondsToSelector:setSel]) {
            [gateway performSelector:setSel withObject:info withObject:appId];
        }
        NSLog(@"[NTM] sync %@ en=%d lock=%d nc=%d banner=%d sound=%d badge=%d push=%lu",
              appId, en, lock, nc, banner, sound, badge, (unsigned long)push);
    } @catch(NSException *e) {
        NSLog(@"[NTM] sync %@ exception: %@", appId, e);
    }
}

#pragma mark - 系统同步：蜂窝网络策略

- (void)syncSystemCellularAsync:(NSString *)appId policy:(NSInteger)policy {
    if (!appId.length) return;
    // 先存 NSUserDefaults
    [_prefs setInteger:policy forKey:[self _netKeyForApp:appId]];
    [_prefs synchronize];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self syncSystemCellularForApp:appId];
    });
}

- (void)syncSystemCellularForApp:(NSString *)appId {
    if (!appId.length) return;
    NSInteger policy = [self readNetPolicyForApp:appId];
    BOOL cellular = (policy == 0 || policy == 3); // wifi+流量/流量
    BOOL wifi = (policy == 0 || policy == 2);     // wifi+流量/打开wifi

    // 方法1: PSAppDataUsagePolicyCache（与"设置→蜂窝网络"同源）
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
            cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        }
        if (cls) {
            id cache = [cls performSelector:@selector(sharedInstance)];
            if (cache) {
                SEL sel = NSSelectorFromString(@"setUsagePoliciesForBundle:cellular:wifi:");
                if ([cache respondsToSelector:sel]) {
                    // 使用 objc_msgSend 避免编译时类型检查
                    ((void (*)(id, SEL, NSString*, BOOL, BOOL))objc_msgSend)(cache, sel, appId, cellular, wifi);
                    NSLog(@"[NTM] cellular %@ policy=%ld cell=%d wifi=%d (PSAppDataUsagePolicyCache)",
                          appId, (long)policy, cellular, wifi);
                    return;
                }
            }
        }
    } @catch(NSException *e) {
        NSLog(@"[NTM] cellular %@ PSAppDataUsagePolicyCache error: %@", appId, e);
    }

    // 方法2: CoreTelephony 私有 API（回退方案）
    @try {
        void *handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        if (!handle) return;
        void *(*createConn)(CFAllocatorRef, void *, void *) = dlsym(handle, "_CTServerConnectionCreate");
        int (*setPolicy)(void *, NSString *, NSDictionary *) = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy");
        if (createConn && setPolicy) {
            void *conn = createConn(kCFAllocatorDefault, NULL, NULL);
            if (conn) {
                NSString *cellStr = cellular ? @"kCTCellularDataUsagePolicyAlwaysAllow" : @"kCTCellularDataUsagePolicyDeny";
                NSString *wifiStr = wifi ? @"kCTWiFiDataUsagePolicyAlwaysAllow" : @"kCTWiFiDataUsagePolicyDeny";
                NSDictionary *policies = @{
                    @"kCTCellularDataUsagePolicy": cellStr,
                    @"kCTWiFiDataUsagePolicy": wifiStr,
                };
                setPolicy(conn, appId, policies);
                NSLog(@"[NTM] cellular %@ policy=%ld (CoreTelephony fallback)", appId, (long)policy);
            }
        }
        dlclose(handle);
    } @catch(NSException *e) {
        NSLog(@"[NTM] cellular %@ CoreTelephony error: %@", appId, e);
    }
}

@end