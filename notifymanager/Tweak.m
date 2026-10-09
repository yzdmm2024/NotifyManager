// Tweak.m — 注入 SpringBoard，hook 通知展示 (iOS 16.6)
// 总开关:   NCNotificationDispatcher -postNotificationWithRequest:
//           同时在此做: 关键词过滤 / 隐藏预览
// 横幅:     SBDashBoardNotificationPresenter -presentModalBannerAndExpandForNotificationRequest:
// 声音:     SBNCSoundController -canPlaySoundForNotificationRequest:
// 角标:     SBApplication -setBadgeValue: (含 仅隐藏角标)
// 列表:     NCNotificationStructuredListViewController / NCNotificationCombinedListViewController -insertNotificationRequest...
// 后台断网: FBSceneManager -_noteSceneMovedToBackground: / -_noteSceneMovedToForeground:
// 设置面板通过 NSUserDefaults suiteName 通信
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>

#pragma mark - Preferences 私有类（网络权限同源）
// iOS 15/16/17 真实接口（无 setUsagePoliciesForBundle:cellular:wifi:）：
@interface PSAppDataUsagePolicyCache : NSObject
+ (instancetype)sharedInstance;
- (id)policiesFor:(NSString *)bundleId;                              // -> CTDataUsagePolicies
- (void)setPolicies:(id)policy completion:(void (^)(void))completion;
@end
@interface CTDataUsagePolicies : NSObject
- (instancetype)init:(NSString *)bundleId withCellularPolicy:(long long)cellular andWifiPolicy:(long long)wifi;
- (void)setCellular:(long long)cellular;                             // 1=允许 0=禁止
- (void)setWifi:(long long)wifi;                                     // 1=允许 0=禁止
@end

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

#pragma mark - 网络策略 (后台断网用, 与设置面板同源)
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static void NTM_applyNetPolicy(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    // policy: 0=wifi+流量 1=断网 2=只wifi 3=只流量；系统侧 1=允许 0=禁止
    long long cell = (policy == 0 || policy == 3) ? 1 : 0;
    long long wifi = (policy == 0 || policy == 2) ? 1 : 0;
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/SettingsCellular.framework/SettingsCellular", RTLD_NOW);
            cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        }
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
            cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        }
        if (!cls) return;
        id cache = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
        if (!cache) return;

        id pol = nil;
        SEL selPoliciesFor = NSSelectorFromString(@"policiesFor:");
        if ([cache respondsToSelector:selPoliciesFor]) {
            pol = ((id (*)(id, SEL, id))objc_msgSend)(cache, selPoliciesFor, appId);
        }
        if (pol) {
            SEL sCell = NSSelectorFromString(@"setCellular:");
            SEL sWifi = NSSelectorFromString(@"setWifi:");
            if ([pol respondsToSelector:sCell])
                ((void (*)(id, SEL, long long))objc_msgSend)(pol, sCell, cell);
            if ([pol respondsToSelector:sWifi])
                ((void (*)(id, SEL, long long))objc_msgSend)(pol, sWifi, wifi);
        } else {
            Class polCls = NSClassFromString(@"CTDataUsagePolicies");
            SEL initSel = NSSelectorFromString(@"init:withCellularPolicy:andWifiPolicy:");
            if (polCls && [polCls instancesRespondToSelector:initSel]) {
                id obj = ((id (*)(id, SEL))objc_msgSend)((id)polCls, NSSelectorFromString(@"alloc"));
                pol = ((id (*)(id, SEL, id, long long, long long))objc_msgSend)(obj, initSel, appId, cell, wifi);
            }
        }
        if (!pol) return;

        SEL setPol = NSSelectorFromString(@"setPolicies:completion:");
        if ([cache respondsToSelector:setPol]) {
            void (^done)(void) = ^{};
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, setPol, pol, done);
        }
    } @catch(NSException *e) {}
}

