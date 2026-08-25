// BatteryPanel.m — 电池耗电分析设置面板
// 读取 Tweak 记录的数据（/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist）
// 展示：电池总览卡片 + 每 App 耗电排行 + 电量历史
// 玻璃拟态 UI：柔和渐变背景 + 半透明白色模糊卡片 + 大圆角 + 微弱阴影 + 按压缩放
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// PSViewController 是 PreferenceLoader 控制器的正确基类
@interface PSViewController : UIViewController
@end

@interface NTMBatteryPrincipalController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *data;
@property (nonatomic, strong) NSArray *appList;      // 排序后的 app 数组
@property (nonatomic, strong) NSArray *historyList;  // 电量历史
@property (nonatomic) NSInteger currentLevel;
@property (nonatomic) BOOL charging;
@end

// 概览卡片 cell（电池总览）
@interface OverviewCardCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *levelLabel;    // 大号电量百分比
@property (nonatomic, strong) UILabel *statusLabel;   // 充电状态
@property (nonatomic, strong) NSMutableArray<UILabel *> *keyLabels;
@property (nonatomic, strong) NSMutableArray<UILabel *> *valLabels;
@end

// 玻璃拟态列表 cell（排行 + 历史）
@interface GlassCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation OverviewCardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.layer.cornerRadius = 18;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.06;
        _cardView.layer.shadowRadius = 10;
        _cardView.layer.shadowOffset = CGSizeMake(0, 4);
        [self.contentView addSubview:_cardView];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 18;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [_cardView addSubview:blur];

        _levelLabel = [UILabel new];
        _levelLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _levelLabel.font = [UIFont systemFontOfSize:40 weight:UIFontWeightBold];
        _levelLabel.textColor = [UIColor systemRedColor];
        _levelLabel.adjustsFontSizeToFitWidth = YES;
        _levelLabel.minimumScaleFactor = 0.5;
        [_cardView addSubview:_levelLabel];

        _statusLabel = [UILabel new];
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _statusLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [_cardView addSubview:_statusLabel];

        _keyLabels = [NSMutableArray array];
        _valLabels = [NSMutableArray array];
        UILabel *prev = nil;
        for (int i = 0; i < 4; i++) {
            UILabel *k = [UILabel new];
            k.translatesAutoresizingMaskIntoConstraints = NO;
            k.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
            k.textColor = [UIColor colorWithWhite:0.45 alpha:1];
            [_cardView addSubview:k];
            [_keyLabels addObject:k];

            UILabel *v = [UILabel new];
            v.translatesAutoresizingMaskIntoConstraints = NO;
            v.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            v.textColor = [UIColor colorWithWhite:0.15 alpha:1];
            v.textAlignment = NSTextAlignmentRight;
            v.numberOfLines = 1;
            v.lineBreakMode = NSLineBreakByTruncatingTail;
            [_cardView addSubview:v];
            [_valLabels addObject:v];

            [NSLayoutConstraint activateConstraints:@[
                [k.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
                [k.trailingAnchor constraintLessThanOrEqualToAnchor:_cardView.centerXAnchor constant:-8],
                [k.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],

                [v.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
                [v.leadingAnchor constraintGreaterThanOrEqualToAnchor:_cardView.centerXAnchor constant:8],
                [v.centerYAnchor constraintEqualToAnchor:k.centerYAnchor],
            ]];

            if (prev) {
                [k.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10].active = YES;
            } else {
                [k.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:16].active = YES;
            }
            prev = k;
        }
        [prev.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-16].active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_levelLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_levelLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:14],

            [_statusLabel.leadingAnchor constraintEqualToAnchor:_levelLabel.trailingAnchor constant:12],
            [_statusLabel.lastBaselineAnchor constraintEqualToAnchor:_levelLabel.lastBaselineAnchor],
        ]];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.15 animations:^{
        self.cardView.transform = CGAffineTransformMakeScale(0.98, 0.98);
    }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.cardView.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.2 animations:^{
        self.cardView.transform = CGAffineTransformIdentity;
    }];
}

@end

