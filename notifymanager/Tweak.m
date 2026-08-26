// Tweak.m — 注入 SpringBoard，hook 通知展示 (iOS 16.6)
// 总开关:   NCNotificationDispatcher -postNotificationWithRequest:
//           同时在此做: 关键词过滤 / 隐藏预览 / 拦截日志
// 横幅:     SBDashBoardNotificationPresenter -presentModalBannerAndExpandForNotificationRequest:
// 声音:     SBNCSoundController -canPlaySoundForNotificationRequest:
// 角标:     SBApplication -setBadgeValue: (含 仅隐藏角标)
// 列表:     NCNotificationStructuredListViewController / NCNotificationCombinedListViewController -insertNotificationRequest...
// 后台断网: FBSceneManager -_noteSceneMovedToBackground: / -_noteSceneMovedToForeground:
// 设置面板通过 NSUserDefaults suiteName 通信
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

// 共享 NSUserDefaults 单例，避免每次通知到达都新建实例
static NSUserDefaults *NTM_prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    });
    return prefs;
}

// 内存缓存：key=NTM_<dim>_<appId> -> NSNumber，通知到达时零 I/O 读取
static NSMutableDictionary *NTM_cache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

// 设置面板写配置后发 Darwin 通知，这里清空缓存保证读取到最新值
static void NTM_cacheInvalidated(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @synchronized(NTM_cache()) {
        [NTM_cache() removeAllObjects];
    }
}

static BOOL NTM_raw(NSString *appId, NSString *key, BOOL def) {
    if (!appId.length) return def;
    NSString *k = [NSString stringWithFormat:@"NTM_%@_%@", key, appId];
    @synchronized(NTM_cache()) {
        NSNumber *cached = NTM_cache()[k];
        if (cached) return [cached boolValue];
        id val = [NTM_prefs() objectForKey:k];
        BOOL v = val ? [val boolValue] : def;
        NTM_cache()[k] = @(v);
        return v;
    }
}

// 开关类：未设置时默认开启（总开关/分项）
static BOOL NTM_on(NSString *appId, NSString *dim) {
    return NTM_raw(appId, dim, YES);
}
// 增强类开关：未设置时默认关闭（隐藏角标/隐藏预览/后台断网）
static BOOL NTM_feat(NSString *appId, NSString *key) {
    return NTM_raw(appId, key, NO);
}

// 子维度是否应拦截：总开关关闭 → 全部拦截；否则按该维度开关
static BOOL NTM_shouldBlock(NSString *appId, NSString *dim) {
    if (!NTM_on(appId, @"en")) return YES;
    return !NTM_on(appId, dim);
}

static NSString *NTM_sectionOf(id request) {
    if (!request) return nil;
    NSString *sectionId = nil;
    @try { sectionId = [request performSelector:@selector(sectionIdentifier)]; } @catch(NSException *e) {}
    return sectionId;
}

#pragma mark - 关键词过滤 (JSON 数组缓存)
static NSMutableDictionary *NTM_kwCache(void) {
    static NSMutableDictionary *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kw = [NSMutableDictionary dictionary]; });
    return kw;
}
// 命中任一关键词即返回该关键词；无关键词/未过滤返回 nil
static NSString *NTM_matchKeyword(NSString *appId, id request) {
    if (!appId.length) return nil;
    NSArray *kws = NTM_kwCache()[appId];
    if (!kws) {
        id v = [NTM_prefs() objectForKey:[NSString stringWithFormat:@"NTM_kw_%@", appId]];
        NSArray *arr = [v isKindOfClass:[NSArray class]] ? v : nil;
        if ([v isKindOfClass:[NSString class]]) {
            NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
        }
        kws = arr ?: @[];
        if (kws.count) NTM_kwCache()[appId] = kws; // 空列表可直接短路
    }
    if (!kws.count) return nil;
    NSString *title = @"", *message = @"";
    @try {
        id content = [request performSelector:@selector(content)];
        if (content) {
            @try { title = [content performSelector:@selector(title)] ?: @""; } @catch(NSException *e) {}
            @try { message = [content performSelector:@selector(message)] ?: @""; } @catch(NSException *e) {}
        }
    } @catch(NSException *e) {}
    NSString *hay = [NSString stringWithFormat:@"%@ %@", title ?: @"", message ?: @""];
    for (NSString *kw in kws) {
        if (kw.length && [hay rangeOfString:kw].location != NSNotFound) return kw;
    }
    return nil;
}

#pragma mark - 隐藏预览 (只显示 App 名)
static void NTM_blankPreview(id request) {
    @try {
        id content = [request performSelector:@selector(content)];
        if (!content) return;
        @try { [content setValue:@"" forKey:@"title"]; } @catch(NSException *e) {}
        @try { [content setValue:@"" forKey:@"subtitle"]; } @catch(NSException *e) {}
        @try { [content setValue:@"" forKey:@"message"]; } @catch(NSException *e) {}
    } @catch(NSException *e) {}
}

