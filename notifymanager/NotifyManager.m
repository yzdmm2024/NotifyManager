// NotifyManager.m — 通知管理设置面板（自定义现代 UI）
// 枚举已安装 App，按分类(用户/巨魔/系统)展示
// 每个 App：总开关 + 锁定屏幕/通知中心/横幅/声音/标记 子开关 + 单应用重置
// 每个 App 显示 4 个网络策略按钮：打开wifi/流量/wifi+流量/断网
// 支持：分类切换、搜索、统计、批量开启/关闭/恢复自定义、导入/导出配置
// 列表使用 UITableView 虚拟化，切换分类/搜索即时响应
// 配置保存到 NSUserDefaults suiteName，Tweak 读取并拦截通知
// 设置变更时同步到系统通知设置 (BBSettingsGateway) 与蜂窝网络 (PSAppDataUsagePolicyCache)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 接口声明
// PSAppDataUsagePolicyCache 是 Preferences 私有类，系统"设置→蜂窝网络"用它读写每应用策略
@interface PSAppDataUsagePolicyCache : NSObject
+ (instancetype)sharedInstance;
- (void)setUsagePoliciesForBundle:(NSString *)bundleId cellular:(BOOL)cellular wifi:(BOOL)wifi;
@end

static NSDictionary *NTM_cellularPolicies(void);
static NSInteger NTM_netReadSystem(NSString *appId);
// PSViewController 是 PreferenceLoader 控制器的正确基类（实现 PSController 协议），
// 提供 setSpecifier:/setParentController:/setRootController: 等全部集成方法，
// 避免 controllerForSpecifier: 调用未实现方法导致 unrecognized selector 崩溃。
@interface PSViewController : UIViewController
@end

@interface NTMPrincipalController : PSViewController <UISearchBarDelegate, UIDocumentPickerDelegate, UITableViewDelegate, UITableViewDataSource>
@end

#pragma mark - 存储: NSUserDefaults suiteName (Tweak 读取同一份)
static NSString *NTM_suite = @"com.ntm.notifymanager";
static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
// 共享 NSUserDefaults 实例，避免每次读写都新建实例导致批量操作卡顿
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
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    [NTM_prefs() setBool:val forKey:NTM_key(appId, dim)];
    [NTM_prefs() synchronize];
}

#pragma mark - 网络权限存储
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static NSString *NTM_netKey(NSString *appId) {
    return [NSString stringWithFormat:@"NTM_net_%@", appId];
}

// 从系统蜂窝网络策略表读取该 App 当前策略（首次读取缓存一次 plist）
static NSInteger NTM_netReadSystem(NSString *appId) {
    NSDictionary *ap = NTM_cellularPolicies();
    NSDictionary *policy = ap[appId];
    if (![policy isKindOfClass:[NSDictionary class]]) return 0;
    NSString *cell = policy[@"kCTCellularDataUsagePolicy"];
    NSString *wifi = policy[@"kCTWiFiDataUsagePolicy"];
    BOOL cellOn = cell.length && [cell containsString:@"Allow"];
    BOOL wifiOn = wifi.length && [wifi containsString:@"Allow"];
    if (cellOn && wifiOn) return 0;   // wifi+流量
    if (!cellOn && !wifiOn) return 1; // 断网
    if (wifiOn) return 2;             // 打开wifi
    return 3;                         // 流量
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
        case 1: return [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1]; // 断网 红
        case 2: return [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1];  // wifi 蓝
        case 3: return [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1]; // 流量 绿
        default: return [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1]; // wifi+流量 青
    }
}

#pragma mark - 同步到系统通知设置 (BBSettingsGateway)
// 让"设置 → 通知"里的系统设置跟随本面板的开关，双向一致
// 注意：BBSectionInfo 没有 soundEnabled/badgeEnabled 属性，声音/角标必须通过
// pushSettings 位掩码控制（bit0/3=角标, bit1/4=声音, bit2/5=横幅提醒）。
// 若用 KVC 设置不存在的 key 会抛异常，导致 setSectionInfo:forSectionID: 永不执行。
// 常驻 gateway，避免每次创建/释放导致 setSectionInfo 持久化失败
static id NTM_gateway(void) {
    static id gw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (cls) gw = [[cls alloc] init];
    });
    return gw;
}