@implementation GlassCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.layer.cornerRadius = 18;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.06;
        _cardView.layer.shadowRadius = 10;
        _cardView.layer.shadowOffset = CGSizeMake(0, 4);
        [self.contentView addSubview:_cardView];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 18;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [_cardView addSubview:blur];

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.layer.cornerRadius = 9;
        _iconView.clipsToBounds = YES;
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1];
        [_cardView addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        _subtitleLabel.numberOfLines = 1;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_subtitleLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _valueLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.numberOfLines = 1;
        _valueLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_valueLabel];

        // 文字列（标题+副标题）用垂直 stack，空副标题自动折叠，行高由内容决定
        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 2;
        textStack.alignment = UIStackViewAlignmentLeading;
        textStack.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:textStack];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_iconView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:40],
            [_iconView.heightAnchor constraintEqualToConstant:40],

            [textStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [textStack.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:12],
            [textStack.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-12],
            [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8],

            [_valueLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_valueLabel.topAnchor constraintGreaterThanOrEqualToAnchor:_cardView.topAnchor constant:10],
            [_valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.15 animations:^{
        self.cardView.transform = CGAffineTransformMakeScale(0.97, 0.97);
    }];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.cardView.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.2 animations:^{
        self.cardView.transform = CGAffineTransformIdentity;
    }];
}

@end

// 常见系统 App 名称映射
static NSString *NTM_appName(NSString *bundleId) {
    static NSDictionary *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"com.apple.mobilesafari": @"Safari 浏览器",
            @"com.apple.mobileslideshow": @"照片",
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.mobilephone": @"电话",
            @"com.apple.mobilemail": @"邮件",
            @"com.apple.Preferences": @"设置",
            @"com.apple.springboard": @"主屏幕",
            @"com.apple.calculator": @"计算器",
            @"com.apple.mobilecal": @"日历",
            @"com.apple.Music": @"音乐",
            @"com.apple.mobileme.fmf1": @"查找",
            @"com.apple.maps": @"地图",
            @"com.apple.camera": @"相机",
            @"com.apple.mobiletimer": @"时钟",
            @"com.apple.weather": @"天气",
            @"com.apple.notes": @"备忘录",
            @"com.apple.reminders": @"提醒事项",
            @"com.apple.Health": @"健康",
            @"com.apple.Passbook": @"钱包",
            @"com.apple.AppStore": @"App Store",
            @"com.apple.facetime": @"FaceTime 通话",
            @"com.apple.mobileme.fmip1": @"查找",
            @"com.apple.MobileStore": @"App Store",
            @"com.apple.Photos": @"照片",
            @"com.apple.wechat": @"微信",
            @"com.tencent.xin": @"微信",
            @"com.tencent.mqq": @"QQ",
            @"com.sina.weibo": @"微博",
            @"com.ss.iphone.ugc.Aweme": @"抖音",
            @"com.taobao.taobao": @"淘宝",
            @"com.taobao.idlefish": @"闲鱼",
            @"com.xunmeng.pinduoduo": @"拼多多",
            @"com.meituan.imeituan": @"美团",
            @"com.dianping.dpscope": @"大众点评",
            @"com.autonavi.minimap": @"高德地图",
            @"com.baidu.BaiduMap": @"百度地图",
            @"com.bilibili.app.blue": @"哔哩哔哩",
            @"com.youku.YouKu": @"优酷",
            @"com.tencent.live4iphone": @"腾讯视频",
            @"com.netease.news": @"网易新闻",
            @"com.tencent.news": @"腾讯新闻",
            @"com.zhihu.ios": @"知乎",
            @"com.xiaomi.hm.health": @"小米运动",
            @"com.huawei.health": @"华为运动健康",
        };
    });
    NSString *n = names[bundleId];
    if (n) return n;
    if ([bundleId hasPrefix:@"com.apple."]) {
        return [bundleId substringFromIndex:10];
    }
    return bundleId;
}

// 图标缓存：避免每次遍历全部 App 加载图标导致卡顿
static NSCache *NTM_iconCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 80;
    });
    return cache;
}

static NSArray *NTM_allApps(void) {
    static NSArray *apps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id ws = [wsClass performSelector:@selector(defaultWorkspace)];
            if (ws && [ws respondsToSelector:@selector(allApplications)]) {
                apps = [ws performSelector:@selector(allApplications)];
            }
        }
    });
    return apps;
}

// 获取 App 图标（带缓存，失败返回 nil）
static UIImage *NTM_appIcon(NSString *bundleId) {
    if (!bundleId.length) return nil;
    UIImage *cached = [NTM_iconCache() objectForKey:bundleId];
    if (cached) return cached;
    NSArray *apps = NTM_allApps();
    for (id proxy in apps) {
        NSString *bid = [proxy valueForKey:@"bundleIdentifier"];
        if ([bid isEqualToString:bundleId]) {
            id icon = [proxy performSelector:@selector(icon)];
            if ([icon isKindOfClass:[UIImage class]]) {
                [NTM_iconCache() setObject:icon forKey:bundleId];
                return icon;
            }
        }
    }
    return nil;
}

// 日期格式化缓存（避免在 cellForRow 里反复创建）
static NSDateFormatter *NTM_formatter(NSString *fmt) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    NSDateFormatter *df = cache[fmt];
    if (!df) {
        df = [NSDateFormatter new];
        df.dateFormat = fmt;
        cache[fmt] = df;
    }
    return df;
}

