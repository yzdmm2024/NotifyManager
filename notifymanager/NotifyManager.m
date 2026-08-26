// NotifyManager.m — 通知管理设置面板（自定义现代 UI）
// 枚举已安装 App，按分类(用户/巨魔/系统)展示
// 每个 App：总开关 + 锁定屏幕/通知中心/横幅/声音/标记 子开关 + 单应用重置
// 增强功能：仅隐藏角标 / 隐藏预览 / 后台自动断网 / 关键词过滤 / 分组
// 网络策略按钮：打开wifi/流量/wifi+流量/断网
// 顶部：模式快照 / 应用分组 / 拦截日志；批量开启/关闭/自定义；筛选；搜索
// 列表使用 UITableView 虚拟化，切换分类/搜索即时响应
// 配置保存到 NSUserDefaults suiteName，Tweak 读取并拦截通知/断网
// 设置变更时同步到系统通知设置 (BBSettingsGateway) 与蜂窝网络 (PSAppDataUsagePolicyCache)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 接口声明
@interface PSAppDataUsagePolicyCache : NSObject
+ (instancetype)sharedInstance;
- (void)setUsagePoliciesForBundle:(NSString *)bundleId cellular:(BOOL)cellular wifi:(BOOL)wifi;
@end

static NSDictionary *NTM_cellularPolicies(void);
static NSInteger NTM_netReadSystem(NSString *appId);
@interface PSViewController : UIViewController
@end

@interface NTMPrincipalController : PSViewController <UISearchBarDelegate, UIDocumentPickerDelegate, UITableViewDelegate, UITableViewDataSource>
@end

// 拦截日志显示页
@interface NTMLogViewController : UITableViewController
@end

#pragma mark - 存储: NSUserDefaults suiteName (Tweak 读取同一份)
static NSString *NTM_suite = @"com.ntm.notifymanager";
static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static NSUserDefaults *NTM_prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    });
    return prefs;
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
static BOOL NTM_readWith(NSUserDefaults *prefs, NSString *appId, NSString *dim) {
    id v = [prefs objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
// 增强开关：未设置默认关闭
static BOOL NTM_feat(NSString *appId, NSString *key) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, key)];
    return v ? [v boolValue] : NO;
}
static void NTM_postConfigChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ntm.notifymanager.configChanged"),
                                         NULL, NULL, YES);
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    [NTM_prefs() setBool:val forKey:NTM_key(appId, dim)];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 网络权限存储
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static NSString *NTM_netKey(NSString *appId) {
    return [NSString stringWithFormat:@"NTM_net_%@", appId];
}
static NSInteger NTM_netReadSystem(NSString *appId) {
    NSDictionary *ap = NTM_cellularPolicies();
    NSDictionary *policy = ap[appId];
    if (![policy isKindOfClass:[NSDictionary class]]) return 0;
    NSString *cell = policy[@"kCTCellularDataUsagePolicy"];
    NSString *wifi = policy[@"kCTWiFiDataUsagePolicy"];
    BOOL cellOn = cell.length && [cell containsString:@"Allow"];
    BOOL wifiOn = wifi.length && [wifi containsString:@"Allow"];
    if (cellOn && wifiOn) return 0;
    if (!cellOn && !wifiOn) return 1;
    if (wifiOn) return 2;
    return 3;
}
static NSInteger NTM_netRead(NSString *appId) {
    id v = [NTM_prefs() objectForKey:NTM_netKey(appId)];
    if (v) return [v integerValue];
    return NTM_netReadSystem(appId);
}
static void NTM_netWrite(NSString *appId, NSInteger policy) {
    [NTM_prefs() setInteger:policy forKey:NTM_netKey(appId)];
    [NTM_prefs() synchronize];
}
static NSArray *NTM_netOptions(void) {
    return @[
        @{@"title":@"打开wifi", @"policy":@2},
        @{@"title":@"流量",     @"policy":@3},
        @{@"title":@"wifi+流量", @"policy":@0},
        @{@"title":@"断网",     @"policy":@1},
    ];
}
static UIColor *NTM_netColor(NSInteger policy) {
    switch (policy) {
        case 1: return [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1];
        case 2: return [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1];
        case 3: return [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1];
        default: return [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1];
    }
}

#pragma mark - 关键词存储 (NSString JSON 数组 / NSArray)
static NSArray *NTM_kwList(NSString *appId) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, @"kw")];
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
        NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSArray class]]) return parsed;
    }
    return @[];
}
static void NTM_kwSave(NSString *appId, NSArray *list) {
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in list) {
        NSString *t = [(s ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [clean addObject:t];
    }
    if (clean.count) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:clean options:0 error:nil];
        [NTM_prefs() setObject:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] forKey:NTM_key(appId, @"kw")];
    } else {
        [NTM_prefs() removeObjectForKey:NTM_key(appId, @"kw")];
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 分组存储
static NSArray *NTM_groupNames(void) {
    NSArray *arr = [NTM_prefs() objectForKey:@"NTM_groupNames"];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}
static void NTM_setGroup(NSString *appId, NSString *name) {
    if (name.length) {
        [NTM_prefs() setObject:name forKey:NTM_key(appId, @"group")];
    } else {
        [NTM_prefs() removeObjectForKey:NTM_key(appId, @"group")];
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}
static void NTM_addGroupName(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    NSMutableArray *arr = [NTM_groupNames() mutableCopy];
    if (![arr containsObject:name]) [arr addObject:name];
    [NTM_prefs() setObject:arr forKey:@"NTM_groupNames"];
    [NTM_prefs() synchronize];
}
static void NTM_removeGroupName(NSString *name) {
    NSMutableArray *arr = [NTM_groupNames() mutableCopy];
    [arr removeObject:name];
    [NTM_prefs() setObject:arr forKey:@"NTM_groupNames"];
    // 该组下所有 App 回到未分组
    for (NSString *k in [NTM_prefs() dictionaryRepresentation].allKeys) {
        if ([k hasPrefix:@"NTM_group_"] && [[NTM_prefs() objectForKey:k] isEqualToString:name]) {
            [NTM_prefs() removeObjectForKey:k];
        }
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 同步到系统通知设置 (BBSettingsGateway)
static id NTM_gateway(void) {
    static id gw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (cls) gw = [[cls alloc] init];
    });
    return gw;
}
static dispatch_queue_t NTM_syncQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.ntm.sync", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void NTM_syncSystem(NSString *appId) {
    if (!appId.length) return;
    @try {
        id gateway = NTM_gateway();
        if (!gateway) return;
        id info = [gateway performSelector:@selector(sectionInfoForSectionID:) withObject:appId];
        if (!info) return;
        BOOL en = NTM_read(appId, @"en");
        BOOL lock = NTM_read(appId, @"lock");
        BOOL nc = NTM_read(appId, @"nc");
        BOOL banner = NTM_read(appId, @"banner");
        BOOL anyVisible = lock || nc || banner;
        BOOL sound = en && anyVisible && NTM_read(appId, @"sound");
        BOOL badge = en && anyVisible && NTM_read(appId, @"badge");
        [info setValue:@(en) forKey:@"allowsNotifications"];
        [info setValue:@(lock) forKey:@"showsInLockScreen"];
        [info setValue:@(nc) forKey:@"showsInNotificationCenter"];
        [info setValue:@(banner ? 1 : 0) forKey:@"alertType"];
        NSUInteger push = 0;
        if (sound) push |= 18;
        if (badge) push |= 9;
        if (banner) push |= 36;
        [info setValue:@(push) forKey:@"pushSettings"];
        SEL setSel = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gateway respondsToSelector:setSel]) {
            [gateway performSelector:setSel withObject:info withObject:appId];
        }
        NSLog(@"[NTM] sync %@ en=%d lock=%d nc=%d banner=%d sound=%d badge=%d push=%lu",
              appId, en, lock, nc, banner, sound, badge, (unsigned long)push);
    } @catch(NSException *e) {
        NSLog(@"[NTM] sync %@ exception %@", appId, e);
    }
}
static void NTM_syncSystemAsync(NSString *appId) {
    if (!appId.length) return;
    dispatch_async(NTM_syncQueue(), ^{ NTM_syncSystem(appId); });
}

