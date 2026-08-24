// NotifyManager.m — 通知管理设置面板（自定义现代 UI）
// 枚举已安装 App，按分类(用户/巨魔/系统)展示
// 每个 App：总开关 + 锁定屏幕/通知中心/横幅/声音/标记 子开关 + 单应用重置
// 支持：分类切换、搜索、统计、批量开启/关闭/恢复自定义、导入/导出配置
// 配置保存到 NSUserDefaults suiteName，Tweak 读取并拦截通知
// 设置变更时同步到系统通知设置 (BBSettingsGateway)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 接口声明
// PSViewController 是 PreferenceLoader 控制器的正确基类（实现 PSController 协议），
// 提供 setSpecifier:/setParentController:/setRootController: 等全部集成方法，
// 避免 controllerForSpecifier: 调用未实现方法导致 unrecognized selector 崩溃。
@interface PSViewController : UIViewController
@end

@interface NTMPrincipalController : PSViewController <UISearchBarDelegate, UIDocumentPickerDelegate>
@end

#pragma mark - 存储: NSUserDefaults suiteName (Tweak 读取同一份)
static NSString *NTM_suite = @"com.ntm.notifymanager";
static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    id v = [prefs objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    [prefs setBool:val forKey:NTM_key(appId, dim)];
    [prefs synchronize];
}

#pragma mark - 同步到系统通知设置 (BBSettingsGateway)
// 让"设置 → 通知"里的系统设置跟随本面板的开关，双向一致
static void NTM_syncSystem(NSString *appId) {
    if (!appId.length) return;
    @try {
        Class gwCls = NSClassFromString(@"BBSettingsGateway");
        if (!gwCls) return;
        id gateway = [[gwCls alloc] init];
        if (!gateway) return;
        id info = [gateway performSelector:@selector(sectionInfoForSectionID:) withObject:appId];
        if (!info) return;
        BOOL en = NTM_read(appId, @"en");
        [info setValue:@(en) forKey:@"allowsNotifications"];
        [info setValue:@(NTM_read(appId, @"lock")) forKey:@"showsInLockScreen"];
        [info setValue:@(NTM_read(appId, @"nc")) forKey:@"showsInNotificationCenter"];
        [info setValue:@(NTM_read(appId, @"banner") ? 1 : 0) forKey:@"alertType"];
        [info setValue:@(NTM_read(appId, @"sound")) forKey:@"soundEnabled"];
        [info setValue:@(NTM_read(appId, @"badge")) forKey:@"badgeEnabled"];
        SEL setSel = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gateway respondsToSelector:setSel]) {
            [gateway performSelector:setSel withObject:info withObject:appId];
        }
    } @catch(NSException *e) {}
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
    for (id proxy in proxies) {
        NSString *bid  = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        NSURL *url     = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
        NSString *name = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("localizedName"));
        NSString *path = [(NSURL *)url path] ?: @"";
        if (!bid.length || !path.length) continue;
        NSString *cat = NTM_catOfProxy(proxy);
        if ([cat isEqualToString:@"系统应用"] &&
            ([path hasPrefix:@"/System/Library/"] && ![bid hasPrefix:@"com.apple"])) continue;
        [out addObject:@{ @"id":bid, @"name":(name.length?name:bid), @"cat":cat,
                          @"icon":[NSNull null] }];
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
@property (nonatomic, copy) void (^onDimChange)(NSString *appId, NSString *dim, BOOL val);
@property (nonatomic, copy) void (^onMasterChange)(NSString *appId, BOOL val);
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

    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[header, dimRow]];
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

- (void)masterChanged:(UISwitch *)sender {
    NTM_write(_appId, @"en", sender.on);
    // 联动：总开关切换时同步所有子开关
    for (NSDictionary *d in NTM_dims()) NTM_write(_appId, d[@"key"], sender.on);
    [self reloadFromPrefs];
    NTM_syncSystem(_appId);
    if (_onMasterChange) _onMasterChange(_appId, sender.on);
}

- (void)dimChanged:(UISwitch *)sender {
    NSUInteger idx = [_dimSwitches indexOfObject:sender];
    if (idx == NSNotFound || idx >= NTM_dims().count) return;
    NSDictionary *d = NTM_dims()[idx];
    NTM_write(_appId, d[@"key"], sender.on);
    // 联动：所有子开关都开 → 总开关开；任一子开关关 → 总开关关
    BOOL allOn = YES;
    for (UISwitch *sw in _dimSwitches) {
        if (!sw.on) { allOn = NO; break; }
    }
    _masterSwitch.on = allOn;
    NTM_write(_appId, @"en", allOn);
    NTM_syncSystem(_appId);
    if (_onDimChange) _onDimChange(_appId, d[@"key"], sender.on);
}