@implementation NTMBatteryPrincipalController

- (instancetype)init {
    self = [super init];
    if (self) {
        _data = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"电池耗电分析";

    // 柔和低饱和渐变背景
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.82 green:0.90 blue:0.96 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.89 green:0.86 blue:0.95 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.95 green:0.88 blue:0.88 alpha:1].CGColor,
    ];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    UIView *bg = [[UIView alloc] initWithFrame:self.view.bounds];
    [bg.layer addSublayer:gradient];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundView = bg;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 20, 0);
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64;
    [self.view addSubview:_tableView];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    self.navigationItem.rightBarButtonItem = refresh;

    [self reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.backgroundView.frame = self.view.bounds;
    CAGradientLayer *g = (CAGradientLayer *)self.tableView.backgroundView.layer.sublayers.firstObject;
    g.frame = self.view.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)refresh {
    [self reloadData];
}

- (void)reloadData {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist"];
    if (d) {
        _data = [d mutableCopy];
    } else {
        _data = [NSMutableDictionary dictionary];
    }

    UIDevice *dev = [UIDevice currentDevice];
    dev.batteryMonitoringEnabled = YES;
    float lv = dev.batteryLevel;
    _currentLevel = (lv < 0) ? -1 : (NSInteger)(lv * 100 + 0.5);
    _charging = [_data[@"charging"] boolValue];

    // App 列表：按加权时间（前台+后台×0.3）排序，估算每 App 耗电
    NSDictionary *apps = _data[@"apps"];
    NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
    NSInteger totalDrain = (endLevel > 0 && _currentLevel >= 0) ? (endLevel - _currentLevel) : 0;
    if (totalDrain < 0) totalDrain = 0;
    NSMutableArray *list = [NSMutableArray array];
    double totalWeight = 0;
    for (NSString *bid in apps) {
        NSDictionary *info = apps[bid];
        double fg = [info[@"foreground"] doubleValue];
        double bg = [info[@"background"] doubleValue];
        if (fg > 0 || bg > 0) {
            double weight = fg + bg * 0.3;
            [list addObject:@{@"id": bid, @"fg": @(fg), @"bg": @(bg), @"weight": @(weight)}];
            totalWeight += weight;
        }
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double wa = [a[@"weight"] doubleValue];
        double wb = [b[@"weight"] doubleValue];
        if (wa == wb) return NSOrderedSame;
        return wa > wb ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray *finalList = [NSMutableArray array];
    for (NSDictionary *a in list) {
        double weight = [a[@"weight"] doubleValue];
        NSInteger drain = (totalWeight > 0) ? (NSInteger)lround(totalDrain * weight / totalWeight) : 0;
        NSMutableDictionary *ma = [a mutableCopy];
        ma[@"drain"] = @(drain);
        [finalList addObject:ma];
    }
    _appList = finalList;

    // 电量历史：过滤相邻相同电量，倒序最新在前
    NSArray *hist = _data[@"batteryHistory"];
    NSMutableArray *filtered = [NSMutableArray array];
    NSInteger lastLevel = -1;
    for (NSDictionary *e in hist) {
        NSInteger lv = [e[@"level"] integerValue];
        if (lv != lastLevel) {
            [filtered addObject:e];
            lastLevel = lv;
        }
    }
    _historyList = [[filtered reverseObjectEnumerator] allObjects];
    if (_historyList.count > 24) {
        _historyList = [_historyList subarrayWithRange:NSMakeRange(0, 24)];
    }

    [_tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return MAX(_appList.count, 1);
    return MAX(_historyList.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"电池总览";
        case 1: return @"每 App 耗电排行（前台/后台时间）";
        default: return @"电量历史（最近 24 小时）";
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor clearColor];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    label.text = [self tableView:tableView titleForHeaderInSection:section];
    [v addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:22],
        [label.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    return v;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 34;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        OverviewCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"overview"];
        if (!cell) cell = [[OverviewCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"overview"];
        [self configOverviewCell:cell];
        return cell;
    }

    GlassCell *cell = [tableView dequeueReusableCellWithIdentifier:@"glass"];
    if (!cell) cell = [[GlassCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"glass"];
    cell.iconView.image = nil;
    cell.subtitleLabel.text = @"";
    cell.subtitleLabel.hidden = YES;
    cell.valueLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
    cell.valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];

    if (indexPath.section == 1) {
        if (_appList.count) {
            NSDictionary *a = _appList[indexPath.row];
            NSInteger fg = (NSInteger)([a[@"fg"] doubleValue] / 60);
            NSInteger bg = (NSInteger)([a[@"bg"] doubleValue] / 60);
            NSInteger drain = [a[@"drain"] integerValue];
            cell.titleLabel.text = NTM_appName(a[@"id"]);
            cell.iconView.image = NTM_appIcon(a[@"id"]);
            cell.subtitleLabel.hidden = NO;
            if (bg > 0) {
                cell.subtitleLabel.text = [NSString stringWithFormat:@"前台 %ld分 · 后台 %ld分", (long)fg, (long)bg];
            } else {
                cell.subtitleLabel.text = [NSString stringWithFormat:@"前台 %ld分", (long)fg];
            }
            NSInteger total = fg + bg;
            if (drain > 0) {
                cell.valueLabel.text = [NSString stringWithFormat:@"共 %ld分 · 耗电 %ld%%", (long)total, (long)drain];
                cell.valueLabel.textColor = [UIColor systemRedColor];
                cell.valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            } else {
                cell.valueLabel.text = [NSString stringWithFormat:@"共 %ld分", (long)total];
            }
        } else {
            cell.titleLabel.text = @"暂无数据（安装后需运行一段时间积累）";
            cell.subtitleLabel.text = @"";
            cell.valueLabel.text = @"";
        }
    } else {
        if (_historyList.count) {
            NSDictionary *e = _historyList[indexPath.row];
            NSDate *ts = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
            cell.titleLabel.text = [NTM_formatter(@"MM-dd HH:mm") stringFromDate:ts];
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)[e[@"level"] integerValue]];
            cell.valueLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
        } else {
            cell.titleLabel.text = @"暂无记录";
            cell.valueLabel.text = @"";
        }
    }
    return cell;
}