// 所有系统同步统一走后台串行队列，避免阻塞 UI 且防止交错
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
        // 声音/标记仅在总开关开启且至少一个可见通道(锁屏/通知中心/横幅)开启时才生效
        BOOL anyVisible = lock || nc || banner;
        BOOL sound = en && anyVisible && NTM_read(appId, @"sound");
        BOOL badge = en && anyVisible && NTM_read(appId, @"badge");
        [info setValue:@(en) forKey:@"allowsNotifications"];
        [info setValue:@(lock) forKey:@"showsInLockScreen"];
        [info setValue:@(nc) forKey:@"showsInNotificationCenter"];
        [info setValue:@(banner ? 1 : 0) forKey:@"alertType"];
        NSUInteger push = 0;
        if (sound) push |= 18;  // bit1+bit4 声音
        if (badge) push |= 9;   // bit0+bit3 角标
        if (banner) push |= 36; // bit2+bit5 横幅提醒
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

#pragma mark - 同步到系统蜂窝网络设置 (CommCenter 私有 API)
// 读取系统蜂窝网络策略表，用于初始同步面板显示
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

// 通过 Preferences 私有类（与"设置→蜂窝网络"同源）设置每 App 网络策略，
// 失败时回退 CoreTelephony 私有 API
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static void NTM_syncCellular(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    BOOL cellular = (policy == 0 || policy == 3); // wifi+流量/流量 允许蜂窝
    BOOL wifi = (policy == 0 || policy == 2);     // wifi+流量/打开wifi 允许WiFi
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
                NSLog(@"[NTM] cellular %@ policy=%ld cell=%d wifi=%d (PSAppDataUsagePolicyCache)",
                      appId, (long)policy, cellular, wifi);
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
                NSDictionary *policies = @{
                    @"kCTCellularDataUsagePolicy": cell,
                    @"kCTWiFiDataUsagePolicy": wifiS,
                };
                setPolicy(conn, appId, policies);
            }
        }
        dlclose(handle);
        NSLog(@"[NTM] cellular %@ policy=%ld (CoreTelephony)", appId, (long)policy);
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
// 缓存一次 BulletinBoard 的所有 section（含 查找/跟踪通知/家庭 等非 /Applications 的漏网之鱼）
// 返回 [{id, name}]，用于补齐系统通知列表与判断某 App 是否注册了通知
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
                    if ([gateway respondsToSelector:sels[i]]) {
                        sections = [gateway performSelector:sels[i]];
                    }
                }
                NSArray *secList = nil;
                if ([sections isKindOfClass:[NSArray class]]) {
                    secList = sections;
                } else if ([sections isKindOfClass:[NSDictionary class]]) {
                    secList = [sections allValues];
                }
                for (id info in secList) {
                    NSString *sid = nil;
                    @try { sid = [info performSelector:@selector(sectionID)]; } @catch(NSException *e) {}
                    if (!sid.length) {
                        @try { sid = [info performSelector:@selector(sectionIdentifier)]; } @catch(NSException *e) {}
                    }
                    if (!sid.length) continue;
                    NSString *name = nil;
                    @try { name = [info performSelector:@selector(sectionName)]; } @catch(NSException *e) {}
                    if (!name.length) {
                        @try { name = [info performSelector:@selector(displayName)]; } @catch(NSException *e) {}
                    }
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
    if (!s.count) return YES; // 查询失败时默认显示
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

// 枚举 App：不在此处加载图标（图标放到卡片里异步加载），避免进入面板卡顿
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
    // 已安装 App 集合：合并系统 section 时只补真实安装的 App，过滤 daemon/服务类 section
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
            // 只保留 /Applications 下的用户界面系统应用，且注册了通知
            if (![path hasPrefix:@"/Applications/"]) continue;
            if (!NTM_hasNotifications(bid)) continue;
        }
        [out addObject:@{ @"id":bid, @"name":(name.length?name:bid), @"cat":cat,
                          @"icon":[NSNull null] }];
    }
    // 合并系统通知 section：只补真实安装的 Apple 系统 App（过滤 daemon/服务类 section）
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

#pragma mark - App 卡片视图
@interface NTMAppCardView : UIView
@property (nonatomic, strong) NSString *appId;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) NSMutableArray *dimSwitches;
@property (nonatomic, strong) NSMutableArray *netButtons;
@property (nonatomic, copy) void (^onDimChange)(NSString *appId, NSString *dim, BOOL val);
@property (nonatomic, copy) void (^onMasterChange)(NSString *appId, BOOL val);
@property (nonatomic, copy) void (^onNetChange)(NSString *appId, NSInteger policy);
@property (nonatomic, copy) void (^onReset)(NSString *appId);
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

    // 图标异步加载，不阻塞主线程
    NSString *bid = _appId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *icon = NTM_iconFor(bid);
        if (!icon) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            iconView.image = icon;
        });
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

    // 子开关行：5 个维度横排
    NSMutableArray *dimItems = [NSMutableArray array];
    for (NSDictionary *d in dims) {
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = d[@"title"];
        lbl.font = [UIFont systemFontOfSize:11];
        lbl.textColor = [UIColor colorWithWhite:0.33 alpha:1];
        lbl.textAlignment = NSTextAlignmentCenter;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        [sw addTarget:self action:@selector(dimChanged:) forControlEvents:UIControlEventValueChanged];
        [_dimSwitches addObject:sw];

        UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[lbl, sw]];
        item.axis = UILayoutConstraintAxisVertical;
        item.alignment = UIStackViewAlignmentCenter;
        item.spacing = 2;
        [dimItems addObject:item];
    }
    UIStackView *dimRow = [[UIStackView alloc] initWithArrangedSubviews:dimItems];
    dimRow.axis = UILayoutConstraintAxisHorizontal;
    dimRow.distribution = UIStackViewDistributionFillEqually;
    dimRow.alignment = UIStackViewAlignmentCenter;
    dimRow.spacing = 4;

    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[header, dimRow]];
    [rows addObject:[self buildNetRow]];
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:rows];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 12;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [v.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
    ]];
}

