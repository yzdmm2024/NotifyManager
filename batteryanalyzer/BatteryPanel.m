// BatteryPanel.m — 电池耗电分析设置面板
// 读取 Tweak 记录的数据（/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist）
// 展示：电池总览 + 每 App 耗电排行 + 电量历史
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

// 玻璃拟态卡片 cell
@interface GlassCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
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

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        _titleLabel.numberOfLines = 0;
        [_cardView addSubview:_titleLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _valueLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.numberOfLines = 0;
        [_cardView addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_titleLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:14],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-14],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8],

            [_valueLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_cardView.leadingAnchor constant:18],
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
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.facetime": @"FaceTime 通话",
            @"com.apple.mobileme.fmf1": @"查找",
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
    // 去掉 com.apple. 前缀显示
    if ([bundleId hasPrefix:@"com.apple."]) {
        return [bundleId substringFromIndex:10];
    }
    return bundleId;
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
    _tableView.estimatedRowHeight = 56;
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

    // 当前电量
    UIDevice *dev = [UIDevice currentDevice];
    dev.batteryMonitoringEnabled = YES;
    float lv = dev.batteryLevel;
    _currentLevel = (lv < 0) ? -1 : (NSInteger)(lv * 100 + 0.5);
    _charging = [_data[@"charging"] boolValue];

    // App 列表：按前台时间排序
    NSDictionary *apps = _data[@"apps"];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *bid in apps) {
        NSDictionary *info = apps[bid];
        double fg = [info[@"foreground"] doubleValue];
        double bg = [info[@"background"] doubleValue];
        if (fg > 0 || bg > 0) {
            [list addObject:@{@"id": bid, @"fg": @(fg), @"bg": @(bg)}];
        }
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double wa = [a[@"fg"] doubleValue] + [a[@"bg"] doubleValue] * 0.3;
        double wb = [b[@"fg"] doubleValue] + [b[@"bg"] doubleValue] * 0.3;
        if (wa == wb) return NSOrderedSame;
        return wa > wb ? NSOrderedAscending : NSOrderedDescending;
    }];
    _appList = list;

    // 电量历史（倒序，最新在前）
    NSArray *hist = _data[@"batteryHistory"];
    _historyList = [[hist reverseObjectEnumerator] allObjects];
    if (_historyList.count > 24) {
        _historyList = [_historyList subarrayWithRange:NSMakeRange(0, 24)];
    }

    [_tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 5;
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
    GlassCell *cell = [tableView dequeueReusableCellWithIdentifier:@"glass"];
    if (!cell) cell = [[GlassCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"glass"];

    if (indexPath.section == 0) {
        [self configOverviewCell:cell row:indexPath.row];
    } else if (indexPath.section == 1) {
        if (_appList.count) {
            NSDictionary *a = _appList[indexPath.row];
            cell.titleLabel.text = NTM_appName(a[@"id"]);
            NSInteger fg = (NSInteger)([a[@"fg"] doubleValue] / 60);
            NSInteger bg = (NSInteger)([a[@"bg"] doubleValue] / 60);
            cell.valueLabel.text = [NSString stringWithFormat:@"前台 %ld分 · 后台 %ld分", (long)fg, (long)bg];
        } else {
            cell.titleLabel.text = @"暂无数据（安装后需运行一段时间积累）";
            cell.valueLabel.text = @"";
        }
    } else {
        if (_historyList.count) {
            NSDictionary *e = _historyList[indexPath.row];
            NSDate *ts = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"MM-dd HH:mm";
            cell.titleLabel.text = [df stringFromDate:ts];
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)[e[@"level"] integerValue]];
        } else {
            cell.titleLabel.text = @"暂无记录";
            cell.valueLabel.text = @"";
        }
    }
    return cell;
}

- (void)configOverviewCell:(GlassCell *)cell row:(NSInteger)row {
    cell.titleLabel.numberOfLines = 1;
    switch (row) {
        case 0: {
            cell.titleLabel.text = @"当前电量";
            if (_currentLevel >= 0) {
                cell.valueLabel.text = [NSString stringWithFormat:@"%ld%%%@", (long)_currentLevel, _charging ? @"（充电中）" : @""];
            } else {
                cell.valueLabel.text = @"未知";
            }
            break;
        }
        case 1: {
            cell.titleLabel.text = @"充电状态";
            cell.valueLabel.text = _charging ? @"充电中" : @"未充电";
            break;
        }
        case 2: {
            cell.titleLabel.text = @"上次充电结束";
            NSNumber *ts = _data[@"lastChargeEnd"];
            if (ts) {
                NSDateFormatter *df = [NSDateFormatter new];
                df.dateFormat = @"MM-dd HH:mm";
                cell.valueLabel.text = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[ts doubleValue]]];
            } else {
                cell.valueLabel.text = @"无记录";
            }
            break;
        }
        case 3: {
            cell.titleLabel.text = @"本次耗电";
            NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
            if (endLevel > 0 && _currentLevel >= 0) {
                NSInteger drain = endLevel - _currentLevel;
                if (drain < 0) drain = 0;
                cell.valueLabel.text = [NSString stringWithFormat:@"%ld%% → %ld%%（消耗 %ld%%）",
                                        (long)endLevel, (long)_currentLevel, (long)drain];
            } else {
                cell.valueLabel.text = @"无记录";
            }
            break;
        }
        case 4: {
            cell.titleLabel.text = @"本次时长";
            NSNumber *ts = _data[@"lastChargeEnd"];
            if (ts) {
                NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [ts doubleValue];
                if (dur < 0) dur = 0;
                NSInteger h = (NSInteger)(dur / 3600);
                NSInteger m = (NSInteger)((NSInteger)dur % 3600) / 60;
                cell.valueLabel.text = [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)h, (long)m];
            } else {
                cell.valueLabel.text = @"无记录";
            }
            break;
        }
    }
}

@end