- (void)configOverviewCell:(OverviewCardCell *)cell {
    // 大号电量 + 充电状态
    if (_currentLevel >= 0) {
        cell.levelLabel.text = [NSString stringWithFormat:@"%ld%%", (long)_currentLevel];
        cell.levelLabel.textColor = _charging ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    } else {
        cell.levelLabel.text = @"--";
        cell.levelLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    }
    cell.statusLabel.text = _charging ? @"充电中" : @"未充电";

    // 4 行统计
    NSArray *keys = @[@"上次充电结束", @"本次耗电", @"本次时长", @"数据状态"];
    for (int i = 0; i < 4; i++) {
        cell.keyLabels[i].text = keys[i];
    }

    // 上次充电结束
    NSNumber *chargeEnd = _data[@"lastChargeEnd"];
    cell.valLabels[0].text = chargeEnd ? [NTM_formatter(@"MM-dd HH:mm") stringFromDate:[NSDate dateWithTimeIntervalSince1970:[chargeEnd doubleValue]]] : @"无记录";

    // 本次耗电
    NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
    if (endLevel > 0 && _currentLevel >= 0) {
        NSInteger drain = endLevel - _currentLevel;
        if (drain < 0) drain = 0;
        cell.valLabels[1].text = [NSString stringWithFormat:@"%ld%% → %ld%%（消耗 %ld%%）", (long)endLevel, (long)_currentLevel, (long)drain];
        cell.valLabels[1].textColor = (drain > 0) ? [UIColor systemRedColor] : [UIColor colorWithWhite:0.15 alpha:1];
    } else {
        cell.valLabels[1].text = @"无记录";
        cell.valLabels[1].textColor = [UIColor colorWithWhite:0.15 alpha:1];
    }

    // 本次时长
    if (chargeEnd) {
        NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [chargeEnd doubleValue];
        if (dur < 0) dur = 0;
        NSInteger totalMin = (NSInteger)(dur / 60);
        NSInteger h = totalMin / 60;
        NSInteger m = totalMin % 60;
        if (h > 0) {
            cell.valLabels[2].text = [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)h, (long)m];
        } else {
            cell.valLabels[2].text = [NSString stringWithFormat:@"%ld 分钟", (long)m];
        }
    } else {
        cell.valLabels[2].text = @"无记录";
    }

    // 数据状态
    NSNumber *upd = _data[@"lastUpdate"];
    NSDictionary *apps = _data[@"apps"];
    NSArray *hist = _data[@"batteryHistory"];
    if (upd) {
        NSString *t = [NTM_formatter(@"MM-dd HH:mm:ss") stringFromDate:[NSDate dateWithTimeIntervalSince1970:[upd doubleValue]]];
        cell.valLabels[3].text = [NSString stringWithFormat:@"更新 %@ · %ld App · %ld 条电量",
                                  t, (long)apps.count, (long)hist.count];
    } else {
        cell.valLabels[3].text = @"Tweak 未运行（重启 SpringBoard 生效）";
    }
}

@end