#pragma mark - 同步到系统蜂窝网络设置
static NSDictionary *NTM_cellularPolicies(void) {
    static NSDictionary *dict = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.apple.cellularplan.plist"];
        id ap = root[@"AppPolicy"];
        if ([ap isKindOfClass:[NSDictionary class]]) dict = ap;
    });
    return dict;
}
static void NTM_syncCellular(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    BOOL cellular = (policy == 0 || policy == 3);
    BOOL wifi = (policy == 0 || policy == 2);
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) {
            dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
            cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        }
        if (cls) {
            id cache = [(id)cls sharedInstance];
            if (cache) {
                [cache setUsagePoliciesForBundle:appId cellular:cellular wifi:wifi];
                NSLog(@"[NTM] cellular %@ policy=%ld (PSAppDataUsagePolicyCache)", appId, (long)policy);
                return;
            }
        }
    } @catch(NSException *e) {
        NSLog(@"[NTM] cellular %@ PSAppDataUsagePolicyCache exception %@", appId, e);
    }
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
    } @catch(NSException *e) {
        NSLog(@"[NTM] cellular %@ exception %@", appId, e);
    }
}
static void NTM_syncCellularAsync(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    dispatch_async(NTM_syncQueue(), ^{ NTM_syncCellular(appId, policy); });
}

#pragma mark - 维度定义
static NSArray *NTM_dims(void) {
    return @[
        @{@"key":@"lock",   @"title":@"锁定屏幕"},
        @{@"key":@"nc",     @"title":@"通知中心"},
        @{@"key":@"banner", @"title":@"横幅"},
        @{@"key":@"sound",  @"title":@"声音"},
        @{@"key":@"badge",  @"title":@"标记"},
    ];
}

#pragma mark - 系统通知 section
static NSArray *NTM_systemSections(void) {
    static NSArray *arr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *out = [NSMutableArray array];
        @try {
            id gateway = NTM_gateway();
            if (gateway) {
                id sections = nil;
                SEL sels[] = {NSSelectorFromString(@"sectionInfoList"),
                              NSSelectorFromString(@"allSectionInfo"),
                              NSSelectorFromString(@"sectionInfos")};
                for (int i = 0; i < 3 && !sections; i++) {
                    if ([gateway respondsToSelector:sels[i]]) sections = [gateway performSelector:sels[i]];
                }
                NSArray *secList = nil;
                if ([sections isKindOfClass:[NSArray class]]) secList = sections;
                else if ([sections isKindOfClass:[NSDictionary class]]) secList = [sections allValues];
                for (id info in secList) {
                    NSString *sid = nil;
                    @try { sid = [info performSelector:@selector(sectionID)]; } @catch(NSException *e) {}
                    if (!sid.length) { @try { sid = [info performSelector:@selector(sectionIdentifier)]; } @catch(NSException *e) {} }
                    if (!sid.length) continue;
                    NSString *name = nil;
                    @try { name = [info performSelector:@selector(sectionName)]; } @catch(NSException *e) {}
                    if (!name.length) { @try { name = [info performSelector:@selector(displayName)]; } @catch(NSException *e) {} }
                    if (!name.length) name = sid;
                    [out addObject:@{@"id":sid, @"name":name}];
                }
            }
        } @catch(NSException *e) {}
        arr = [out copy];
    });
    return arr;
}
static NSSet *NTM_notifSet(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
        for (NSDictionary *sec in NTM_systemSections()) [set addObject:sec[@"id"]];
    });
    return set;
}
static BOOL NTM_hasNotifications(NSString *appId) {
    NSSet *s = NTM_notifSet();
    if (!s.count) return YES;
    return [s containsObject:appId];
}

#pragma mark - 枚举 App (LSApplicationWorkspace)
static NSString *NTM_catOfProxy(id proxy) {
    NSString *type = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationType")) ?: @"";
    NSString *bid  = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier")) ?: @"";
    if ([type isEqualToString:@"System"]) {
        return ([bid hasPrefix:@"com.apple."]) ? @"系统应用" : @"巨魔应用";
    }
    NSString *teamID = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("teamID")) ?: @"";
    BOOL appleSign = (teamID.length && ![teamID isEqualToString:@"adhoc"] && ![teamID isEqualToString:@"AdHoc"]);
    return appleSign ? @"用户应用" : @"巨魔应用";
}
static UIImage *NTM_iconFor(NSString *bid) {
    if (!bid.length) return nil;
    @try {
        id (*f)(id,SEL,id,long long,double) = (id(*)(id,SEL,id,long long,double))objc_msgSend;
        id icon = f((id)UIImage.class, sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:"), bid, 0, 2.0);
        if (icon && [icon isKindOfClass:UIImage.class]) return (UIImage *)icon;
    } @catch(NSException *e) {}
    return nil;
}
static NSArray *NTM_allApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class wk = objc_getClass("LSApplicationWorkspace");
    if (!wk) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        wk = objc_getClass("LSApplicationWorkspace");
    }
    if (!wk) return out;
    id ws = ((id(*)(id,SEL))objc_msgSend)((id)wk, sel_registerName("defaultWorkspace"));
    if (!ws) return out;
    NSArray *proxies = ((id(*)(id,SEL))objc_msgSend)(ws, sel_registerName("allApplications"));
    NSMutableSet *installed = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *bid = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        if (bid.length) [installed addObject:bid];
    }
    for (id proxy in proxies) {
        NSString *bid  = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        NSURL *url     = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
        NSString *name = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("localizedName"));
        NSString *path = [(NSURL *)url path] ?: @"";
        if (!bid.length || !path.length) continue;
        NSString *cat = NTM_catOfProxy(proxy);
        if ([cat isEqualToString:@"系统应用"]) {
            if (![path hasPrefix:@"/Applications/"]) continue;
            if (!NTM_hasNotifications(bid)) continue;
        }
        [out addObject:@{ @"id":bid, @"name":(name.length?name:bid), @"cat":cat, @"icon":[NSNull null] }];
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *app in out) [seen addObject:app[@"id"]];
    for (NSDictionary *sec in NTM_systemSections()) {
        NSString *sid = sec[@"id"];
        if ([seen containsObject:sid]) continue;
        if (![installed containsObject:sid]) continue;
        if (![sid hasPrefix:@"com.apple."]) continue;
        [seen addObject:sid];
        [out addObject:@{@"id":sid, @"name":sec[@"name"], @"cat":@"系统应用", @"icon":[NSNull null]}];
    }
    NSArray *order = @[@"用户应用", @"巨魔应用", @"系统应用"];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        NSInteger ia = [order indexOfObject:a[@"cat"]];
        NSInteger ib = [order indexOfObject:b[@"cat"]];
        if (ia != ib) return ia<ib ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}