static NSInteger NTM_netRead(NSString *appId) {
    id v = [NTM_prefs() objectForKey:[NSString stringWithFormat:@"NTM_net_%@", appId]];
    return v ? [v integerValue] : 0;
}

#pragma mark - Hook NCNotificationDispatcher (总开关 + 关键词过滤 + 隐藏预览)
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length) {
        // 关键词过滤：优先于总开关（命中即丢弃该条）
        if (NTM_matchKeyword(sectionId, request)) return;
        if (!NTM_on(sectionId, @"en")) return; // 总开关关闭 → 拦截整个通知
        // 隐藏预览：只显示 App 名，不放行具体内容
        if (NTM_feat(sectionId, @"noPreview")) NTM_blankPreview(request);
    }
    if (orig_postRequest)
        orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"banner")) return; // 拦截横幅
    if (orig_presentBanner)
        orig_presentBanner(self, _cmd, request);
}

#pragma mark - Hook SBNCSoundController (声音)
static BOOL (*orig_canPlaySound)(id, SEL, id);
static BOOL hook_canPlaySound(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"sound")) return NO; // 拦截声音
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
        if (noBadge || NTM_shouldBlock(bundleId, @"badge")) return; // 拦截角标更新
    }
    if (orig_setBadgeValue)
        orig_setBadgeValue(self, _cmd, value);
}

#pragma mark - Hook 通知列表插入 (锁屏/通知中心)
static BOOL (*orig_insertRequest)(id, SEL, id);
static BOOL hook_insertRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES; // 拦截列表插入
    return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
}

static BOOL (*orig_insertRequestCoalesced)(id, SEL, id, id);
static BOOL hook_insertRequestCoalesced(id self, SEL _cmd, id request, id coalesce) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES; // 拦截列表插入
    return orig_insertRequestCoalesced ? orig_insertRequestCoalesced(self, _cmd, request, coalesce) : YES;
}

#pragma mark - 自动授权通知权限 (抹除设置后免弹窗)
// 开启"自动授权"后：App 调用 requestAuthorization 时不再向系统(及 usernoted)发请求，
// 系统也就不会弹出"XX想给你发送通知"；直接按本插件里该 App 的总开关回调 granted/denied，
// 使"抹除手机设置"后的授权状态与插件配置一致（未配置的 App 默认授权）。
static BOOL NTM_autoAuthOn(void) {
    // 默认开启：装上即免弹窗，符合“抹除设置后打开 App 就不出现授权框”的使用预期。
    // 用户仍可在面板里手动关闭（关闭后恢复系统原生弹窗）。
    id v = [NTM_prefs() objectForKey:@"NTM_autoAuth"];
    return v ? [v boolValue] : YES;
}

// 尽力把系统通知授权置为允许（与设置面板的 NTM_syncSystem 同理），让通知能真正送达。
// 无权限/失败时静默跳过，不影响"不弹窗"这一核心目标。
static void NTM_grantSystem(NSString *bid) {
    @try {
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (!cls) return;
        id gw = [[cls alloc] init];
        if (!gw) return;
        SEL s = NSSelectorFromString(@"sectionInfoForSectionID:");
        if (![gw respondsToSelector:s]) return;
        id info = [gw performSelector:s withObject:bid];
        if (!info) return;
        [info setValue:@(YES) forKey:@"allowsNotifications"];
        [info setValue:@(YES) forKey:@"showsInLockScreen"];
        [info setValue:@(YES) forKey:@"showsInNotificationCenter"];
        [info setValue:@(1) forKey:@"alertType"];
        [info setValue:@(63) forKey:@"pushSettings"]; // 声音+角标+横幅
        SEL set = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gw respondsToSelector:set]) [gw performSelector:set withObject:info withObject:bid];
    } @catch(NSException *e) {}
}