#pragma mark - 拦截日志 (只记被拦截的事件)
static dispatch_queue_t NTM_logQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.ntm.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}
// 异步写日志，避免阻塞通知主线程
static void NTM_logBlocked(NSString *appId, NSString *type, NSString *detail) {
    NSUserDefaults *prefs = NTM_prefs();
    dispatch_async(NTM_logQueue(), ^{
        NSMutableArray *arr = [[prefs objectForKey:@"NTM_log"] mutableCopy];
        if (![arr isKindOfClass:[NSMutableArray class]]) arr = [NSMutableArray array];
        [arr insertObject:@{
            @"t":@([NSDate date].timeIntervalSince1970),
            @"app":appId ?: @"",
            @"type":type ?: @"",
            @"d":detail ?: @"",
        } atIndex:0];
        if (arr.count > 300) [arr removeObjectsInRange:NSMakeRange(300, arr.count - 300)];
        [prefs setObject:arr forKey:@"NTM_log"];
        [prefs synchronize];
    });
}

#pragma mark - 网络策略 (后台断网用, 与设置面板同源)
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static void NTM_applyNetPolicy(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    BOOL cellular = (policy == 0 || policy == 3);
    BOOL wifi = (policy == 0 || policy == 2);
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) cls = NSClassFromString(@"PSAppDataUsagePolicyCache"); // Preferences 已加载
        id cache = nil;
        if (cls) {
            @try { cache = [(id)cls performSelector:@selector(sharedInstance)]; } @catch(NSException *e) {}
        }
        if (cache) {
            @try {
                [cache setUsagePoliciesForBundle:appId cellular:cellular wifi:wifi];
                return;
            } @catch(NSException *e) {}
        }
    } @catch(NSException *e) {}
    @try {
        void *handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        if (!handle) return;
        void *(*createConn)(CFAllocatorRef, void *, void *) = dlsym(handle, "_CTServerConnectionCreate");
        int (*setPolicy)(void *, NSString *, NSDictionary *) = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy");
        if (createConn && setPolicy) {
            void *conn = createConn(kCFAllocatorDefault, NULL, NULL);
            if (conn) {
                NSString *cell = cellular ? @"kCTCellularDataUsagePolicyAlwaysAllow" : @"kCTCellularDataUsagePolicyDeny";
                NSString *wifiS = wifi ? @"kCTWiFiDataUsagePolicyAlwaysAllow" : @"kCTWiFiDataUsagePolicyDeny";
                setPolicy(conn, appId, @{@"kCTCellularDataUsagePolicy":cell, @"kCTWiFiDataUsagePolicy":wifiS});
            }
        }
        dlclose(handle);
    } @catch(NSException *e) {}
}

static NSInteger NTM_netRead(NSString *appId) {
    id v = [NTM_prefs() objectForKey:[NSString stringWithFormat:@"NTM_net_%@", appId]];
    return v ? [v integerValue] : 0;
}

#pragma mark - Hook NCNotificationDispatcher (总开关 + 关键词过滤 + 隐藏预览 + 日志)
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length) {
        // 关键词过滤：优先于总开关（命中即丢弃该条）
        NSString *kw = NTM_matchKeyword(sectionId, request);
        if (kw) {
            NTM_logBlocked(sectionId, @"kw", kw);
            return;
        }
        if (!NTM_on(sectionId, @"en")) {
            NTM_logBlocked(sectionId, @"notif", @"总开关关闭");
            return; // 总开关关闭 → 拦截整个通知
        }
        // 隐藏预览：只显示 App 名，不放行具体内容
        if (NTM_feat(sectionId, @"noPreview")) {
            NTM_blankPreview(request);
        }
    }
    if (orig_postRequest)
        orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"banner")) {
        NTM_logBlocked(sectionId, @"banner", @"横幅");
        return; // 拦截横幅
    }
    if (orig_presentBanner)
        orig_presentBanner(self, _cmd, request);
}

#pragma mark - Hook SBNCSoundController (声音)
static BOOL (*orig_canPlaySound)(id, SEL, id);
static BOOL hook_canPlaySound(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"sound")) {
        NTM_logBlocked(sectionId, @"sound", @"声音");
        return NO; // 拦截声音
    }
    return orig_canPlaySound ? orig_canPlaySound(self, _cmd, request) : YES;
}

#pragma mark - Hook SBApplication (角标: 原标记开关 + 仅隐藏角标)
static void (*orig_setBadgeValue)(id, SEL, id);
static void hook_setBadgeValue(id self, SEL _cmd, id value) {
    NSString *bundleId = nil;
    @try { bundleId = [self performSelector:@selector(bundleIdentifier)]; } @catch(NSException *e) {}
    if (bundleId.length) {
        // 仅隐藏角标：保留全部通知，只藏桌面小红点
        BOOL noBadge = NTM_feat(bundleId, @"noBadge");
        if (noBadge || NTM_shouldBlock(bundleId, @"badge")) {
            NTM_logBlocked(bundleId, @"badge", noBadge ? @"仅隐藏角标" : @"角标关闭");
            return; // 拦截角标更新
        }
    }
    if (orig_setBadgeValue)
        orig_setBadgeValue(self, _cmd, value);
}