// App id -> 显示名（拦截日志等场景）
static NSDictionary *NTM_nameMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSDictionary *app in NTM_allApps()) if (app[@"name"]) d[app[@"id"]] = app[@"name"];
        map = [d copy];
    });
    return map;
}
// 显示名（可复用的解析，appId可能不在已装列表）
static NSString *NTM_dispName(NSString *appId) {
    NSString *n = NTM_nameMap()[appId];
    return n.length ? n : appId;
}

#pragma mark - 状态 tag 构造
static UILabel *NTM_tag(NSString *text, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    l.textColor = color;
    l.backgroundColor = [color colorWithAlphaComponent:0.13];
    l.layer.cornerRadius = 7;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    // 重要：让标签保持自身宽度，不被栈拉伸撑满整行
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

#pragma mark - App 卡片视图
@interface NTMAppCardView : UIView
@property (nonatomic, strong) NSString *appId;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) NSMutableArray *dimSwitches;
@property (nonatomic, strong) NSMutableArray *netButtons;
@property (nonatomic, strong) UISwitch *noBadgeSwitch;
@property (nonatomic, strong) UISwitch *noPreviewSwitch;
@property (nonatomic, strong) UISwitch *bgNetSwitch;
@property (nonatomic, strong) UIStackView *statusRow;
@property (nonatomic, copy) void (^onDimChange)(NSString *appId, NSString *dim, BOOL val);
@property (nonatomic, copy) void (^onMasterChange)(NSString *appId, BOOL val);
@property (nonatomic, copy) void (^onNetChange)(NSString *appId, NSInteger policy);
@property (nonatomic, copy) void (^onReset)(NSString *appId);
@property (nonatomic, copy) void (^onFeatChange)(NSString *appId, NSString *key, BOOL val);
@property (nonatomic, copy) void (^onKeywordEdit)(NSString *appId);
@property (nonatomic, copy) void (^onGroupPick)(NSString *appId);
- (instancetype)initWithApp:(NSDictionary *)app;
- (void)reloadFromPrefs;
@end

@implementation NTMAppCardView

- (instancetype)initWithApp:(NSDictionary *)app {
    self = [super init];
    if (self) {
        _appId = app[@"id"];
        _dimSwitches = [NSMutableArray array];
        _netButtons = [NSMutableArray array];
        self.backgroundColor = [UIColor whiteColor];
        self.layer.cornerRadius = 16;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.06;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        [self buildUI:app];
    }
    return self;
}

// 构造一个 "标签+开关" 的竖向单元（行内均分宽度，开关列自动对齐）
- (UIView *)swCell:(NSString *)title sw:(UISwitch *)sw {
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.32 alpha:1];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.adjustsFontSizeToFitWidth = YES;
    lbl.minimumScaleFactor = 0.8;
    sw.transform = CGAffineTransformMakeScale(0.68, 0.68);
    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[lbl, sw]];
    item.axis = UILayoutConstraintAxisVertical;
    item.alignment = UIStackViewAlignmentCenter;
    item.spacing = 3;
    return item;
}

- (void)buildUI:(NSDictionary *)app {
    NSArray *dims = NTM_dims();

    // 头部行：图标 + 名称 + 重置 + 总开关
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 8;
    iconView.clipsToBounds = YES;
    iconView.backgroundColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:1];
    [iconView.widthAnchor constraintEqualToConstant:32].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:32].active = YES;
    NSString *bid = _appId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *icon = NTM_iconFor(bid);
        if (!icon) return;
        dispatch_async(dispatch_get_main_queue(), ^{ iconView.image = icon; });
    });

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = app[@"name"];
    nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor colorWithWhite:0.13 alpha:1];
    [nameLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"重置" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *masterLabel = [[UILabel alloc] init];
    masterLabel.text = @"总开关";
    masterLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    masterLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];

    UISwitch *master = [[UISwitch alloc] init];
    [master addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
    _masterSwitch = master;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, nameLabel, resetBtn, masterLabel, master]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;

    // 状态标签行（纵向容器，内分两行铺标签，避免一行塞不下溢出）
    _statusRow = [[UIStackView alloc] init];
    _statusRow.axis = UILayoutConstraintAxisVertical;
    _statusRow.alignment = UIStackViewAlignmentLeading;
    _statusRow.spacing = 4;

    // 子开关行：5 个维度横排
    NSMutableArray *dimItems = [NSMutableArray array];
    for (NSDictionary *d in dims) {
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(dimChanged:) forControlEvents:UIControlEventValueChanged];
        [_dimSwitches addObject:sw];
        [dimItems addObject:[self swCell:d[@"title"] sw:sw]];
    }
    UIStackView *dimRow = [[UIStackView alloc] initWithArrangedSubviews:dimItems];
    dimRow.axis = UILayoutConstraintAxisHorizontal;
    dimRow.distribution = UIStackViewDistributionFillEqually;
    dimRow.alignment = UIStackViewAlignmentCenter;
    dimRow.spacing = 4;

    // 增强功能行：仅隐藏角标 / 隐藏预览 / 后台自动断网
    _noBadgeSwitch = [[UISwitch alloc] init];
    [_noBadgeSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    _noPreviewSwitch = [[UISwitch alloc] init];
    [_noPreviewSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    _bgNetSwitch = [[UISwitch alloc] init];
    [_bgNetSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *featRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self swCell:@"仅隐藏角标" sw:_noBadgeSwitch],
        [self swCell:@"隐藏预览" sw:_noPreviewSwitch],
        [self swCell:@"后台断网" sw:_bgNetSwitch],
    ]];
    featRow.axis = UILayoutConstraintAxisHorizontal;
    featRow.distribution = UIStackViewDistributionFillEqually;
    featRow.alignment = UIStackViewAlignmentCenter;
    featRow.spacing = 6;

    // 关键词 + 分组 行
    UIButton *kwBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [kwBtn setTitle:@"关键词过滤" forState:UIControlStateNormal];
    kwBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    kwBtn.layer.cornerRadius = 8;
    kwBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.15];
    [kwBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1] forState:UIControlStateNormal];
    [kwBtn addTarget:self action:@selector(keywordTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *grpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [grpBtn setTitle:@"分组" forState:UIControlStateNormal];
    grpBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    grpBtn.layer.cornerRadius = 8;
    grpBtn.backgroundColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:0.15];
    [grpBtn setTitleColor:[UIColor colorWithRed:0.20 green:0.40 blue:0.80 alpha:1] forState:UIControlStateNormal];
    [grpBtn addTarget:self action:@selector(groupTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *btnRow = [[UIStackView alloc] initWithArrangedSubviews:@[kwBtn, grpBtn]];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    btnRow.spacing = 8;
    [kwBtn.heightAnchor constraintEqualToConstant:26].active = YES;
    [grpBtn.heightAnchor constraintEqualToConstant:26].active = YES;

    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[header, _statusRow, dimRow, featRow, btnRow]];
    [rows addObject:[self buildNetRow]];
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:rows];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 9;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [v.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
    ]];

    [self reloadStatus];
}