- (void)resetTapped {
    NTM_write(_appId, @"en", YES);
    for (NSDictionary *d in NTM_dims()) NTM_write(_appId, d[@"key"], YES);
    [self reloadFromPrefs];
    NTM_syncSystem(_appId);
    if (_onReset) _onReset(_appId);
}

- (void)reloadFromPrefs {
    _masterSwitch.on = NTM_read(_appId, @"en");
    NSArray *dims = NTM_dims();
    for (NSUInteger i = 0; i < dims.count && i < _dimSwitches.count; i++) {
        ((UISwitch *)_dimSwitches[i]).on = NTM_read(_appId, dims[i][@"key"]);
    }
}

@end

#pragma mark - 控制器
@implementation NTMPrincipalController {
    UISegmentedControl *_catSeg;
    UISegmentedControl *_batchSeg;
    UISearchBar *_searchBar;
    UILabel *_statLabel;
    UIScrollView *_scrollView;
    UIStackView *_listStack;
    UIActivityIndicatorView *_spinner;
    NSMutableArray *_cards;
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
    _cards = [NSMutableArray array];

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

    _batchSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部开启", @"全部关闭", @"自定义"]];
    _batchSeg.selectedSegmentIndex = 2;
    [_batchSeg addTarget:self action:@selector(batchChanged) forControlEvents:UIControlEventValueChanged];

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.placeholder = @"搜索应用名称";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.backgroundImage = [UIImage new];

    _statLabel = [[UILabel alloc] init];
    _statLabel.font = [UIFont systemFontOfSize:12];
    _statLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    _listStack = [[UIStackView alloc] init];
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = 12;

    UIButton *exportBtn = NTM_pillButton(@"导出配置",
        [UIColor colorWithRed:0.35 green:0.56 blue:1.0 alpha:0.15],
        [UIColor colorWithRed:0.17 green:0.35 blue:0.72 alpha:1]);
    [exportBtn addTarget:self action:@selector(exportConfig) forControlEvents:UIControlEventTouchUpInside];

    UIButton *importBtn = NTM_pillButton(@"导入配置",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [importBtn addTarget:self action:@selector(importConfig) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[_batchSeg, _statLabel, _searchBar, _catSeg, _scrollView, exportBtn, importBtn]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    _listStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_listStack];

    [NSLayoutConstraint activateConstraints:@[
        [_batchSeg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_batchSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_batchSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_statLabel.topAnchor constraintEqualToAnchor:_batchSeg.bottomAnchor constant:8],
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

        // 关键修复：滚动列表必须位于分类栏(catSeg)之下，否则会盖住分类/搜索/统计
        [_scrollView.topAnchor constraintEqualToAnchor:_catSeg.bottomAnchor constant:12],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:exportBtn.topAnchor constant:-12],

        [_listStack.topAnchor constraintEqualToAnchor:_scrollView.topAnchor constant:4],
        [_listStack.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor constant:16],
        [_listStack.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor constant:-16],
        [_listStack.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-32],
        [_listStack.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:-4],
    ]];
}

- (void)hideSpinner {
    [_spinner stopAnimating];
    [_spinner removeFromSuperview];
    _spinner = nil;
}