static void (*orig_requestAuth)(id, SEL, unsigned long long, id);
static void hook_requestAuth(id self, SEL _cmd, unsigned long long options, id handler) {
    if (NTM_autoAuthOn()) {
        NSString *bid = nil;
        @try { bid = [[NSBundle mainBundle] bundleIdentifier]; } @catch(NSException *e) {}
        BOOL granted = NTM_on(bid, @"en"); // 总开关：开=授权 关=拒绝（未配置默认开）
        if (granted) NTM_grantSystem(bid); // 尽力让系统真正允许，通知能送达
        if (handler) {
            @try {
                void (^block)(BOOL, NSError *) = (void (^)(BOOL, NSError *))handler;
                block(granted, nil);
            } @catch(NSException *e) {}
        }
        return; // 不调用 original → 系统不会弹出授权框
    }
    if (orig_requestAuth) orig_requestAuth(self, _cmd, options, handler);
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
// 全局快路径：面板维护"是否有 App 开了后台断网"。
// 缺省按"有"处理（兼容旧数据，避免误跳过导致功能失效）；只有明确为关时才跳过 KVC。
static BOOL NTM_anyBgNet(void) {
    @synchronized(NTM_cache()) {
        NSNumber *c = NTM_cache()[@"_bgNetAny"];
        if (c) return [c boolValue];
    }
    id v = [NTM_prefs() objectForKey:@"NTM_anyBgNet"];
    BOOL any = (v == nil) ? YES : [v boolValue];
    @synchronized(NTM_cache()) { NTM_cache()[@"_bgNetAny"] = @(any); }
    return any;
}

static void (*orig_bg)(id, SEL, id);
static void hook_bg(id self, SEL _cmd, id scene) {
    if (orig_bg) orig_bg(self, _cmd, scene);
    if (!NTM_anyBgNet()) return; // 没开任何后台断网 → 跳过 KVC
    NSString *bid = NTM_bundleIdOf(scene);
    if (bid.length && NTM_bgNetOn(bid)) NTM_applyNetPolicy(bid, 1); // 断网
}
static void (*orig_fg)(id, SEL, id);
static void hook_fg(id self, SEL _cmd, id scene) {
    // 先恢复网络策略再调用原函数：系统在 orig_fg 内部会评估要不要弹「允许使用无线数据」，
    // 如果策略还停留在"后台断网"状态，拦截 hook 又没拦住就会弹窗。
    if (NTM_anyBgNet()) {
        NSString *bid = NTM_bundleIdOf(scene);
        if (bid.length && NTM_bgNetOn(bid)) NTM_applyNetPolicy(bid, NTM_netRead(bid)); // 恢复保存的网络策略
    }
    if (orig_fg) orig_fg(self, _cmd, scene);
}

#pragma mark - 屏蔽「允许"XX"使用无线数据」启动弹窗
// 国行机在 App 蜂窝权限未确定时，App 一联网就弹「允许使用无线数据？」选择框。
// SpringBoard 在 App 进入前台时用 SBApplicationLaunchAlertEvaluatorForNetworkBasedAlertItems
// 评估要不要展示这类"网络类启动弹窗"。面板里设为「断网」的 App 直接判定为不展示，
// 达到「没网就是没网」，同时避免用户误点弹窗把权限改回允许、和面板设置对不上。
static NSString *NTM_appBundleId(id app) {
    NSString *bid = nil;
    @try { bid = [app bundleIdentifier]; } @catch(NSException *e) {}
    if (!bid.length) { @try { bid = [app valueForKeyPath:@"bundleIdentifier"]; } @catch(NSException *e) {} }
    return bid.length ? bid : nil;
}
static NSUInteger (*orig_shouldShowLaunchAlert)(id, SEL, id);
static NSUInteger hook_shouldShowLaunchAlert(id self, SEL _cmd, id app) {
    NSString *bid = NTM_appBundleId(app);
    // 断网 或 开启了后台断网 → 不展示（后台断网的App回前台时也会触发这个评估，需要一并拦住）
    if (bid.length && (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid))) return 0;
    if (orig_shouldShowLaunchAlert) return orig_shouldShowLaunchAlert(self, _cmd, app);
    return 0;
}
static void (*orig_showLaunchAlert)(id, SEL, NSUInteger, id);
static void hook_showLaunchAlert(id self, SEL _cmd, NSUInteger type, id app) {
    NSString *bid = NTM_appBundleId(app);
    // 断网 或 开启了后台断网 → 不展示
    if (bid.length && (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid))) return;
    if (orig_showLaunchAlert) orig_showLaunchAlert(self, _cmd, type, app);
}