- (UIView *)buildNetRow {
    UILabel *netLabel = [[UILabel alloc] init];
    netLabel.text = @"网络";
    netLabel.font = [UIFont systemFontOfSize:11];
    netLabel.textColor = [UIColor colorWithWhite:0.33 alpha:1];
    [netLabel.widthAnchor constraintEqualToConstant:34].active = YES;

    NSMutableArray *btns = [NSMutableArray array];
    for (NSDictionary *opt in NTM_netOptions()) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:opt[@"title"] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        btn.layer.cornerRadius = 8;
        btn.tag = [opt[@"policy"] integerValue];
        [btn addTarget:self action:@selector(netTapped:) forControlEvents:UIControlEventTouchUpInside];
        [btn.heightAnchor constraintEqualToConstant:28].active = YES;
        [btns addObject:btn];
        [_netButtons addObject:btn];
    }
    UIStackView *netRow = [[UIStackView alloc] initWithArrangedSubviews:btns];
    netRow.axis = UILayoutConstraintAxisHorizontal;
    netRow.distribution = UIStackViewDistributionFillEqually;
    netRow.alignment = UIStackViewAlignmentCenter;
    netRow.spacing = 6;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[netLabel, netRow]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    return row;
}

- (void)reloadStatus {
    for (UIView *v in _statusRow.arrangedSubviews) {
        [_statusRow removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    // 主行：通知状态 + 网络状态
    NSMutableArray *primary = [NSMutableArray array];
    BOOL en = NTM_read(_appId, @"en");
    if (!en) {
        [primary addObject:NTM_tag(@"通知关闭", [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1])];
    } else {
        BOOL allOn = YES;
        for (NSDictionary *d in NTM_dims()) if (!NTM_read(_appId, d[@"key"])) { allOn = NO; break; }
        [primary addObject:NTM_tag(allOn ? @"通知全开" : @"部分开启",
                                   allOn ? [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1]
                                         : [UIColor colorWithRed:0.95 green:0.60 blue:0.15 alpha:1])];
    }
    NSInteger net = NTM_netRead(_appId);
    BOOL netOff = (net == 1);
    [primary addObject:NTM_tag(netOff ? @"断网" : @"正常联网",
                               netOff ? [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1]
                                      : [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1])];

    // 副行：增强项 + 分组（有内容才显示，避免一排"—"）
    NSMutableArray *feats = [NSMutableArray array];
    if (NTM_feat(_appId, @"noBadge")) [feats addObject:@"仅隐角标"];
    if (NTM_feat(_appId, @"noPreview")) [feats addObject:@"隐预览"];
    if (NTM_feat(_appId, @"bgNet")) [feats addObject:@"后台断网"];
    NSString *grp = [NTM_prefs() objectForKey:NTM_key(_appId, @"group")];
    NSMutableArray *sub = [NSMutableArray array];
    if (feats.count) {
        [sub addObject:NTM_tag(feats.count ? [feats componentsJoinedByString:@"+"] : @"—",
                               [UIColor colorWithRed:0.40 green:0.45 blue:0.55 alpha:1])];
    }
    if (grp.length) {
        [sub addObject:NTM_tag(grp, [UIColor colorWithRed:0.55 green:0.40 blue:0.90 alpha:1])];
    }

    // 组装两行
    UIStackView *rowA = [[UIStackView alloc] initWithArrangedSubviews:primary];
    rowA.axis = UILayoutConstraintAxisHorizontal;
    rowA.alignment = UIStackViewAlignmentCenter;
    rowA.spacing = 6;
    rowA.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusRow addArrangedSubview:rowA];
    if (sub.count) {
        UIStackView *rowB = [[UIStackView alloc] initWithArrangedSubviews:sub];
        rowB.axis = UILayoutConstraintAxisHorizontal;
        rowB.alignment = UIStackViewAlignmentCenter;
        rowB.spacing = 6;
        rowB.translatesAutoresizingMaskIntoConstraints = NO;
        [_statusRow addArrangedSubview:rowB];
    }
    for (UILabel *t in primary) [t.heightAnchor constraintEqualToConstant:16].active = YES;
    for (UILabel *t in sub) [t.heightAnchor constraintEqualToConstant:16].active = YES;
}

- (void)netTapped:(UIButton *)sender {
    NSInteger policy = sender.tag;
    NTM_netWrite(_appId, policy);
    [self updateNetButtons];
    NTM_syncCellularAsync(_appId, policy);
    if (_onNetChange) _onNetChange(_appId, policy);
}

- (void)updateNetButtons {
    NSInteger policy = NTM_netRead(_appId);
    for (UIButton *btn in _netButtons) {
        BOOL selected = (btn.tag == policy);
        if (selected) {
            btn.backgroundColor = [NTM_netColor(policy) colorWithAlphaComponent:0.18];
            [btn setTitleColor:NTM_netColor(policy) forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
            [btn setTitleColor:[UIColor colorWithWhite:0.42 alpha:1] forState:UIControlStateNormal];
        }
    }
}

- (void)masterChanged:(UISwitch *)sender {
    NSUserDefaults *prefs = NTM_prefs();
    [prefs setBool:sender.on forKey:NTM_key(_appId, @"en")];
    for (NSDictionary *d in NTM_dims()) [prefs setBool:sender.on forKey:NTM_key(_appId, d[@"key"])];
    [prefs synchronize];
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onMasterChange) _onMasterChange(_appId, sender.on);
}

- (void)dimChanged:(UISwitch *)sender {
    NSUInteger idx = [_dimSwitches indexOfObject:sender];
    if (idx == NSNotFound || idx >= NTM_dims().count) return;
    NSDictionary *d = NTM_dims()[idx];
    NTM_write(_appId, d[@"key"], sender.on);
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onDimChange) _onDimChange(_appId, d[@"key"], sender.on);
}

// 增强功能开关
- (void)featChanged:(UISwitch *)sender {
    NSString *key = nil;
    if (sender == _noBadgeSwitch) key = @"noBadge";
    else if (sender == _noPreviewSwitch) key = @"noPreview";
    else if (sender == _bgNetSwitch) key = @"bgNet";
    if (!key) return;
    [NTM_prefs() setBool:sender.on forKey:NTM_key(_appId, key)];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    if (_onFeatChange) _onFeatChange(_appId, key, sender.on);
}