// 网络策略行：打开wifi / 流量 / wifi+流量 / 断网，单选
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
    // 联动：总开关切换时同步所有子开关
    for (NSDictionary *d in NTM_dims()) [prefs setBool:sender.on forKey:NTM_key(_appId, d[@"key"])];
    [prefs synchronize];
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onMasterChange) _onMasterChange(_appId, sender.on);
}

- (void)dimChanged:(UISwitch *)sender {
    NSUInteger idx = [_dimSwitches indexOfObject:sender];
    if (idx == NSNotFound || idx >= NTM_dims().count) return;
    NSDictionary *d = NTM_dims()[idx];
    NTM_write(_appId, d[@"key"], sender.on);
    // 各子开关独立控制，互不联动；总开关仅由总开关本身控制
    // 刷新后按依赖规则更新声音/标记的可用状态
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onDimChange) _onDimChange(_appId, d[@"key"], sender.on);
}

- (void)resetTapped {
    NSUserDefaults *prefs = NTM_prefs();
    [prefs setBool:YES forKey:NTM_key(_appId, @"en")];
    for (NSDictionary *d in NTM_dims()) [prefs setBool:YES forKey:NTM_key(_appId, d[@"key"])];
    [prefs synchronize];
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onReset) _onReset(_appId);
}

- (void)reloadFromPrefs {
    BOOL en = NTM_read(_appId, @"en");
    _masterSwitch.on = en;
    NSArray *dims = NTM_dims();
    // 声音/标记依赖：总开关开启 且 锁屏/通知中心/横幅至少一个开启 才可点
    BOOL anyVisible = NTM_read(_appId, @"lock") || NTM_read(_appId, @"nc") || NTM_read(_appId, @"banner");
    BOOL soundBadgeEnabled = en && anyVisible;
    for (NSUInteger i = 0; i < dims.count && i < _dimSwitches.count; i++) {
        UISwitch *sw = _dimSwitches[i];
        sw.on = NTM_read(_appId, dims[i][@"key"]);
        if (i == 3 || i == 4) { // 声音/标记
            sw.enabled = soundBadgeEnabled;
        }
    }
    [self updateNetButtons];
}

@end

#pragma mark - 控制器
@implementation NTMPrincipalController {
    UISegmentedControl *_catSeg;
    UISearchBar *_searchBar;
    UILabel *_statLabel;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    NSArray *_allApps;
    NSArray *_curApps;
    NSString *_curCat;
    NSString *_searchText;
    NSMutableDictionary *_snapshot; // 批量操作前的快照 {appId: {dim: BOOL}}
}