#pragma mark - 直接拦截 CommCenter 的「允许"XX"使用无线数据」请求（不弹窗）
// 实测(iOS 16.6)：该弹窗由 CommCenter 给 SpringBoard 发消息，经
// +[SBUserNotificationCenter dispatchUserNotification:flags:replyPort:auditToken:] 创建，
// 消息字典里只有 AlertSource / AlertHeader(App 中文名)，没有 bundle id。
// 前面 hook 的 SBApplicationLaunchAlertEvaluator* 只覆盖「App 启动评估」这条路，
// CommCenter 直发的请求不经过它，所以还会漏弹。
// 这里对面板里设为「断网」的 App 直接回一条「不允许」报文，不创建弹窗。
// 回「不允许」写的是系统数据策略，和面板 NTM_applyNetPolicy 同源，
// 解除断网后面板会把它同步回允许，不会留下和面板不一致的残留状态。
//
// 报文格式为实测值（frida 抓 mach_msg 得到）：
//   28 字节 = 24 字节头 + 4 字节体；msgh_bits=0x12(COPY_SEND)、msgh_id=0；
//   体为 uint32 响应码，0 = Default = 「不允许」。
static void NTM_sendDenyReply(uint64_t replyPort) {
    if (!replyPort) return;
    struct {
        mach_msg_header_t header;
        uint32_t response;
    } msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSGH_BITS_ZERO);
    msg.header.msgh_size = (mach_msg_size_t)sizeof(msg); // 28
    msg.header.msgh_remote_port = (mach_port_t)replyPort;
    msg.header.msgh_id = 0;
    msg.response = 0; // 0 = Default = 「不允许」
    @try {
        mach_msg(&msg.header, MACH_SEND_MSG, (mach_msg_size_t)sizeof(msg),
                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    } @catch (NSException *e) {}
}

// 「允许“微信”使用无线数据？」→ 微信
static NSString *NTM_appNameOfHeader(NSString *header) {
    if (!header.length) return nil;
    NSArray *quotes = @[@[@"\u201C", @"\u201D"], @[@"\"", @"\""]];
    for (NSArray *q in quotes) {
        NSRange l = [header rangeOfString:q[0]];
        if (l.location == NSNotFound) continue;
        NSUInteger from = NSMaxRange(l);
        if (from >= header.length) continue;
        NSRange r = [header rangeOfString:q[1]
                                  options:0
                                    range:NSMakeRange(from, header.length - from)];
        if (r.location == NSNotFound) continue;
        NSString *name = [header substringWithRange:NSMakeRange(from, r.location - from)];
        if (name.length) return name;
    }
    return nil;
}

// App 中文名 → bundle id：遍历已安装 App，优先精确匹配本地化名，
// 匹配不到再退回「本地化名是该名字的子串」中最长的那个。
static NSString *NTM_bundleIdOfName(NSString *name) {
    if (!name.length) return nil;
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        SEL selWS = NSSelectorFromString(@"defaultWorkspace");
        if (!wsCls || ![wsCls respondsToSelector:selWS]) return nil;
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, selWS);
        SEL selAll = NSSelectorFromString(@"allInstalledApplications");
        if (!ws || ![ws respondsToSelector:selAll]) return nil;
        id arr = ((id (*)(id, SEL))objc_msgSend)(ws, selAll);
        if (!arr) return nil;
        NSUInteger n = [arr count];
        NSString *exact = nil, *partial = nil;
        NSUInteger partialLen = 0;
        for (NSUInteger i = 0; i < n; i++) {
            id proxy = [arr objectAtIndex:i];
            NSString *nm = nil, *bid = nil;
            SEL sName = NSSelectorFromString(@"localizedName");
            if ([proxy respondsToSelector:sName])
                nm = ((id (*)(id, SEL))objc_msgSend)(proxy, sName);
            SEL sBid = NSSelectorFromString(@"applicationIdentifier");
            if ([proxy respondsToSelector:sBid])
                bid = ((id (*)(id, SEL))objc_msgSend)(proxy, sBid);
            if (!nm.length || !bid.length) continue;
            if ([nm isEqualToString:name]) {
                if (!exact) exact = bid;
            } else if (nm.length > partialLen && [name rangeOfString:nm].location != NSNotFound) {
                partial = bid;
                partialLen = nm.length;
            }
            if (exact) break;
        }
        return exact ?: partial;
    } @catch (NSException *e) {}
    return nil;
}