- (void)keywordTapped {
    if (_onKeywordEdit) _onKeywordEdit(_appId);
}
- (void)groupTapped {
    if (_onGroupPick) _onGroupPick(_appId);
}

- (void)resetTapped {
    NSUserDefaults *prefs = NTM_prefs();
    [prefs setBool:YES forKey:NTM_key(_appId, @"en")];
    for (NSDictionary *d in NTM_dims()) [prefs setBool:YES forKey:NTM_key(_appId, d[@"key"])];
    [prefs setBool:NO forKey:NTM_key(_appId, @"noBadge")];
    [prefs setBool:NO forKey:NTM_key(_appId, @"noPreview")];
    [prefs setBool:NO forKey:NTM_key(_appId, @"bgNet")];
    [prefs removeObjectForKey:NTM_key(_appId, @"kw")];
    [prefs synchronize];
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onReset) _onReset(_appId);
}

- (void)reloadFromPrefs {
    BOOL en = NTM_read(_appId, @"en");
    _masterSwitch.on = en;
    NSArray *dims = NTM_dims();
    BOOL anyVisible = NTM_read(_appId, @"lock") || NTM_read(_appId, @"nc") || NTM_read(_appId, @"banner");
    BOOL soundBadgeEnabled = en && anyVisible;
    for (NSUInteger i = 0; i < dims.count && i < _dimSwitches.count; i++) {
        UISwitch *sw = _dimSwitches[i];
        sw.on = NTM_read(_appId, dims[i][@"key"]);
        if (i == 3 || i == 4) sw.enabled = soundBadgeEnabled;
    }
    _noBadgeSwitch.on = NTM_feat(_appId, @"noBadge");
    _noPreviewSwitch.on = NTM_feat(_appId, @"noPreview");
    _bgNetSwitch.on = NTM_feat(_appId, @"bgNet");
    [self updateNetButtons];
    [self reloadStatus];
}

@end

#pragma mark - 拦截日志页
@implementation NTMLogViewController {
    NSArray *_entries;
    NSArray *_typeMaps;
    UIBarButtonItem *_emptyBtn;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"拦截日志";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self action:@selector(done)];
    _emptyBtn = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItem = _emptyBtn;
    _typeMaps = @[
        @{@"k":@"notif", @"t":@"拦截通知", @"c":[UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1]},
        @{@"k":@"banner", @"t":@"拦截横幅", @"c":[UIColor colorWithRed:0.95 green:0.60 blue:0.15 alpha:1]},
        @{@"k":@"sound", @"t":@"拦截声音", @"c":[UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1]},
        @{@"k":@"badge", @"t":@"角标", @"c":[UIColor colorWithRed:0.55 green:0.40 blue:0.90 alpha:1]},
        @{@"k":@"kw", @"t":@"关键词过滤", @"c":[UIColor colorWithRed:0.87 green:0.35 blue:0.55 alpha:1]},
        @{@"k":@"bgNet", @"t":@"后台断网", @"c":[UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1]},
    ];
    [self reloadEntries];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reloadEntries {
    NSArray *arr = [NTM_prefs() objectForKey:@"NTM_log"];
    _entries = [arr isKindOfClass:[NSArray class]] ? arr : @[];
    [self.tableView reloadData];
}
- (void)clearLog {
    [NTM_prefs() removeObjectForKey:@"NTM_log"];
    [NTM_prefs() synchronize];
    [self reloadEntries];
}
- (NSString *)typeTitle:(NSString *)key {
    for (NSDictionary *m in _typeMaps) if ([m[@"k"] isEqualToString:key]) return m[@"t"];
    return key;
}
- (UIColor *)typeColor:(NSString *)key {
    for (NSDictionary *m in _typeMaps) if ([m[@"k"] isEqualToString:key]) return m[@"c"];
    return [UIColor grayColor];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _entries.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 62; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"log"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.layer.cornerRadius = 12;
        cell.clipsToBounds = YES;
    }
    NSDictionary *e = _entries[indexPath.row];
    NSString *app = NTM_dispName(e[@"app"] ?: @"");
    NSString *type = e[@"type"] ?: @"";
    cell.textLabel.text = app;
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.textLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    double ts = [e[@"t"] doubleValue];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss";
    NSString *time = [df stringFromDate:date];
    NSString *detail = e[@"d"] ?: @"";
    NSString *typeTitle = [self typeTitle:type];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@  %@", time, typeTitle, detail];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    UIColor *c = [self typeColor:type];
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 16, 4, 30)];
    badge.backgroundColor = c;
    badge.layer.cornerRadius = 2;
    cell.contentView.backgroundColor = [UIColor whiteColor];
    for (UIView *v in cell.contentView.subviews) if ([v isKindOfClass:[UIView class]] && v.tag == 9999) [v removeFromSuperview];
    badge.tag = 9999;
    [cell.contentView addSubview:badge];
    return cell;
}
@end

#pragma mark - 控制器
@implementation NTMPrincipalController {
    UISegmentedControl *_catSeg;
    UISegmentedControl *_filterSeg;
    UISearchBar *_searchBar;
    UILabel *_statLabel;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    NSArray *_allApps;
    NSArray *_curApps;
    NSString *_curCat;
    NSString *_searchText;
    NSInteger _filter; // 0全部 1已开启 2已关闭 3断网
    NSMutableDictionary *_snapshot;
}

- (void)setRootController:(id)rootController {}
- (void)setParentController:(id)parentController {}
- (void)setSpecifier:(id)specifier {}
- (void)setPreferenceLoader:(id)preferenceLoader {}
- (void)setParentController:(id)parentController specifier:(id)specifier {}

static UIButton *NTM_pillButton(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 14;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通知管理";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];
    _curCat = @"用户应用";
    _searchText = @"";
    _filter = 0;
    _snapshot = [NSMutableDictionary dictionary];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"反馈"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self action:@selector(feedback)];
    [self buildUI];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];
    [self.view addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = NTM_allApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            _allApps = apps;
            [self reloadList];
        });
    });
}