// PreferenceLoader/PSListController 集成方法（自定义 UI 不使用，仅避免 unrecognized selector 崩溃）
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
    _snapshot = [NSMutableDictionary dictionary];

    [self buildUI];

    // 异步加载应用列表，避免进入面板卡顿
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

    // 批量操作按钮：全部开启 / 全部关闭 / 自定义(恢复快照)
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
    _tableView.rowHeight = 134; // 卡片 122 + 上下间距 12
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 4, 0);

    UIButton *exportBtn = NTM_pillButton(@"导出配置",
        [UIColor colorWithRed:0.35 green:0.56 blue:1.0 alpha:0.15],
        [UIColor colorWithRed:0.17 green:0.35 blue:0.72 alpha:1]);
    [exportBtn addTarget:self action:@selector(exportConfig) forControlEvents:UIControlEventTouchUpInside];

    UIButton *importBtn = NTM_pillButton(@"导入配置",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [importBtn addTarget:self action:@selector(importConfig) forControlEvents:UIControlEventTouchUpInside];

    // 表格先加入(置于最底层)，其余控件在其上层，避免任何控件被表格遮挡导致无法点击
    for (UIView *v in @[_tableView, batchRow, _statLabel, _searchBar, _catSeg, exportBtn, importBtn]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    [self.view bringSubviewToFront:batchRow];

    [NSLayoutConstraint activateConstraints:@[
        [batchRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [batchRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [batchRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [batchRow.heightAnchor constraintEqualToConstant:40],

        [_statLabel.topAnchor constraintEqualToAnchor:batchRow.bottomAnchor constant:8],
        [_statLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_searchBar.topAnchor constraintEqualToAnchor:_statLabel.bottomAnchor constant:2],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_catSeg.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:2],
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

        // 列表位于分类栏之下，不遮挡任何控件
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _curApps.count;
}

// 所有 App 卡片统一高度（含网络按钮行）
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 178;
}

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
    [card reloadFromPrefs]; // 加载实际开关状态，避免重建后全部显示为关
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
    return cell;
}

#pragma mark - 列表
- (void)reloadList {
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        if (_searchText.length) {
            // 搜索时跨分类查找，保证能搜到目标 App
            NSString *name = app[@"name"];
            NSString *bid = app[@"id"];
            if (![name localizedCaseInsensitiveContainsString:_searchText] &&
                ![bid localizedCaseInsensitiveContainsString:_searchText]) continue;
        } else {
            if (![app[@"cat"] isEqualToString:_curCat]) continue;
        }
        [filtered addObject:app];
    }
    _curApps = filtered;

    if (!filtered.count) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 80)];
        empty.text = @"该分类暂无应用";
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

// 批量操作后直接刷新可见卡片开关，避免重建列表
- (void)refreshAllCards {
    for (UITableViewCell *cell in _tableView.visibleCells) {
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[NTMAppCardView class]]) {
                [(NTMAppCardView *)v reloadFromPrefs];
            }
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
    NSString *scope = _searchText.length ? [NSString stringWithFormat:@"搜索：%@", _searchText] : _curCat;
    _statLabel.text = [NSString stringWithFormat:@"%@    已开启 %ld / %ld 个应用",
                       scope, (long)on, (long)total];
}

#pragma mark - 交互
- (void)catChanged {
    NSArray *cats = @[@"用户应用", @"巨魔应用", @"系统应用"];
    _curCat = cats[_catSeg.selectedSegmentIndex];
    [self reloadList];
}

- (void)allOnTapped {
    [self saveSnapshot];
    [self batchWrite:YES];
    [self refreshAllCards];
    [self refreshStat];
}

- (void)allOffTapped {
    [self saveSnapshot];
    [self batchWrite:NO];
    [self refreshAllCards];
    [self refreshStat];
}

- (void)customTapped {
    [self restoreSnapshot];
    [self refreshAllCards];
    [self refreshStat];
}

// 批量写入：内存写入即时生效，磁盘落盘与系统同步放后台串行队列，避免主线程卡顿
// 联动网络：所有 App 生效，开启=wifi+流量(0)，关闭=断网(1)
- (void)batchWrite:(BOOL)val {
    NSUserDefaults *prefs = NTM_prefs();
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableArray *netIds = [NSMutableArray array];
    NSInteger netPolicy = val ? 0 : 1;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        [ids addObject:aid];
        [prefs setBool:val forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:val forKey:NTM_key(aid, d[@"key"])];
        [prefs setInteger:netPolicy forKey:NTM_netKey(aid)];
        [netIds addObject:aid];
    }
    NSArray *idsCopy = [ids copy];
    NSArray *netIdsCopy = [netIds copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize];
        for (NSString *aid in idsCopy) NTM_syncSystem(aid);
        for (NSString *aid in netIdsCopy) NTM_syncCellular(aid, netPolicy);
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
        if (net) {
            [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)];
            NTM_syncCellularAsync(aid, [net integerValue]);
        }
        NTM_syncSystemAsync(aid);
    }
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; });
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
        [arr addObject:d];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { [self toast:@"导出失败"]; return; }
    NSString *path = [self configPath];
    if (![data writeToFile:path atomically:YES]) { [self toast:@"导出失败，无写入权限"]; return; }
    [self toast:[NSString stringWithFormat:@"已导出 %lu 个应用\n%@", (unsigned long)arr.count, path]];
    // 弹出分享面板，方便保存到"文件"App
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
        if ([dims isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in dims) {
                [prefs setBool:[dims[k] boolValue] forKey:NTM_key(aid, k)];
            }
        }
        id net = d[@"net"];
        if (net) {
            [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)];
            NTM_syncCellularAsync(aid, [net integerValue]);
        }
        NTM_syncSystemAsync(aid);
        count++;
    }
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; });
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
- (void)applySearch {
    [self reloadList];
}
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