// 这条 CommCenter 请求是不是「面板里已断网的 App」
static BOOL NTM_shouldDenyWirelessAlert(id msg) {
    @try {
        if (!msg) return NO;
        NSString *src = [msg objectForKey:@"AlertSource"];
        if (![src isKindOfClass:[NSString class]] || ![src isEqualToString:@"CommCenter"]) return NO;
        NSString *hdr = [msg objectForKey:@"AlertHeader"];
        if (![hdr isKindOfClass:[NSString class]] || ![hdr containsString:@"使用无线数据"]) return NO;
        NSString *bid = NTM_bundleIdOfName(NTM_appNameOfHeader(hdr));
        if (!bid.length) return NO;
        // 与前面启动弹窗 hook 同一条件：断网 或 开了后台断网
        return (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid));
    } @catch (NSException *e) { return NO; }
}

// auditToken 是结构体（>16 字节）时按指针传，这里统一用 void* 承接并原样透传
static void (*orig_dispatch)(id, SEL, id, uint64_t, uint64_t, void *);
static void hook_dispatch(id self, SEL _cmd, id msg, uint64_t flags,
                          uint64_t replyPort, void *auditToken) {
    if (NTM_shouldDenyWirelessAlert(msg)) {
        NTM_sendDenyReply(replyPort); // 回「不允许」，不创建弹窗
        return;
    }
    if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
}

static void tryHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

// 类方法版本（dispatchUserNotification 是 + 方法）
static void tryHookMeta(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getClassMethod(cls, sel);
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

        // 自动授权通知默认开启：保证重装/抹除后打开 App 不再弹授权框（面板可手动关）
        [NTM_prefs() registerDefaults:@{@"NTM_autoAuth": @YES}];

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

        // 自动授权通知权限（注入 App 进程，需 Tweak.plist 含 Classes=UNUserNotificationCenter）
        tryHook(objc_getClass("UNUserNotificationCenter"),
                sel_registerName("requestAuthorizationWithOptions:completionHandler:"),
                (IMP)hook_requestAuth, (IMP *)&orig_requestAuth);

        // 屏蔽「允许"XX"使用无线数据」启动弹窗（面板里设为断网的 App）
        tryHook(objc_getClass("SBApplicationLaunchAlertEvaluatorForNetworkBasedAlertItems"),
                sel_registerName("shouldShowLaunchAlertForApplication:"),
                (IMP)hook_shouldShowLaunchAlert, (IMP *)&orig_shouldShowLaunchAlert);
        tryHook(objc_getClass("SBApplicationLaunchAlertService"),
                sel_registerName("showLaunchAlertOfType:forApplication:"),
                (IMP)hook_showLaunchAlert, (IMP *)&orig_showLaunchAlert);

        // 直接拦截 CommCenter 直发的「允许"XX"使用无线数据」请求（回「不允许」，不弹窗）
        tryHookMeta(objc_getClass("SBUserNotificationCenter"),
                    sel_registerName("dispatchUserNotification:flags:replyPort:auditToken:"),
                    (IMP)hook_dispatch, (IMP *)&orig_dispatch);
    }
}