- (void)buildUI {
    _catSeg = [[UISegmentedControl alloc] initWithItems:@[@"用户应用", @"巨魔应用", @"系统应用"]];
    _catSeg.selectedSegmentIndex = 0;
    [_catSeg addTarget:self action:@selector(catChanged) forControlEvents:UIControlEventValueChanged];

    _filterSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"已开启", @"已关闭", @"断网"]];
    _filterSeg.selectedSegmentIndex = 0;
    _filterSeg.tintColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:1];
    [_filterSeg addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];

    UIButton *allOnBtn = NTM_pillButton(@"全部开启",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [allOnBtn addTarget:self action:@selector(allOnTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *allOffBtn = NTM_pillButton(@"全部关闭",
        [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15],
        [UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]);
    [allOffBtn addTarget:self action:@selector(allOffTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *customBtn = NTM_pillButton(@"自定义",
        [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18],
        [UIColor colorWithWhite:0.35 alpha:1]);
    [customBtn addTarget:self action:@selector(customTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *batchRow = [[UIStackView alloc] initWithArrangedSubviews:@[allOnBtn, allOffBtn, customBtn]];
    batchRow.axis = UILayoutConstraintAxisHorizontal;
    batchRow.distribution = UIStackViewDistributionFillEqually;
    batchRow.spacing = 10;

    UIButton *snapBtn = NTM_pillButton(@"模式快照",
        [UIColor colorWithRed:0.55 green:0.40 blue:0.90 alpha:0.15],
        [UIColor colorWithRed:0.45 green:0.30 blue:0.85 alpha:1]);
    [snapBtn addTarget:self action:@selector(snapshotTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *grpBtn = NTM_pillButton(@"应用分组",
        [UIColor colorWithRed:0.30 green:0.66 blue:0.95 alpha:0.15],
        [UIColor colorWithRed:0.15 green:0.45 blue:0.78 alpha:1]);
    [grpBtn addTarget:self action:@selector(groupManagerTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *logBtn = NTM_pillButton(@"拦截日志",
        [UIColor colorWithRed:0.95 green:0.60 blue:0.15 alpha:0.15],
        [UIColor colorWithRed:0.85 green:0.50 blue:0.08 alpha:1]);
    [logBtn addTarget:self action:@selector(logTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *featRow = [[UIStackView alloc] initWithArrangedSubviews:@[snapBtn, grpBtn, logBtn]];
    featRow.axis = UILayoutConstraintAxisHorizontal;
    featRow.distribution = UIStackViewDistributionFillEqually;
    featRow.spacing = 10;

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.placeholder = @"搜索应用名称";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.backgroundImage = [UIImage new];

    _statLabel = [[UILabel alloc] init];
    _statLabel.font = [UIFont systemFontOfSize:12];
    _statLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.rowHeight = 300; // 卡片 288 + 上下间距 12
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 4, 0);

    UIButton *exportBtn = NTM_pillButton(@"导出配置",
        [UIColor colorWithRed:0.35 green:0.56 blue:1.0 alpha:0.15],
        [UIColor colorWithRed:0.17 green:0.35 blue:0.72 alpha:1]);
    [exportBtn addTarget:self action:@selector(exportConfig) forControlEvents:UIControlEventTouchUpInside];
    UIButton *importBtn = NTM_pillButton(@"导入配置",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [importBtn addTarget:self action:@selector(importConfig) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[_tableView, batchRow, featRow, _statLabel, _searchBar, _filterSeg, _catSeg, exportBtn, importBtn]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    [self.view bringSubviewToFront:batchRow];

    [NSLayoutConstraint activateConstraints:@[
        [batchRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [batchRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [batchRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [batchRow.heightAnchor constraintEqualToConstant:40],

        [featRow.topAnchor constraintEqualToAnchor:batchRow.bottomAnchor constant:8],
        [featRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [featRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [featRow.heightAnchor constraintEqualToConstant:38],

        [_statLabel.topAnchor constraintEqualToAnchor:featRow.bottomAnchor constant:8],
        [_statLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_searchBar.topAnchor constraintEqualToAnchor:_statLabel.bottomAnchor constant:2],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_filterSeg.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:2],
        [_filterSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_filterSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_catSeg.topAnchor constraintEqualToAnchor:_filterSeg.bottomAnchor constant:6],
        [_catSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_catSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [exportBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [exportBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [exportBtn.heightAnchor constraintEqualToConstant:44],
        [importBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [importBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [importBtn.heightAnchor constraintEqualToConstant:44],
        [exportBtn.trailingAnchor constraintEqualToAnchor:importBtn.leadingAnchor constant:-12],
        [exportBtn.widthAnchor constraintEqualToAnchor:importBtn.widthAnchor],

        [_tableView.topAnchor constraintEqualToAnchor:_catSeg.bottomAnchor constant:12],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:exportBtn.topAnchor constant:-12],
    ]];
}

- (void)hideSpinner {
    [_spinner stopAnimating];
    [_spinner removeFromSuperview];
    _spinner = nil;
}

#pragma mark - UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _curApps.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 300; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"card"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"card"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSDictionary *app = _curApps[indexPath.row];
    NTMAppCardView *card = [[NTMAppCardView alloc] initWithApp:app];
    [card reloadFromPrefs];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],
    ]];
    __weak typeof(self) ws = self;
    card.onDimChange = ^(NSString *aid, NSString *dim, BOOL val) { [ws refreshStat]; };
    card.onMasterChange = ^(NSString *aid, BOOL val) { [ws refreshStat]; };
    card.onNetChange = ^(NSString *aid, NSInteger policy) { [ws refreshStat]; };
    card.onReset = ^(NSString *aid) { [ws refreshStat]; };
    card.onFeatChange = ^(NSString *aid, NSString *key, BOOL val) { [ws refreshStat]; };
    card.onKeywordEdit = ^(NSString *aid) { [ws editKeyword:aid]; };
    card.onGroupPick = ^(NSString *aid) { [ws pickGroup:aid]; };
    return cell;
}

#pragma mark - 列表
- (void)reloadList {
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        if (_searchText.length) {
            NSString *name = app[@"name"];
            NSString *bid = app[@"id"];
            if (![name localizedCaseInsensitiveContainsString:_searchText] &&
                ![bid localizedCaseInsensitiveContainsString:_searchText]) continue;
        } else {
            if (![app[@"cat"] isEqualToString:_curCat]) continue;
        }
        if (_filter == 1) { if (!NTM_read(app[@"id"], @"en")) continue; }
        else if (_filter == 2) { if (NTM_read(app[@"id"], @"en")) continue; }
        else if (_filter == 3) { if (NTM_netRead(app[@"id"]) != 1) continue; }
        [filtered addObject:app];
    }
    _curApps = filtered;

    if (!filtered.count) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 80)];
        empty.text = @"暂无应用";
        empty.font = [UIFont systemFontOfSize:14];
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        empty.textAlignment = NSTextAlignmentCenter;
        _tableView.backgroundView = empty;
    } else {
        _tableView.backgroundView = nil;
    }
    [_tableView reloadData];
    [self refreshStat];
    [self hideSpinner];
}

- (void)refreshAllCards {
    for (UITableViewCell *cell in _tableView.visibleCells) {
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[NTMAppCardView class]]) [(NTMAppCardView *)v reloadFromPrefs];
        }
    }
}

- (void)refreshStat {
    NSUserDefaults *prefs = NTM_prefs();
    NSInteger total = 0, on = 0;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        if (NTM_readWith(prefs, aid, @"en")) on++;
        total++;
    }
    NSString *scope = _searchText.length ? [NSString stringWithFormat:@"搜索：%@", _searchText]
                     : (_filter ? [NSString stringWithFormat:@"%@ / %@", _curCat, @[@"", @"已开启", @"已关闭", @"断网"][_filter]]
                                : _curCat);
    _statLabel.text = [NSString stringWithFormat:@"%@    已开启 %ld / %ld 个应用", scope, (long)on, (long)total];
}

#pragma mark - 交互
- (void)catChanged {
    NSArray *cats = @[@"用户应用", @"巨魔应用", @"系统应用"];
    _curCat = cats[_catSeg.selectedSegmentIndex];
    [self reloadList];
}
- (void)filterChanged { _filter = _filterSeg.selectedSegmentIndex; [self reloadList]; }

- (void)allOnTapped { [self saveSnapshot]; [self batchWrite:YES]; [self refreshAllCards]; [self refreshStat]; }
- (void)allOffTapped { [self saveSnapshot]; [self batchWrite:NO]; [self refreshAllCards]; [self refreshStat]; }
- (void)customTapped { [self restoreSnapshot]; [self refreshAllCards]; [self refreshStat]; }

- (void)batchWrite:(BOOL)val {
    NSUserDefaults *prefs = NTM_prefs();
    NSMutableArray *ids = [NSMutableArray array];
    NSInteger netPolicy = val ? 0 : 1;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        [ids addObject:aid];
        [prefs setBool:val forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:val forKey:NTM_key(aid, d[@"key"])];
        [prefs setInteger:netPolicy forKey:NTM_netKey(aid)];
        if (!val) {
            [prefs setBool:NO forKey:NTM_key(aid, @"bgNet")]; // 全部关闭时顺带关后台断网
        }
    }
    NSArray *idsCopy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize];
        NTM_postConfigChanged();
        for (NSString *aid in idsCopy) NTM_syncSystem(aid);
        for (NSString *aid in idsCopy) NTM_syncCellular(aid, netPolicy);
    });
}

- (void)saveSnapshot {
    [_snapshot removeAllObjects];
    NSUserDefaults *prefs = NTM_prefs();
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @(NTM_readWith(prefs, aid, @"en"));
        for (NSDictionary *dim in NTM_dims()) d[dim[@"key"]] = @(NTM_readWith(prefs, aid, dim[@"key"]));
        d[@"net"] = @(NTM_netRead(aid));
        _snapshot[aid] = d;
    }
}
- (void)restoreSnapshot {
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in _snapshot) {
        NSDictionary *d = _snapshot[aid];
        id en = d[@"en"];
        if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        for (NSDictionary *dim in NTM_dims()) {
            id v = d[dim[@"key"]];
            if (v) [prefs setBool:[v boolValue] forKey:NTM_key(aid, dim[@"key"])];
        }
        id net = d[@"net"];
        if (net) { [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)]; NTM_syncCellularAsync(aid, [net integerValue]); }
        NTM_syncSystemAsync(aid);
    }
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged(); });
}

