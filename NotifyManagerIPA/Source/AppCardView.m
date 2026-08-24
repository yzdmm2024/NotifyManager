#import "AppCardView.h"
#import "StorageManager.h"

#pragma mark - 网络按钮颜色

static UIColor *NetColor(NSInteger policy) {
    switch (policy) {
        case 1: return [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1]; // 断网 红
        case 2: return [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1];  // wifi 蓝
        case 3: return [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1]; // 流量 绿
        default: return [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1]; // wifi+流量 青
    }
}

#pragma mark - 网络选项

static NSArray *NetOptions(void) {
    return @[
        @{@"title": @"打开wifi", @"policy": @2},
        @{@"title": @"流量",     @"policy": @3},
        @{@"title": @"wifi+流量", @"policy": @0},
        @{@"title": @"断网",     @"policy": @1},
    ];
}

#pragma mark - AppCardView

@interface AppCardView ()
@property (nonatomic, strong) NSString *appId;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) NSMutableArray<UISwitch *> *dimSwitches;
@property (nonatomic, strong) NSMutableArray<UIButton *> *netButtons;
@property (nonatomic, strong) UIImageView *iconView;
@end

@implementation AppCardView

- (instancetype)initWithApp:(NSDictionary *)app {
    if (self = [super init]) {
        _appId = app[@"id"];
        _appName = app[@"name"];
        _dimSwitches = [NSMutableArray array];
        _netButtons = [NSMutableArray array];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    self.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.85];
    self.layer.cornerRadius = 18;
    self.layer.masksToBounds = NO;
    // 玻璃拟态阴影 — 柔和外阴影
    self.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;
    self.layer.shadowOpacity = 1;
    self.layer.shadowRadius = 12;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    // 内层模糊背景（用 view 模拟玻璃效果不可行，使用半透明白底 + 亮色即可）

    NSArray *dims = [[StorageManager shared] allDims];

    // ── 头部行：图标 + 名称 + 重置 + 总开关 ──
    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.layer.cornerRadius = 9;
    _iconView.clipsToBounds = YES;
    _iconView.backgroundColor = [UIColor colorWithRed:0.88 green:0.90 blue:0.95 alpha:1];
    [_iconView.widthAnchor constraintEqualToConstant:36].active = YES;
    [_iconView.heightAnchor constraintEqualToConstant:36].active = YES;

    [self loadIconAsync];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = _appName;
    nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"重置" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor colorWithRed:0.78 green:0.28 blue:0.28 alpha:1] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *masterLabel = [[UILabel alloc] init];
    masterLabel.text = @"总开关";
    masterLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    masterLabel.textColor = [UIColor colorWithWhite:0.40 alpha:1];

    _masterSwitch = [[UISwitch alloc] init];
    _masterSwitch.onTintColor = [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1];
    [_masterSwitch addTarget:self action:@selector(masterChanged) forControlEvents:UIControlEventValueChanged];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_iconView, nameLabel, resetBtn, masterLabel, _masterSwitch]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;

    // ── 子开关行：5 个维度横排 ──
    NSMutableArray *dimItems = [NSMutableArray array];
    for (NSDictionary *d in dims) {
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = d[@"title"];
        lbl.font = [UIFont systemFontOfSize:11];
        lbl.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        lbl.textAlignment = NSTextAlignmentCenter;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        sw.onTintColor = [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1];
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

    // ── 网络按钮行 ──
    UIView *netRow = [self buildNetRow];

    // ── 垂直堆叠 ──
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[header, dimRow, netRow]];
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

- (void)loadIconAsync {
    NSString *bid = _appId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *icon = nil;
        @try {
            id (*f)(id, SEL, id, long long, double) = (id (*)(id, SEL, id, long long, double))objc_msgSend;
            id iconCls = (id)UIImage.class;
            icon = f(iconCls, sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:"), bid, 0, 2.0);
        } @catch (NSException *e) {}
        if (!icon) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.iconView.image = icon;
        });
    });
}

- (UIView *)buildNetRow {
    UILabel *netLabel = [[UILabel alloc] init];
    netLabel.text = @"网络";
    netLabel.font = [UIFont systemFontOfSize:11];
    netLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
    [netLabel.widthAnchor constraintEqualToConstant:34].active = YES;

    NSMutableArray *btns = [NSMutableArray array];
    for (NSDictionary *opt in NetOptions()) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:opt[@"title"] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        btn.layer.cornerRadius = 9;
        btn.clipsToBounds = YES;
        btn.tag = [opt[@"policy"] integerValue];
        [btn addTarget:self action:@selector(netTapped:) forControlEvents:UIControlEventTouchUpInside];
        [btn.heightAnchor constraintEqualToConstant:30].active = YES;
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

#pragma mark - Actions

- (void)masterChanged {
    [[StorageManager shared] writeMaster:_masterSwitch.on forApp:_appId];
    [self reloadFromPrefs];
    if (_onValueChanged) _onValueChanged(_appId);
}

- (void)dimChanged:(UISwitch *)sender {
    NSUInteger idx = [_dimSwitches indexOfObject:sender];
    if (idx == NSNotFound || idx >= [[StorageManager shared] allDims].count) return;
    NSString *dimKey = [[StorageManager shared] dimKeyAtIndex:idx];
    [[StorageManager shared] writeEnabled:sender.on forApp:_appId dim:dimKey];
    [self reloadFromPrefs];
    if (_onValueChanged) _onValueChanged(_appId);
}

- (void)netTapped:(UIButton *)sender {
    [[StorageManager shared] writeNetPolicy:sender.tag forApp:_appId];
    [self reloadFromPrefs];
    if (_onValueChanged) _onValueChanged(_appId);
}

- (void)resetTapped {
    [[StorageManager shared] resetApp:_appId];
    [self reloadFromPrefs];
    if (_onValueChanged) _onValueChanged(_appId);
}

#pragma mark - Reload

- (void)reloadFromPrefs {
    StorageManager *mgr = [StorageManager shared];
    BOOL en = [mgr readMasterForApp:_appId];
    _masterSwitch.on = en;

    BOOL anyVisible = [mgr readEnabledForApp:_appId dim:@"lock"] ||
                      [mgr readEnabledForApp:_appId dim:@"nc"] ||
                      [mgr readEnabledForApp:_appId dim:@"banner"];
    BOOL soundBadgeEnabled = en && anyVisible;

    NSArray *dims = [mgr allDims];
    for (NSUInteger i = 0; i < dims.count && i < _dimSwitches.count; i++) {
        UISwitch *sw = _dimSwitches[i];
        sw.on = [mgr readEnabledForApp:_appId dim:dims[i][@"key"]];
        // 声音(3) / 标记(4) 依赖总开关 + 至少一个可见通道
        if (i == 3 || i == 4) sw.enabled = soundBadgeEnabled;
    }

    // 更新网络按钮高亮
    NSInteger netPolicy = [mgr readNetPolicyForApp:_appId];
    for (UIButton *btn in _netButtons) {
        BOOL selected = (btn.tag == netPolicy);
        if (selected) {
            btn.backgroundColor = [NetColor(netPolicy) colorWithAlphaComponent:0.18];
            [btn setTitleColor:NetColor(netPolicy) forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
            [btn setTitleColor:[UIColor colorWithWhite:0.45 alpha:1] forState:UIControlStateNormal];
        }
    }
}

@end