#pragma mark - 列表
- (void)reloadList {
    for (UIView *v in [_listStack.arrangedSubviews copy]) {
        [_listStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_cards removeAllObjects];

    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        if (![app[@"cat"] isEqualToString:_curCat]) continue;
        if (_searchText.length) {
            NSString *name = app[@"name"];
            if (![name localizedCaseInsensitiveContainsString:_searchText]) continue;
        }
        [filtered addObject:app];
    }
    _curApps = filtered;

    if (!filtered.count) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"该分类暂无应用";
        empty.font = [UIFont systemFontOfSize:14];
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        empty.textAlignment = NSTextAlignmentCenter;
        [_listStack addArrangedSubview:empty];
        [empty.heightAnchor constraintEqualToConstant:80].active = YES;
        [self hideSpinner];
        [self refreshStat];
        return;
    }

    // 分批创建卡片（每批 40 张），让转圈动画持续、UI 保持响应
    __block NSUInteger idx = 0;
    __weak typeof(self) wself = self;
    __block void (^nextBatch)(void);
    nextBatch = ^{
        typeof(self) sself = wself;
        if (!sself) return;
        NSUInteger end = MIN(idx + 40, filtered.count);
        for (; idx < end; idx++) {
            NSDictionary *app = filtered[idx];
            NTMAppCardView *card = [[NTMAppCardView alloc] initWithApp:app];
            [card.heightAnchor constraintEqualToConstant:122].active = YES;
            __weak typeof(sself) ws = sself;
            card.onDimChange = ^(NSString *aid, NSString *dim, BOOL val) { [ws refreshStat]; };
            card.onMasterChange = ^(NSString *aid, BOOL val) { [ws refreshStat]; };
            card.onReset = ^(NSString *aid) { [ws refreshStat]; };
            [sself->_listStack addArrangedSubview:card];
            [sself->_cards addObject:card];
        }
        if (idx < filtered.count) {
            dispatch_async(dispatch_get_main_queue(), nextBatch);
        } else {
            [sself hideSpinner];
            [sself refreshStat];
        }
    };
    dispatch_async(dispatch_get_main_queue(), nextBatch);
}

// 批量操作后直接刷新现有卡片开关，避免重建列表
- (void)refreshAllCards {
    for (NTMAppCardView *card in _cards) [card reloadFromPrefs];
}

- (void)refreshStat {
    NSInteger total = 0, on = 0;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        if (NTM_read(aid, @"en")) on++;
        total++;
        for (NSDictionary *d in NTM_dims()) {
            total++;
            if (NTM_read(aid, d[@"key"])) on++;
        }
    }
    _statLabel.text = [NSString stringWithFormat:@"当前分类：%@    已开启 %ld / %ld 项",
                       _curCat, (long)on, (long)total];
}

#pragma mark - 交互
- (void)catChanged {
    NSArray *cats = @[@"用户应用", @"巨魔应用", @"系统应用"];
    _curCat = cats[_catSeg.selectedSegmentIndex];
    _batchSeg.selectedSegmentIndex = 2;
    [self reloadList];
}

- (void)batchChanged {
    NSInteger idx = _batchSeg.selectedSegmentIndex;
    if (idx == 0) {
        [self saveSnapshot];
        [self batchWrite:YES];
        [self refreshAllCards];
        [self refreshStat];
        [self toast:@"已全部开启"];
    } else if (idx == 1) {
        [self saveSnapshot];
        [self batchWrite:NO];
        [self refreshAllCards];
        [self refreshStat];
        [self toast:@"已全部关闭"];
    } else {
        [self restoreSnapshot];
        [self refreshAllCards];
        [self refreshStat];
        [self toast:@"已恢复自定义设置"];
    }
    _batchSeg.selectedSegmentIndex = 2;
}

// 批量写入：一次 synchronize，避免 2000+ 次磁盘写导致 UI 冻结
- (void)batchWrite:(BOOL)val {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        [ids addObject:aid];
        [prefs setBool:val forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:val forKey:NTM_key(aid, d[@"key"])];
    }
    [prefs synchronize];
    for (NSString *aid in ids) NTM_syncSystem(aid);
}

- (void)saveSnapshot {
    [_snapshot removeAllObjects];
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @(NTM_read(aid, @"en"));
        for (NSDictionary *dim in NTM_dims()) d[dim[@"key"]] = @(NTM_read(aid, dim[@"key"]));
        _snapshot[aid] = d;
    }
}

- (void)restoreSnapshot {
    for (NSString *aid in _snapshot) {
        NSDictionary *d = _snapshot[aid];
        id en = d[@"en"];
        if (en) NTM_write(aid, @"en", [en boolValue]);
        for (NSDictionary *dim in NTM_dims()) {
            id v = d[dim[@"key"]];
            if (v) NTM_write(aid, dim[@"key"], [v boolValue]);
        }
        NTM_syncSystem(aid);
    }
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
    for (NSDictionary *d in arr) {
        NSString *aid = d[@"appId"];
        if (!aid.length) continue;
        id en = d[@"en"];
        if (en) NTM_write(aid, @"en", [en boolValue]);
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in dims) {
                NTM_write(aid, k, [dims[k] boolValue]);
            }
        }
        NTM_syncSystem(aid);
        count++;
    }
    [self refreshAllCards];
    [self refreshStat];
    [self toast:[NSString stringWithFormat:@"已导入 %ld 个应用", (long)count]];
}

#pragma mark - 搜索
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _searchText = searchText ?: @"";
    [self reloadList];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
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