#pragma mark - Alert/Sheet 弹出（统一设置 popover 来源，避免 iPad 崩溃）
- (void)showAlertController:(UIAlertController *)ac {
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height-40, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 模式快照（持久化，一键回滚）
- (void)snapshotTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"模式快照"
                                                                message:@"保存当前全部App的通知+网络配置，可随时一键回滚"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存当前配置为快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self snapshotSave];
    }]];
    BOOL has = [[NTM_prefs() objectForKey:@"NTM_snapshot"] isKindOfClass:[NSDictionary class]];
    if (has) {
        [ac addAction:[UIAlertAction actionWithTitle:@"恢复已保存的快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [self snapshotRestore];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"删除已保存的快照" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            [NTM_prefs() removeObjectForKey:@"NTM_snapshot"];
            [NTM_prefs() synchronize];
            [self toast:@"已删除快照"];
        }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"恢复已保存的快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [self toast:@"还没有保存过快照"];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)snapshotSave {
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (NSDictionary *app in _allApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @(NTM_read(aid, @"en"));
        NSMutableDictionary *dims = [NSMutableDictionary dictionary];
        for (NSDictionary *dim in NTM_dims()) dims[dim[@"key"]] = @(NTM_read(aid, dim[@"key"]));
        d[@"dims"] = dims;
        d[@"net"] = @(NTM_netRead(aid));
        d[@"noBadge"] = @(NTM_feat(aid, @"noBadge"));
        d[@"noPreview"] = @(NTM_feat(aid, @"noPreview"));
        d[@"bgNet"] = @(NTM_feat(aid, @"bgNet"));
        d[@"kw"] = NTM_kwList(aid);
        NSString *grp = [NTM_prefs() objectForKey:NTM_key(aid, @"group")];
        if (grp.length) d[@"group"] = grp;
        snap[aid] = d;
    }
    [NTM_prefs() setObject:snap forKey:@"NTM_snapshot"];
    [NTM_prefs() synchronize];
    [self toast:[NSString stringWithFormat:@"已保存 %lu 个应用为快照", (unsigned long)snap.count]];
}
- (void)snapshotRestore {
    id snap = [NTM_prefs() objectForKey:@"NTM_snapshot"];
    if (![snap isKindOfClass:[NSDictionary class]]) return;
    NSUserDefaults *prefs = NTM_prefs();
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *aid in snap) {
        NSDictionary *d = snap[aid];
        [ids addObject:aid];
        id en = d[@"en"]; if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) for (NSString *k in dims) [prefs setBool:[dims[k] boolValue] forKey:NTM_key(aid, k)];
        id net = d[@"net"];
        if (net) [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)];
        if (d[@"noBadge"]) [prefs setBool:[d[@"noBadge"] boolValue] forKey:NTM_key(aid, @"noBadge")];
        if (d[@"noPreview"]) [prefs setBool:[d[@"noPreview"] boolValue] forKey:NTM_key(aid, @"noPreview")];
        if (d[@"bgNet"]) [prefs setBool:[d[@"bgNet"] boolValue] forKey:NTM_key(aid, @"bgNet")];
        NSArray *kw = d[@"kw"];
        if (kw) { [prefs removeObjectForKey:NTM_key(aid, @"kw")]; if ([kw isKindOfClass:[NSArray class]] && kw.count) NTM_kwSave(aid, kw); }
        if (d[@"group"]) [prefs setObject:d[@"group"] forKey:NTM_key(aid, @"group")];
    }
    NSArray *idsCopy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in idsCopy) { NTM_syncSystem(aid); NTM_syncCellular(aid, NTM_netRead(aid)); }
    });
    [self refreshAllCards];
    [self refreshStat];
    [self toast:[NSString stringWithFormat:@"已恢复 %lu 个应用", (unsigned long)ids.count]];
}