#pragma mark - Hook 通知列表插入 (锁屏/通知中心)
static BOOL (*orig_insertRequest)(id, SEL, id);
static BOOL hook_insertRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc"))) {
        NTM_logBlocked(sectionId, @"notif", @"锁屏/通知中心关闭");
        return YES; // 拦截列表插入
    }
    return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
}

static BOOL (*orig_insertRequestCoalesced)(id, SEL, id, id);
static BOOL hook_insertRequestCoalesced(id self, SEL _cmd, id request, id coalesce) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc"))) {
        NTM_logBlocked(sectionId, @"notif", @"锁屏/通知中心关闭");
        return YES; // 拦截列表插入
    }
    return orig_insertRequestCoalesced ? orig_insertRequestCoalesced(self, _cmd, request, coalesce) : YES;
}

#pragma mark - 切后台自动断网 (FBSceneManager)
static NSString *NTM_bundleIdOf(id scene) {
    if (!scene) return nil;
    NSString *bid = nil;
    @try { bid = [scene valueForKeyPath:@"identity.bundleIdentifier"]; } @catch(NSException *e) {}
    if (!bid.length) { @try { bid = [scene valueForKeyPath:@"definition.clientProcessName"]; } @catch(NSException *e) {} }
    if (!bid.length) { @try { bid = [scene valueForKeyPath:@"clientIdentity.bundleIdentifier"]; } @catch(NSException *e) {} }
    if (!bid.length) { @try { bid = [scene valueForKeyPath:@"clientProcess.bundleIdentifier"]; } @catch(NSException *e) {} }
    return bid.length ? bid : nil;
}
// 是否开启"切后台自动断网"
static BOOL NTM_bgNetOn(NSString *appId) {
    return NTM_feat(appId, @"bgNet");
}

static void (*orig_bg)(id, SEL, id);
static void hook_bg(id self, SEL _cmd, id scene) {
    if (orig_bg) orig_bg(self, _cmd, scene);
    NSString *bid = NTM_bundleIdOf(scene);
    if (NTM_bgNetOn(bid)) {
        NTM_applyNetPolicy(bid, 1); // 断网
        NTM_logBlocked(bid, @"bgNet", @"切后台自动断网");
    }
}
static void (*orig_fg)(id, SEL, id);
static void hook_fg(id self, SEL _cmd, id scene) {
    if (orig_fg) orig_fg(self, _cmd, scene);
    NSString *bid = NTM_bundleIdOf(scene);
    if (NTM_bgNetOn(bid)) {
        NTM_applyNetPolicy(bid, NTM_netRead(bid)); // 恢复保存的网络策略
        NTM_logBlocked(bid, @"bgNet", @"回前台恢复网络");
    }
}

static void tryHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        // 监听设置面板的配置变更通知，清空内存缓存
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, NTM_cacheInvalidated,
                                        CFSTR("com.ntm.notifymanager.configChanged"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 总开关 + 关键词过滤 + 隐藏预览
        tryHook(objc_getClass("NCNotificationDispatcher"),
                sel_registerName("postNotificationWithRequest:"),
                (IMP)hook_postRequest, (IMP *)&orig_postRequest);

        // 横幅
        tryHook(objc_getClass("SBDashBoardNotificationPresenter"),
                sel_registerName("presentModalBannerAndExpandForNotificationRequest:"),
                (IMP)hook_presentBanner, (IMP *)&orig_presentBanner);

        // 声音
        tryHook(objc_getClass("SBNCSoundController"),
                sel_registerName("canPlaySoundForNotificationRequest:"),
                (IMP)hook_canPlaySound, (IMP *)&orig_canPlaySound);

        // 角标 (含 仅隐藏角标)
        tryHook(objc_getClass("SBApplication"),
                sel_registerName("setBadgeValue:"),
                (IMP)hook_setBadgeValue, (IMP *)&orig_setBadgeValue);

        // 列表 (锁屏/通知中心)
        tryHook(objc_getClass("NCNotificationStructuredListViewController"),
                sel_registerName("insertNotificationRequest:"),
                (IMP)hook_insertRequest, (IMP *)&orig_insertRequest);

        tryHook(objc_getClass("NCNotificationCombinedListViewController"),
                sel_registerName("insertNotificationRequest:forCoalescedNotification:"),
                (IMP)hook_insertRequestCoalesced, (IMP *)&orig_insertRequestCoalesced);

        // 切后台自动断网
        Class fbm = objc_getClass("FBSceneManager");
        tryHook(fbm, sel_registerName("_noteSceneMovedToBackground:"),
                (IMP)hook_bg, (IMP *)&orig_bg);
        tryHook(fbm, sel_registerName("_noteSceneMovedToForeground:"),
                (IMP)hook_fg, (IMP *)&orig_fg);
    }
}