#pragma mark - 应用分组
- (void)groupManagerTapped {
    NSArray *names = NTM_groupNames();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"应用分组"
                                                                message:names.count ? @"选中的整组可批量操作" : @"还没有分组，先新建一个"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ 分组", name]
                                               style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupOps:name]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"新建分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self promptNewGroup]; }]];
    if (names.count)
        [ac addAction:[UIAlertAction actionWithTitle:@"管理分组（删除）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ [self manageGroups]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)promptNewGroup {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"新建分组" message:@"输入分组名称（如：社交、游戏、短视频）" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"分组名称"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NTM_addGroupName(ac.textFields.firstObject.text);
        [self toast:@"已创建分组"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)manageGroups {
    NSArray *names = NTM_groupNames();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"管理分组" message:@"点击删除分组" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"删除 %@", name] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            NTM_removeGroupName(name);
            [self refreshAllCards];
            [self toast:[NSString stringWithFormat:@"已删除分组 %@", name]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (NSArray *)appIdsOfGroup:(NSString *)name {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        NSString *g = [NTM_prefs() objectForKey:NTM_key(app[@"id"], @"group")];
        if ([g isEqualToString:name]) [ids addObject:app[@"id"]];
    }
    return ids;
}
- (void)groupOps:(NSString *)name {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 分组", name] message:@"整组批量操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组全部开启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupBatch:name en:YES]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组全部关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupBatch:name en:NO]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组断网" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupNetOff:name]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)groupBatch:(NSString *)name en:(BOOL)en {
    NSUserDefaults *prefs = NTM_prefs();
    NSArray *ids = [self appIdsOfGroup:name];
    for (NSString *aid in ids) {
        [prefs setBool:en forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:en forKey:NTM_key(aid, d[@"key"])];
        [prefs setInteger:(en ? 0 : 1) forKey:NTM_netKey(aid)];
    }
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in copy) { NTM_syncSystem(aid); NTM_syncCellular(aid, en?0:1); } });
    [self refreshAllCards]; [self refreshStat];
    [self toast:[NSString stringWithFormat:@"%@：已%@ %lu 个应用", name, en?@"开启":@"关闭", (unsigned long)ids.count]];
}
- (void)groupNetOff:(NSString *)name {
    NSUserDefaults *prefs = NTM_prefs();
    NSArray *ids = [self appIdsOfGroup:name];
    for (NSString *aid in ids) [prefs setInteger:1 forKey:NTM_netKey(aid)];
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in copy) NTM_syncCellular(aid, 1); });
    [self refreshAllCards]; [self refreshStat];
    [self toast:[NSString stringWithFormat:@"%@：已断网 %lu 个应用", name, (unsigned long)ids.count]];
}
- (void)pickGroup:(NSString *)aid {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:NTM_dispName(aid) message:@"选择分组" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"未分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NTM_setGroup(aid, @""); [self refreshAllCards];
    }]];
    for (NSString *name in NTM_groupNames()) {
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            NTM_setGroup(aid, name); [self refreshAllCards];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"新建分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self promptNewGroup]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}

#pragma mark - 关键词过滤
- (void)editKeyword:(NSString *)aid {
    NSArray *list = NTM_kwList(aid);
    NSString *text = [list componentsJoinedByString:@","];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"关键词过滤" message:@"输入关键词，用逗号或分号分隔；命中即拦截该条通知" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text = text; tf.placeholder = @"如：广告,优惠券,营销"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *v = ac.textFields.firstObject.text ?: @"";
        NSMutableArray *kws = [NSMutableArray array];
        for (NSString *part in [v componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，;；"]]) {
            NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [kws addObject:t];
        }
        NTM_kwSave(aid, kws);
        [self refreshAllCards];
        [self toast:kws.count ? [NSString stringWithFormat:@"已设置 %lu 个关键词", (unsigned long)kws.count] : @"已清除关键词"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}

#pragma mark - 拦截日志
- (void)logTapped {
    NTMLogViewController *vc = [[NTMLogViewController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 反馈
- (void)feedback {
    NSString *subject = [@"通知管理插件反馈" stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"mailto:wacljcr@qq.com?subject=%@", subject]];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - 导入/导出
- (NSString *)configPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/NotifyManagerConfig.json"];
}
- (void)exportConfig {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"appId"] = aid;
        d[@"name"] = app[@"name"];
        d[@"en"] = @(NTM_read(aid, @"en"));
        NSMutableDictionary *dims = [NSMutableDictionary dictionary];
        for (NSDictionary *dim in NTM_dims()) dims[dim[@"key"]] = @(NTM_read(aid, dim[@"key"]));
        d[@"dims"] = dims;
        d[@"net"] = @(NTM_netRead(aid));
        d[@"noBadge"] = @(NTM_feat(aid, @"noBadge"));
        d[@"noPreview"] = @(NTM_feat(aid, @"noPreview"));
        d[@"bgNet"] = @(NTM_feat(aid, @"bgNet"));
        d[@"kw"] = NTM_kwList(aid);
        NSString *grp = [NTM_prefs() objectForKey:NTM_key(aid, @"group")];
        if (grp.length) d[@"group"] = grp;
        [arr addObject:d];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { [self toast:@"导出失败"]; return; }
    NSString *path = [self configPath];
    if (![data writeToFile:path atomically:YES]) { [self toast:@"导出失败，无写入权限"]; return; }
    [self toast:[NSString stringWithFormat:@"已导出 %lu 个应用", (unsigned long)arr.count]];
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.view;
    avc.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    [self presentViewController:avc animated:YES completion:nil];
}
- (void)importConfig {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.json", @"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) { [self toast:@"读取文件失败"]; return; }
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) { [self toast:@"配置格式错误"]; return; }
    NSInteger count = 0;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSDictionary *d in arr) {
        NSString *aid = d[@"appId"];
        if (!aid.length) continue;
        id en = d[@"en"];
        if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) for (NSString *k in dims) [prefs setBool:[dims[k] boolValue] forKey:NTM_key(aid, k)];
        id net = d[@"net"];
        if (net) { [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)]; NTM_syncCellularAsync(aid, [net integerValue]); }
        if (d[@"noBadge"]) [prefs setBool:[d[@"noBadge"] boolValue] forKey:NTM_key(aid, @"noBadge")];
        if (d[@"noPreview"]) [prefs setBool:[d[@"noPreview"] boolValue] forKey:NTM_key(aid, @"noPreview")];
        if (d[@"bgNet"]) [prefs setBool:[d[@"bgNet"] boolValue] forKey:NTM_key(aid, @"bgNet")];
        NSArray *kw = d[@"kw"];
        if ([kw isKindOfClass:[NSArray class]]) { [prefs removeObjectForKey:NTM_key(aid, @"kw")]; if (kw.count) NTM_kwSave(aid, kw); }
        NSString *grp = d[@"group"];
        if (grp.length) [prefs setObject:grp forKey:NTM_key(aid, @"group")];
        NTM_syncSystemAsync(aid);
        count++;
    }
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged(); });
    [self refreshAllCards];
    [self refreshStat];
    [self toast:[NSString stringWithFormat:@"已导入 %ld 个应用", (long)count]];
}

#pragma mark - 搜索（防抖 0.3s）
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _searchText = searchText ?: @"";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self performSelector:@selector(applySearch) withObject:nil afterDelay:0.3];
}
- (void)applySearch { [self reloadList]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self applySearch];
}

#pragma mark - Toast
- (void)toast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [l.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:30],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-30],
    ]];
    l.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f){ [l removeFromSuperview]; }];
    });
}

@end