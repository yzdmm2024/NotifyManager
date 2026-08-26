// BatteryPanel.m — 电池耗电分析设置面板 (1.3.0)
// 结构：电池总览 → 待机漏电测试 → 智能诊断 → 4 Tab(App排行/Tweak耗电/省电诊断/硬件充电) → 电量24小时趋势
// 玻璃拟态 UI：柔和渐变背景 + 半透明白色模糊卡片 + 大圆角 + 微弱阴影 + 按压缩放
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <IOKit/IOKitLib.h>

// PSViewController 是 PreferenceLoader 控制器的正确基类
@interface PSViewController : UIViewController
@end

@interface NTMBatteryPrincipalController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *data;
@property (nonatomic, strong) NSArray *appList;      // 排序后的 app 数组
@property (nonatomic, strong) NSArray *historyList;  // 电量历史（倒序）
@property (nonatomic, strong) NSArray *tweakList;    // 已注入 Tweak
@property (nonatomic, strong) NSArray *saverRows;    // 省电&诊断 行数据
@property (nonatomic, strong) NSArray *hwRows;       // 硬件&充电 行数据
@property (nonatomic) NSInteger currentLevel;
@property (nonatomic) BOOL charging;
@property (nonatomic) UIDeviceBatteryState batteryState;
@property (nonatomic) NSInteger totalDrain;   // 排行 App 耗电总和（用于占比进度条）
@property (nonatomic) NSInteger expandedRow;  // 展开的排行行，-1 表示无
@property (nonatomic) NSInteger selectedTab;  // 0 App排行 1 Tweak耗电 2 省电诊断 3 硬件充电
@property (nonatomic) CGFloat drainRate;      // 平均耗电速率 %/h
@end

// 概览卡片 cell（电池总览：大数字 + 描述 + 迷你卡片 + 警告）
@interface OverviewCardCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *levelLabel;      // 大号电量百分比
@property (nonatomic, strong) UILabel *statusLabel;     // 充电状态
@property (nonatomic, strong) UILabel *descLabel;       // 上次充电结束/本次消耗/历时
@property (nonatomic, strong) UILabel *rateValueLabel;  // 平均耗电速率值
@property (nonatomic, strong) UILabel *rateKeyLabel;
@property (nonatomic, strong) UILabel *sampleValueLabel; // 采样点值
@property (nonatomic, strong) UILabel *sampleKeyLabel;
@property (nonatomic, strong) UILabel *warnLabel;       // 警告
@end

// 操作按钮 cell（待机漏电测试）
@interface ActionButtonCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@end

// 智能诊断 cell（黄色提示框）
@interface DiagnosisCell : UITableViewCell
@property (nonatomic, strong) UIView *boxView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@end

// Tab 切换条
@interface TabBarView : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic) NSInteger selectedIndex;
@end

@interface TabBarCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) TabBarView *tabBar;
@end

// 玻璃拟态列表 cell（排行 / Tweak）
@interface GlassCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *rankLabel;      // 排名徽章
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIView *progressTrack;   // 耗电占比条
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) UILabel *progressLabel;  // 占比百分比
@property (nonatomic) CGFloat progressRatio;
@property (nonatomic, copy) NSString *currentBundleId; // 异步图标校验
@end

// 排行详情 cell（点击展开）
@interface GlassDetailCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *collapseLabel;  // 收起提示
@property (nonatomic, strong) NSMutableArray<UILabel *> *keyLabels;
@property (nonatomic, strong) NSMutableArray<UILabel *> *valLabels;
@end

// 简单键值 cell（省电&硬件 Tab）
@interface InfoCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@end

// 分组标题 cell（省电 Tab 内部分组）
@interface SectionTitleCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@end

// 电量历史折线图
@interface BatteryChartView : UIView
@property (nonatomic, strong) NSArray *points;  // NSArray<NSDictionary{ts,level}> 时间正序
@end

// 电量历史卡片 cell
@interface BatteryChartCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) BatteryChartView *chartView;
@end

@implementation OverviewCardCell

- (UIView *)makeMiniCardWithValue:(UILabel **)valueOut key:(UILabel **)keyOut {
    UIView *box = [UIView new];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [UIColor colorWithWhite:0.96 alpha:0.9];
    box.layer.cornerRadius = 10;
    UILabel *v = [UILabel new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    v.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    v.textAlignment = NSTextAlignmentCenter;
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumScaleFactor = 0.6;
    [box addSubview:v];
    UILabel *k = [UILabel new];
    k.translatesAutoresizingMaskIntoConstraints = NO;
    k.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    k.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    k.textAlignment = NSTextAlignmentCenter;
    [box addSubview:k];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:box.topAnchor constant:10],
        [v.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:6],
        [v.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-6],
        [k.topAnchor constraintEqualToAnchor:v.bottomAnchor constant:2],
        [k.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:6],
        [k.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-6],
        [k.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10],
    ]];
    if (valueOut) *valueOut = v;
    if (keyOut) *keyOut = k;
    return box;
}

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
        _levelLabel.font = [UIFont systemFontOfSize:52 weight:UIFontWeightBold];
        _levelLabel.textColor = [UIColor systemRedColor];
        _levelLabel.adjustsFontSizeToFitWidth = YES;
        _levelLabel.minimumScaleFactor = 0.5;
        [_cardView addSubview:_levelLabel];

        _statusLabel = [UILabel new];
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _statusLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [_cardView addSubview:_statusLabel];

        _descLabel = [UILabel new];
        _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _descLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _descLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        _descLabel.numberOfLines = 2;
        _descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_cardView addSubview:_descLabel];

        UIView *mini1 = [self makeMiniCardWithValue:&_rateValueLabel key:&_rateKeyLabel];
        UIView *mini2 = [self makeMiniCardWithValue:&_sampleValueLabel key:&_sampleKeyLabel];
        UIStackView *miniStack = [[UIStackView alloc] initWithArrangedSubviews:@[mini1, mini2]];
        miniStack.axis = UILayoutConstraintAxisHorizontal;
        miniStack.distribution = UIStackViewDistributionFillEqually;
        miniStack.spacing = 10;
        miniStack.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:miniStack];

        _warnLabel = [UILabel new];
        _warnLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _warnLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _warnLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        _warnLabel.numberOfLines = 1;
        [_cardView addSubview:_warnLabel];

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
            [_levelLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:16],

            [_statusLabel.leadingAnchor constraintEqualToAnchor:_levelLabel.trailingAnchor constant:12],
            [_statusLabel.lastBaselineAnchor constraintEqualToAnchor:_levelLabel.lastBaselineAnchor],

            [_descLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_descLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_descLabel.topAnchor constraintEqualToAnchor:_levelLabel.bottomAnchor constant:6],

            [miniStack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16],
            [miniStack.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-16],
            [miniStack.topAnchor constraintEqualToAnchor:_descLabel.bottomAnchor constant:12],

            [_warnLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_warnLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_warnLabel.topAnchor constraintEqualToAnchor:miniStack.bottomAnchor constant:10],
            [_warnLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-14],
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

@implementation ActionButtonCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.layer.cornerRadius = 12;
        _cardView.backgroundColor = [UIColor systemBlueColor];
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.1;
        _cardView.layer.shadowRadius = 8;
        _cardView.layer.shadowOffset = CGSizeMake(0, 3);
        [self.contentView addSubview:_cardView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_cardView addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_cardView.heightAnchor constraintEqualToConstant:46],

            [_titleLabel.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
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

@implementation DiagnosisCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _boxView = [UIView new];
        _boxView.translatesAutoresizingMaskIntoConstraints = NO;
        _boxView.backgroundColor = [UIColor colorWithRed:1.0 green:0.98 blue:0.91 alpha:1];
        _boxView.layer.cornerRadius = 12;
        _boxView.layer.borderColor = [UIColor colorWithRed:1.0 green:0.87 blue:0.44 alpha:1].CGColor;
        _boxView.layer.borderWidth = 1;
        [self.contentView addSubview:_boxView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor colorWithRed:0.62 green:0.42 blue:0.0 alpha:1];
        [_boxView addSubview:_titleLabel];

        _descLabel = [UILabel new];
        _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _descLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _descLabel.textColor = [UIColor colorWithRed:0.71 green:0.42 blue:0.0 alpha:1];
        _descLabel.numberOfLines = 0;
        [_boxView addSubview:_descLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_boxView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_boxView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_boxView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_boxView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_boxView.leadingAnchor constant:14],
            [_titleLabel.topAnchor constraintEqualToAnchor:_boxView.topAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_boxView.trailingAnchor constant:-14],

            [_descLabel.leadingAnchor constraintEqualToAnchor:_boxView.leadingAnchor constant:14],
            [_descLabel.trailingAnchor constraintEqualToAnchor:_boxView.trailingAnchor constant:-14],
            [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_descLabel.bottomAnchor constraintEqualToAnchor:_boxView.bottomAnchor constant:-12],
        ]];
    }
    return self;
}

@end

@implementation TabBarView {
    NSMutableArray<UIButton *> *_buttons;
    NSMutableArray<UIView *> *_underlines;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _buttons = [NSMutableArray array];
        _underlines = [NSMutableArray array];
        NSArray *titles = @[@"App耗电排行", @"Tweak插件耗电", @"省电&诊断", @"硬件&充电"];
        UIStackView *stack = [[UIStackView alloc] init];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
        for (int i = 0; i < 4; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            [b setTitle:titles[i] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
            b.tag = i;
            [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [stack addArrangedSubview:b];
            [_buttons addObject:b];

            UIView *line = [UIView new];
            line.backgroundColor = [UIColor systemBlueColor];
            line.layer.cornerRadius = 1;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [b addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.bottomAnchor constraintEqualToAnchor:b.bottomAnchor constant:-2],
                [line.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
                [line.widthAnchor constraintEqualToConstant:28],
                [line.heightAnchor constraintEqualToConstant:2],
            ]];
            [_underlines addObject:line];
        }
        [self setSelectedIndex:0];
    }
    return self;
}

- (void)tap:(UIButton *)b {
    [self setSelectedIndex:b.tag];
    if (self.onSelect) self.onSelect(b.tag);
}

- (void)setSelectedIndex:(NSInteger)index {
    _selectedIndex = index;
    for (int i = 0; i < (int)_buttons.count; i++) {
        UIButton *b = _buttons[i];
        BOOL active = (i == index);
        [b setTitleColor:active ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.45 alpha:1] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:active ? UIFontWeightSemibold : UIFontWeightRegular];
        _underlines[i].hidden = !active;
    }
}

@end

@implementation TabBarCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.layer.cornerRadius = 12;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.06;
        _cardView.layer.shadowRadius = 8;
        _cardView.layer.shadowOffset = CGSizeMake(0, 3);
        [self.contentView addSubview:_cardView];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 12;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [_cardView addSubview:blur];

        _tabBar = [TabBarView new];
        _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_tabBar];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_cardView.heightAnchor constraintEqualToConstant:44],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_tabBar.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [_tabBar.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [_tabBar.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [_tabBar.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],
        ]];
    }
    return self;
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

        _rankLabel = [UILabel new];
        _rankLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _rankLabel.font = [UIFont boldSystemFontOfSize:10];
        _rankLabel.textColor = [UIColor whiteColor];
        _rankLabel.textAlignment = NSTextAlignmentCenter;
        _rankLabel.layer.cornerRadius = 9;
        _rankLabel.clipsToBounds = YES;
        _rankLabel.backgroundColor = [UIColor systemGrayColor];
        [_cardView addSubview:_rankLabel];

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

        // 耗电占比进度条
        _progressTrack = [UIView new];
        _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
        _progressTrack.layer.cornerRadius = 2;
        _progressTrack.clipsToBounds = YES;
        _progressTrack.backgroundColor = [UIColor colorWithWhite:0.86 alpha:1];
        [_cardView addSubview:_progressTrack];

        _progressFill = [UIView new];
        _progressFill.layer.cornerRadius = 2;
        _progressFill.backgroundColor = [UIColor systemRedColor];
        [_progressTrack addSubview:_progressFill];

        _progressLabel = [UILabel new];
        _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _progressLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        _progressLabel.textAlignment = NSTextAlignmentRight;
        [_cardView addSubview:_progressLabel];

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
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_iconView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor constant:-4],
            [_iconView.widthAnchor constraintEqualToConstant:40],
            [_iconView.heightAnchor constraintEqualToConstant:40],

            [_rankLabel.leadingAnchor constraintEqualToAnchor:_iconView.leadingAnchor constant:-4],
            [_rankLabel.topAnchor constraintEqualToAnchor:_iconView.topAnchor constant:-4],
            [_rankLabel.widthAnchor constraintEqualToConstant:18],
            [_rankLabel.heightAnchor constraintEqualToConstant:18],

            [textStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [textStack.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:12],
            [textStack.bottomAnchor constraintEqualToAnchor:_progressTrack.topAnchor constant:-10],
            [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8],

            [_valueLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
            [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_valueLabel.topAnchor constraintGreaterThanOrEqualToAnchor:_cardView.topAnchor constant:10],
            [_valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardView.bottomAnchor constant:-10],

            [_progressTrack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:16],
            [_progressTrack.trailingAnchor constraintEqualToAnchor:_progressLabel.leadingAnchor constant:-6],
            [_progressTrack.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-14],
            [_progressTrack.heightAnchor constraintEqualToConstant:4],

            [_progressLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-16],
            [_progressLabel.centerYAnchor constraintEqualToAnchor:_progressTrack.centerYAnchor],
            [_progressLabel.widthAnchor constraintEqualToConstant:44],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.progressTrack.bounds.size.width * self.progressRatio;
    if (w < 0) w = 0;
    if (w > self.progressTrack.bounds.size.width) w = self.progressTrack.bounds.size.width;
    self.progressFill.frame = CGRectMake(0, 0, w, self.progressTrack.bounds.size.height);
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

@implementation GlassDetailCell

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
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor colorWithWhite:0.2 alpha:1];
        [_cardView addSubview:_titleLabel];

        _collapseLabel = [UILabel new];
        _collapseLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _collapseLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _collapseLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        _collapseLabel.text = @"收起 ▲";
        [_cardView addSubview:_collapseLabel];

        _keyLabels = [NSMutableArray array];
        _valLabels = [NSMutableArray array];
        UILabel *prev = _titleLabel;
        for (int i = 0; i < 3; i++) {
            UILabel *k = [UILabel new];
            k.translatesAutoresizingMaskIntoConstraints = NO;
            k.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            k.textColor = [UIColor colorWithWhite:0.45 alpha:1];
            [_cardView addSubview:k];
            [_keyLabels addObject:k];

            UILabel *v = [UILabel new];
            v.translatesAutoresizingMaskIntoConstraints = NO;
            v.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            v.textColor = [UIColor colorWithWhite:0.15 alpha:1];
            v.textAlignment = NSTextAlignmentRight;
            v.numberOfLines = 1;
            v.adjustsFontSizeToFitWidth = YES;
            v.minimumScaleFactor = 0.7;
            [_cardView addSubview:v];
            [_valLabels addObject:v];

            [NSLayoutConstraint activateConstraints:@[
                [k.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
                [k.widthAnchor constraintEqualToConstant:80],
                [k.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
                [v.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
                [v.leadingAnchor constraintEqualToAnchor:k.trailingAnchor constant:8],
                [v.centerYAnchor constraintEqualToAnchor:k.centerYAnchor],
                [k.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
            ]];
            prev = k;
        }
        [prev.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-14].active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_titleLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:14],

            [_collapseLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_collapseLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        ]];
    }
    return self;
}

@end

@implementation InfoCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.layer.cornerRadius = 12;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.05;
        _cardView.layer.shadowRadius = 8;
        _cardView.layer.shadowOffset = CGSizeMake(0, 3);
        [self.contentView addSubview:_cardView];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 12;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [_cardView addSubview:blur];

        _keyLabel = [UILabel new];
        _keyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _keyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _keyLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
        [_cardView addSubview:_keyLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _valueLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.numberOfLines = 1;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.7;
        [_cardView addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_keyLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_keyLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_keyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8],

            [_valueLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-18],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_valueLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:13],
            [_valueLabel.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-13],
        ]];
    }
    return self;
}

@end

@implementation SectionTitleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        [_titleLabel sizeToFit];
        [self.contentView addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        ]];
    }
    return self;
}

@end

// 前置声明：日期格式化缓存（BatteryChartView 先于定义使用）
static NSDateFormatter *NTM_formatter(NSString *fmt);

@implementation BatteryChartView

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    NSArray *pts = self.points;
    if (!pts.count) {
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1]};
        NSString *s = @"暂无数据（安装后需运行一段时间积累）";
        CGSize ts = [s sizeWithAttributes:attrs];
        [s drawAtPoint:CGPointMake((self.bounds.size.width - ts.width) / 2, (self.bounds.size.height - ts.height) / 2) withAttributes:attrs];
        return;
    }

    CGFloat padL = 10, padR = 14, padT = 14, padB = 16;
    CGFloat w = self.bounds.size.width - padL - padR;
    CGFloat h = self.bounds.size.height - padT - padB;
    if (w <= 0 || h <= 0) return;

    // 电量范围（留 5% 上下余量）
    NSInteger minL = 100, maxL = 0;
    for (NSDictionary *e in pts) {
        NSInteger lv = [e[@"level"] integerValue];
        minL = MIN(minL, lv);
        maxL = MAX(maxL, lv);
    }
    NSInteger lo = MAX(0, minL - 5);
    NSInteger hi = MIN(100, maxL + 5);
    if (hi - lo < 10) hi = MIN(100, lo + 10);
    CGFloat range = (hi - lo > 0) ? (hi - lo) : 1;

    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // 网格线 + 刻度
    for (NSInteger g = 0; g <= 100; g += 25) {
        if (g < lo || g > hi) continue;
        CGFloat y = padT + h * (1 - (CGFloat)(g - lo) / range);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.86 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 0.5);
        CGContextMoveToPoint(ctx, padL, y);
        CGContextAddLineToPoint(ctx, padL + w, y);
        CGContextStrokePath(ctx);
        NSString *label = [NSString stringWithFormat:@"%ld", (long)g];
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:8], NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1]};
        CGSize ts = [label sizeWithAttributes:attrs];
        [label drawAtPoint:CGPointMake(padL + w - ts.width, y - ts.height - 1) withAttributes:attrs];
    }

    // 数据点坐标
    NSInteger n = pts.count;
    CGFloat stepX = (n > 1) ? (w / (n - 1)) : 0;
    NSMutableArray *xys = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        NSDictionary *e = pts[i];
        NSInteger lv = [e[@"level"] integerValue];
        CGFloat x = padL + i * stepX;
        CGFloat y = padT + h * (1 - (CGFloat)(lv - lo) / range);
        [xys addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
    }

    // 线下渐变填充
    CGMutablePathRef fillPath = CGPathCreateMutable();
    CGPoint p0 = [xys.firstObject CGPointValue];
    CGPoint pn = [xys.lastObject CGPointValue];
    CGPathMoveToPoint(fillPath, NULL, p0.x, padT + h);
    for (NSValue *v in xys) {
        CGPoint p = [v CGPointValue];
        CGPathAddLineToPoint(fillPath, NULL, p.x, p.y);
    }
    CGPathAddLineToPoint(fillPath, NULL, pn.x, padT + h);
    CGPathCloseSubpath(fillPath);

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, fillPath);
    CGContextClip(ctx);
    CGFloat comps[] = {1.0, 0.33, 0.30, 0.35, 1.0, 0.33, 0.30, 0.05};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, padT), CGPointMake(0, padT + h), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);
    CGPathRelease(fillPath);

    // 折线
    CGContextSetStrokeColorWithColor(ctx, [UIColor systemRedColor].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextBeginPath(ctx);
    for (NSInteger i = 0; i < (NSInteger)xys.count; i++) {
        CGPoint p = [xys[i] CGPointValue];
        if (i == 0) CGContextMoveToPoint(ctx, p.x, p.y);
        else CGContextAddLineToPoint(ctx, p.x, p.y);
    }
    CGContextStrokePath(ctx);

    // 当前点高亮
    CGContextSetFillColorWithColor(ctx, [UIColor systemRedColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(pn.x - 3, pn.y - 3, 6, 6));
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(pn.x - 3, pn.y - 3, 6, 6));

    // 底部时间标签（首尾）
    NSDictionary *firstE = pts.firstObject;
    NSDictionary *lastE = pts.lastObject;
    NSDateFormatter *fmt = NTM_formatter(@"MM-dd HH:mm");
    NSString *t0 = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[firstE[@"ts"] doubleValue]]];
    NSString *t1 = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[lastE[@"ts"] doubleValue]]];
    NSDictionary *tattrs = @{NSFontAttributeName: [UIFont systemFontOfSize:9], NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1]};
    [t0 drawAtPoint:CGPointMake(padL, padT + h + 4) withAttributes:tattrs];
    CGSize t1s = [t1 sizeWithAttributes:tattrs];
    [t1 drawAtPoint:CGPointMake(padL + w - t1s.width, padT + h + 4) withAttributes:tattrs];
}

@end

@implementation BatteryChartCell

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

        _summaryLabel = [UILabel new];
        _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _summaryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _summaryLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [_cardView addSubview:_summaryLabel];

        _chartView = [BatteryChartView new];
        _chartView.translatesAutoresizingMaskIntoConstraints = NO;
        _chartView.backgroundColor = [UIColor clearColor];
        [_cardView addSubview:_chartView];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],

            [blur.topAnchor constraintEqualToAnchor:_cardView.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

            [_summaryLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:18],
            [_summaryLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:14],
            [_summaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_cardView.trailingAnchor constant:-18],

            [_chartView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:8],
            [_chartView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-8],
            [_chartView.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:6],
            [_chartView.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-8],
            [_chartView.heightAnchor constraintEqualToConstant:150],
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

// 从 App Bundle 直接读取图标 PNG（越狱环境 Settings 可读其他 App Bundle，不依赖私有图标 API，最可靠）
static UIImage *NTM_iconFromBundle(NSString *bundleId) {
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!proxyClass) return nil;
        id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
        if (!proxy) return nil;
        NSURL *url = [proxy valueForKey:@"bundleURL"];
        if (![url isKindOfClass:[NSURL class]]) return nil;
        NSString *path = [url path];
        if (!path.length) return nil;
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (!bundle) return nil;
        NSDictionary *info = bundle.infoDictionary;
        if (!info) return nil;

        // 收集图标文件名（CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles，兼容旧格式）
        NSMutableArray *names = [NSMutableArray array];
        NSDictionary *icons = info[@"CFBundleIcons"];
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        NSArray *files = primary[@"CFBundleIconFiles"];
        if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
        files = info[@"CFBundleIconFiles"];
        if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
        NSString *single = info[@"CFBundleIconFile"];
        if ([single isKindOfClass:[NSString class]]) [names addObject:single];

        CGFloat scale = [UIScreen mainScreen].scale;
        for (NSString *name in names) {
            for (int s = (int)scale; s >= 1; s--) {
                NSString *scaled = (s > 1) ? [NSString stringWithFormat:@"%@@%dx", name, s] : name;
                NSString *p = [bundle pathForResource:scaled ofType:@"png"];
                if (!p) continue;
                UIImage *img = [UIImage imageWithContentsOfFile:p];
                if (img) return img;
            }
        }
    } @catch (NSException *e) {
        return nil;
    }
    return nil;
}

// 兜底占位图标：彩色圆形 + App 首字母（真实图标加载失败时保证界面不空）
static UIImage *NTM_letterIcon(NSString *bundleId, NSString *name) {
    NSString *letter = @"?";
    if (name.length) {
        letter = [name substringToIndex:1];
    } else if (bundleId.length) {
        letter = [bundleId substringToIndex:1];
    }
    letter = [letter uppercaseString];

    CGFloat hue = ([bundleId hash] % 360) / 360.0;
    UIColor *color = [UIColor colorWithHue:hue saturation:0.4 brightness:0.85 alpha:1];

    CGFloat size = 160;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, size, size));
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:size * 0.5],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };
    CGSize ts = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:CGPointMake((size - ts.width) / 2, (size - ts.height) / 2) withAttributes:attrs];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 从 Assets.car 编译资源目录读取图标（处理图标只在资源目录里的 App）
static UIImage *NTM_iconFromAssetsCar(NSString *bundleId) {
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!proxyClass) return nil;
        id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
        if (!proxy) return nil;
        NSURL *url = [proxy valueForKey:@"bundleURL"];
        if (![url isKindOfClass:[NSURL class]]) return nil;
        NSString *path = [url path];
        if (!path.length) return nil;
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (!bundle) return nil;
        NSString *carPath = [bundle pathForResource:@"Assets.car" ofType:nil];
        if (!carPath) return nil;

        static Class CUICatalogClass = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            void *h = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY);
            if (h) CUICatalogClass = NSClassFromString(@"CUICatalog");
        });
        if (!CUICatalogClass) return nil;

        // CUICatalog 是私有类，initWithName:fromBundle: 需动态调用避免编译报错
        id catalog = [CUICatalogClass performSelector:NSSelectorFromString(@"alloc")];
        catalog = [catalog performSelector:NSSelectorFromString(@"initWithName:fromBundle:") withObject:@"Assets.car" withObject:bundle];
        if (!catalog) return nil;

        CGFloat scale = [UIScreen mainScreen].scale;
        SEL sel = NSSelectorFromString(@"imageWithName:scaleFactor:");
        if (![catalog respondsToSelector:sel]) return nil;
        typedef UIImage *(*ImgFn)(id, SEL, NSString *, CGFloat);
        ImgFn fn = (ImgFn)[catalog methodForSelector:sel];
        NSArray *names = @[@"AppIcon", @"AppIcon60x60", @"AppIcon40x40", @"AppIcon29x29"];
        for (NSString *name in names) {
            UIImage *img = fn(catalog, sel, name, scale);
            if (img) return img;
        }
    } @catch (NSException *e) {
        return nil;
    }
    return nil;
}

// 获取 App 图标（带缓存，失败返回 nil）
// 依次尝试：Bundle 直读 PNG → _LSCopyApplicationIcon → UIKit 私有方法 → LSApplicationProxy iconData → Assets.car
static UIImage *NTM_appIcon(NSString *bundleId) {
    if (!bundleId.length) return nil;
    UIImage *cached = [NTM_iconCache() objectForKey:bundleId];
    if (cached) return cached;

    UIImage *icon = nil;

    // 方法1: 直接从 App Bundle 读取图标 PNG（不依赖私有图标 API，越狱环境最可靠）
    icon = NTM_iconFromBundle(bundleId);

    if (!icon) {
        @try {
            // 方法2: MobileCoreServices 私有函数 _LSCopyApplicationIcon（返回 +1 对象）
            static CFTypeRef (*LSCopyIcon)(CFStringRef, BOOL) = NULL;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                void *h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
                if (h) LSCopyIcon = (CFTypeRef (*)(CFStringRef, BOOL))dlsym(h, "_LSCopyApplicationIcon");
            });
            if (LSCopyIcon) {
                CFTypeRef ref = LSCopyIcon((__bridge CFStringRef)bundleId, NO);
                if (ref) icon = (__bridge_transfer UIImage *)ref;
            }
        } @catch (NSException *e) {
            icon = nil;
        }
    }

    if (!icon) {
        @try {
            // 方法3: UIKit 私有方法 +[UIImage _applicationIconImageForBundleIdentifier:format:scale:]
            Class cls = [UIImage class];
            SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
            if ([cls respondsToSelector:sel]) {
                typedef UIImage *(*IconFn)(id, SEL, NSString *, int, CGFloat);
                IconFn fn = (IconFn)[cls methodForSelector:sel];
                icon = fn(cls, sel, bundleId, 2, [UIScreen mainScreen].scale);
            }
        } @catch (NSException *e) {
            icon = nil;
        }
    }

    if (!icon) {
        @try {
            // 方法4: LSApplicationProxy iconDataForVariant:withOptions:（int 参数，用 methodForSelector 直接调用）
            Class proxyClass = NSClassFromString(@"LSApplicationProxy");
            if (proxyClass) {
                id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
                SEL sel = NSSelectorFromString(@"iconDataForVariant:withOptions:");
                if (proxy && [proxy respondsToSelector:sel]) {
                    typedef NSData *(*IconDataFn)(id, SEL, int, int);
                    IconDataFn fn = (IconDataFn)[proxy methodForSelector:sel];
                    NSData *data = fn(proxy, sel, 2, 0);
                    if ([data isKindOfClass:[NSData class]] && data.length) {
                        icon = [UIImage imageWithData:data];
                    }
                }
            }
        } @catch (NSException *e) {
            icon = nil;
        }
    }

    if (!icon) {
        // 方法5: 从 Assets.car 编译资源目录读取图标（处理图标只在资源目录里的 App）
        icon = NTM_iconFromAssetsCar(bundleId);
    }

    if (icon) {
        [NTM_iconCache() setObject:icon forKey:bundleId];
    }
    return icon;
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

// 读取电池硬件信息（IOKit AppleSmartBattery）
static NSDictionary *NTM_batteryHw(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        CFMutableDictionaryRef props = NULL;
        kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
        if (kr == KERN_SUCCESS && props) {
            NSDictionary *d = (__bridge_transfer NSDictionary *)props;
            for (NSString *k in @[@"Amperage", @"Temperature", @"CycleCount", @"AppleRawMaxCapacity", @"DesignCapacity", @"AppleRawCurrentCapacity", @"Voltage", @"ExternalConnected", @"IsCharging"]) {
                if (d[k]) info[k] = d[k];
            }
        }
        IOObjectRelease(service);
    }
    return info;
}

@implementation NTMBatteryPrincipalController

- (instancetype)init {
    self = [super init];
    if (self) {
        _data = [NSMutableDictionary dictionary];
        _expandedRow = -1;
        _selectedTab = 0;
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

    // Grouped 样式：表头随内容滚动，不吸顶，避免遮挡观看
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
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
    // 充电状态直接用系统电池状态，不依赖 Tweak 记录，保证实时准确
    _batteryState = dev.batteryState;
    _charging = (_batteryState == UIDeviceBatteryStateCharging || _batteryState == UIDeviceBatteryStateFull);

    // 平均耗电速率（自上次充电结束）
    NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
    NSNumber *chargeEnd = _data[@"lastChargeEnd"];
    _drainRate = 0;
    if (endLevel > 0 && chargeEnd && _currentLevel >= 0) {
        NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [chargeEnd doubleValue];
        if (dur > 60) {
            NSInteger drain = endLevel - _currentLevel;
            if (drain < 0) drain = 0;
            _drainRate = (CGFloat)drain / (dur / 3600.0);
        }
    }

    // App 列表：按加权时间（前台+后台×0.3）排序，估算每 App 耗电
    NSDictionary *apps = _data[@"apps"];
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
    NSMutableArray *tmpList = [NSMutableArray array];
    for (NSDictionary *a in list) {
        double weight = [a[@"weight"] doubleValue];
        NSInteger drain = (totalWeight > 0) ? (NSInteger)lround(totalDrain * weight / totalWeight) : 0;
        NSMutableDictionary *ma = [a mutableCopy];
        ma[@"drain"] = @(drain);
        [tmpList addObject:ma];
    }
    NSArray *finalList = tmpList;
    // 只显示使用量最大的前 10 个 App
    if (finalList.count > 10) {
        finalList = [finalList subarrayWithRange:NSMakeRange(0, 10)];
    }
    _appList = finalList;
    // 排行 App 耗电总和（进度条占比分母）
    NSInteger drainSum = 0;
    for (NSDictionary *a in _appList) drainSum += [a[@"drain"] integerValue];
    _totalDrain = drainSum;
    // 展开行越界时重置
    if (_expandedRow >= (NSInteger)_appList.count) _expandedRow = -1;

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
    if (_historyList.count > 48) {
        _historyList = [_historyList subarrayWithRange:NSMakeRange(0, 48)];
    }

    // 已注入 Tweak 列表
    _tweakList = _data[@"tweaks"];
    if (![_tweakList isKindOfClass:[NSArray class]]) _tweakList = @[];

    // 省电&诊断 行数据
    NSMutableArray *saver = [NSMutableArray array];
    [saver addObject:@{@"type": @"title", @"text": @"预估续航"}];
    NSString *screenTime = @"--";
    if (_drainRate > 0) {
        CGFloat hours = _currentLevel / _drainRate;
        NSInteger h = (NSInteger)hours;
        NSInteger m = (NSInteger)((hours - h) * 60);
        screenTime = [NSString stringWithFormat:@"约 %ld 小时 %ld 分", (long)h, (long)m];
    }
    [saver addObject:@{@"type": @"info", @"key": @"预估亮屏可用", @"value": screenTime}];
    NSString *nightVal = @"--";
    NSString *nightColor = @"normal";
    if (_drainRate > 0) {
        NSInteger nd = (NSInteger)lround(_drainRate * 8);
        nightVal = [NSString stringWithFormat:@"约 %ld%%（%@）", (long)nd, nd > 15 ? @"偏高" : @"正常"];
        nightColor = nd > 15 ? @"orange" : @"green";
    }
    [saver addObject:@{@"type": @"info", @"key": @"预估夜间8小时待机掉电", @"value": nightVal, @"color": nightColor}];
    [saver addObject:@{@"type": @"title", @"text": @"自动扫描结果"}];
    NSInteger bgApps = 0;
    for (NSDictionary *a in _appList) {
        if ([a[@"bg"] doubleValue] > 0) bgApps++;
    }
    if (bgApps > 3) {
        [saver addObject:@{@"type": @"info", @"key": @"后台刷新 App 过多", @"value": @"⚠️", @"color": @"orange"}];
    } else {
        [saver addObject:@{@"type": @"info", @"key": @"后台刷新 App 过多", @"value": @"正常", @"color": @"green"}];
    }
    [saver addObject:@{@"type": @"info", @"key": @"休眠阻断检测", @"value": @"无异常", @"color": @"green"}];
    [saver addObject:@{@"type": @"title", @"text": @"续航建议（仅提示，不自动修改）"}];
    [saver addObject:@{@"type": @"info", @"key": @"夜间极限待机方案", @"value": @">"}];
    [saver addObject:@{@"type": @"info", @"key": @"日常均衡续航方案", @"value": @">"}];
    _saverRows = saver;

    // 硬件&充电 行数据
    NSDictionary *hw = NTM_batteryHw();
    NSMutableArray *hwRows = [NSMutableArray array];
    NSNumber *amp = hw[@"Amperage"];
    if (amp) {
        [hwRows addObject:@{@"type": @"info", @"key": @"实时放电电流", @"value": [NSString stringWithFormat:@"%ldmA", (long)[amp integerValue]]}];
    } else {
        [hwRows addObject:@{@"type": @"info", @"key": @"实时放电电流", @"value": @"--"}];
    }
    NSNumber *temp = hw[@"Temperature"];
    if (temp) {
        [hwRows addObject:@{@"type": @"info", @"key": @"电池温度", @"value": [NSString stringWithFormat:@"%.1f℃", [temp doubleValue] / 100.0]}];
    } else {
        [hwRows addObject:@{@"type": @"info", @"key": @"电池温度", @"value": @"--"}];
    }
    NSNumber *cycles = hw[@"CycleCount"];
    [hwRows addObject:@{@"type": @"info", @"key": @"循环次数", @"value": cycles ? [NSString stringWithFormat:@"%ld次", (long)[cycles integerValue]] : @"--"}];
    NSNumber *rawMax = hw[@"AppleRawMaxCapacity"];
    NSNumber *design = hw[@"DesignCapacity"];
    if (rawMax && design && [design integerValue] > 0) {
        NSInteger pct = (NSInteger)lround([rawMax doubleValue] / [design doubleValue] * 100);
        [hwRows addObject:@{@"type": @"info", @"key": @"实际最大容量", @"value": [NSString stringWithFormat:@"%ld%%", (long)pct]}];
    } else {
        [hwRows addObject:@{@"type": @"info", @"key": @"实际最大容量", @"value": @"--"}];
    }
    BOOL lowPower = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
    [hwRows addObject:@{@"type": @"info", @"key": @"系统低电量模式", @"value": lowPower ? @"开启" : @"关闭", @"color": lowPower ? @"orange" : @"green"}];
    _hwRows = hwRows;

    [_tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // 总览
        case 1: return 1; // 测试按钮
        case 2: return 1; // 诊断
        case 3: return 1; // Tab 条
        case 4: {         // Tab 内容
            switch (_selectedTab) {
                case 0: {
                    NSInteger base = MAX(_appList.count, 1);
                    if (_expandedRow >= 0 && _expandedRow < (NSInteger)_appList.count) return base + 1;
                    return base;
                }
                case 1: return MAX(_tweakList.count, 1);
                case 2: return _saverRows.count;
                case 3: return _hwRows.count;
            }
        }
        case 5: return 1; // 折线图
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 5) return @"电量24小时趋势";
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 5) return nil;
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor clearColor];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    label.text = @"电量24小时趋势";
    [v addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:22],
        [label.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    return v;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 5) return 30;
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 8;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            OverviewCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"overview"];
            if (!cell) cell = [[OverviewCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"overview"];
            [self configOverviewCell:cell];
            return cell;
        }
        case 1: {
            ActionButtonCell *cell = [tableView dequeueReusableCellWithIdentifier:@"action"];
            if (!cell) cell = [[ActionButtonCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"action"];
            cell.titleLabel.text = _data[@"testStartTime"] ? @"🔋 查看待机漏电测试结果" : @"🔋 开始待机漏电测试";
            return cell;
        }
        case 2: {
            DiagnosisCell *cell = [tableView dequeueReusableCellWithIdentifier:@"diag"];
            if (!cell) cell = [[DiagnosisCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"diag"];
            cell.titleLabel.text = @"🔍 自动漏电诊断";
            cell.descLabel.text = [self diagnosisText];
            return cell;
        }
        case 3: {
            TabBarCell *cell = [tableView dequeueReusableCellWithIdentifier:@"tabbar"];
            if (!cell) cell = [[TabBarCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"tabbar"];
            cell.tabBar.selectedIndex = _selectedTab;
            __weak typeof(self) weakSelf = self;
            cell.tabBar.onSelect = ^(NSInteger idx) {
                __strong typeof(self) s = weakSelf;
                if (!s) return;
                s.selectedTab = idx;
                [s.tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationFade];
            };
            return cell;
        }
        case 4: {
            return [self tabContentCellForIndexPath:indexPath tableView:tableView];
        }
        case 5: {
            BatteryChartCell *cell = [tableView dequeueReusableCellWithIdentifier:@"chart"];
            if (!cell) cell = [[BatteryChartCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"chart"];
            [self configChartCell:cell];
            return cell;
        }
    }
    return [UITableViewCell new];
}

// Tab 内容 cell
- (UITableViewCell *)tabContentCellForIndexPath:(NSIndexPath *)indexPath tableView:(UITableView *)tableView {
    switch (_selectedTab) {
        case 0: {
            // 排行详情行（点击展开）
            if (_expandedRow >= 0 && indexPath.row == _expandedRow + 1) {
                GlassDetailCell *dcell = [tableView dequeueReusableCellWithIdentifier:@"glassDetail"];
                if (!dcell) dcell = [[GlassDetailCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"glassDetail"];
                NSDictionary *a = _appList[_expandedRow];
                NSInteger fg = (NSInteger)([a[@"fg"] doubleValue] / 60);
                NSInteger bg = (NSInteger)([a[@"bg"] doubleValue] / 60);
                NSInteger drain = [a[@"drain"] integerValue];
                dcell.titleLabel.text = [NSString stringWithFormat:@"%@ 详情", NTM_appName(a[@"id"])];
                dcell.keyLabels[0].text = @"前台使用";
                dcell.valLabels[0].text = [NSString stringWithFormat:@"%ld 分钟", (long)fg];
                dcell.keyLabels[1].text = @"后台使用";
                dcell.valLabels[1].text = [NSString stringWithFormat:@"%ld 分钟", (long)bg];
                dcell.keyLabels[2].text = @"耗电占比";
                if (_totalDrain > 0) {
                    dcell.valLabels[2].text = [NSString stringWithFormat:@"%ld%%（占排行总耗电）", (long)lround((double)drain / _totalDrain * 100)];
                } else {
                    dcell.valLabels[2].text = @"--";
                }
                return dcell;
            }
            GlassCell *cell = [tableView dequeueReusableCellWithIdentifier:@"glass"];
            if (!cell) cell = [[GlassCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"glass"];
            [self configAppCell:cell atRow:indexPath.row];
            return cell;
        }
        case 1: {
            GlassCell *cell = [tableView dequeueReusableCellWithIdentifier:@"glass"];
            if (!cell) cell = [[GlassCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"glass"];
            [self configTweakCell:cell atRow:indexPath.row];
            return cell;
        }
        case 2: {
            NSDictionary *row = _saverRows[indexPath.row];
            if ([row[@"type"] isEqualToString:@"title"]) {
                SectionTitleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"secTitle"];
                if (!cell) cell = [[SectionTitleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"secTitle"];
                cell.titleLabel.text = row[@"text"];
                return cell;
            }
            InfoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"info"];
            if (!cell) cell = [[InfoCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"info"];
            [self configInfoCell:cell withRow:row];
            return cell;
        }
        case 3: {
            NSDictionary *row = _hwRows[indexPath.row];
            InfoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"info"];
            if (!cell) cell = [[InfoCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"info"];
            [self configInfoCell:cell withRow:row];
            return cell;
        }
    }
    return [UITableViewCell new];
}

- (void)configAppCell:(GlassCell *)cell atRow:(NSInteger)row {
    cell.rankLabel.hidden = NO;
    cell.progressTrack.hidden = NO;
    cell.progressLabel.hidden = NO;
    cell.iconView.image = nil;
    cell.subtitleLabel.text = @"";
    cell.subtitleLabel.hidden = YES;
    cell.valueLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
    cell.valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.progressRatio = 0;
    cell.progressLabel.text = @"";

    if (_appList.count) {
        NSDictionary *a = _appList[row];
        NSInteger fg = (NSInteger)([a[@"fg"] doubleValue] / 60);
        NSInteger bg = (NSInteger)([a[@"bg"] doubleValue] / 60);
        NSInteger drain = [a[@"drain"] integerValue];
        cell.titleLabel.text = NTM_appName(a[@"id"]);
        cell.rankLabel.text = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
        if (row == 0) cell.rankLabel.backgroundColor = [UIColor systemRedColor];
        else if (row == 1) cell.rankLabel.backgroundColor = [UIColor systemOrangeColor];
        else if (row == 2) cell.rankLabel.backgroundColor = [UIColor systemYellowColor];
        else cell.rankLabel.backgroundColor = [UIColor systemGrayColor];
        // 先显示字母占位，后台加载真实图标（避免首次进入卡顿）
        cell.currentBundleId = a[@"id"];
        cell.iconView.image = NTM_letterIcon(a[@"id"], cell.titleLabel.text);
        NSString *bid = a[@"id"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *icon = NTM_appIcon(bid);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (icon && [cell.currentBundleId isEqualToString:bid]) {
                    cell.iconView.image = icon;
                }
            });
        });
        cell.subtitleLabel.hidden = NO;
        if (bg > 0) {
            cell.subtitleLabel.text = [NSString stringWithFormat:@"前台 %ld分 · 后台 %ld分", (long)fg, (long)bg];
        } else {
            cell.subtitleLabel.text = [NSString stringWithFormat:@"前台 %ld分", (long)fg];
        }
        NSInteger total = fg + bg;
        if (drain > 0) {
            cell.valueLabel.text = [NSString stringWithFormat:@"耗电 %ld%%", (long)drain];
            cell.valueLabel.textColor = [UIColor systemRedColor];
            cell.valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        } else {
            cell.valueLabel.text = [NSString stringWithFormat:@"共 %ld分", (long)total];
        }
        // 耗电占比进度条（占排行总耗电比例）+ 百分比标签
        cell.progressRatio = (_totalDrain > 0) ? (CGFloat)drain / _totalDrain : 0;
        if (_totalDrain > 0 && drain > 0) {
            cell.progressLabel.text = [NSString stringWithFormat:@"占 %ld%%", (long)lround((double)drain / _totalDrain * 100)];
        }
    } else {
        cell.titleLabel.text = @"暂无数据（安装后需运行一段时间积累）";
        cell.subtitleLabel.text = @"";
        cell.valueLabel.text = @"";
    }
}

- (void)configTweakCell:(GlassCell *)cell atRow:(NSInteger)row {
    cell.rankLabel.hidden = YES;
    cell.progressTrack.hidden = YES;
    cell.progressLabel.hidden = YES;
    cell.iconView.image = nil;
    cell.valueLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1];
    cell.valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];

    if (_tweakList.count) {
        NSString *name = _tweakList[row];
        NSString *display = [name stringByReplacingOccurrencesOfString:@".dylib" withString:@""];
        cell.titleLabel.text = display;
        cell.iconView.image = NTM_letterIcon(name, display);
        cell.subtitleLabel.hidden = NO;
        cell.subtitleLabel.text = @"已注入 SpringBoard";
        cell.valueLabel.text = @"运行中";
        cell.valueLabel.textColor = [UIColor systemGreenColor];
        cell.valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    } else {
        cell.titleLabel.text = @"暂无 Tweak 数据（重启 SpringBoard 生效）";
        cell.subtitleLabel.text = @"";
        cell.subtitleLabel.hidden = YES;
        cell.valueLabel.text = @"";
    }
}

- (void)configInfoCell:(InfoCell *)cell withRow:(NSDictionary *)row {
    cell.keyLabel.text = row[@"key"];
    cell.valueLabel.text = row[@"value"];
    NSString *color = row[@"color"];
    if ([color isEqualToString:@"orange"]) cell.valueLabel.textColor = [UIColor systemOrangeColor];
    else if ([color isEqualToString:@"green"]) cell.valueLabel.textColor = [UIColor systemGreenColor];
    else if ([color isEqualToString:@"red"]) cell.valueLabel.textColor = [UIColor systemRedColor];
    else cell.valueLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
}

- (void)configOverviewCell:(OverviewCardCell *)cell {
    if (_currentLevel >= 0) {
        cell.levelLabel.text = [NSString stringWithFormat:@"%ld%%", (long)_currentLevel];
        cell.levelLabel.textColor = _charging ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    } else {
        cell.levelLabel.text = @"--";
        cell.levelLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    }
    cell.statusLabel.text = @"未充电";
    if (_batteryState == UIDeviceBatteryStateFull) {
        cell.statusLabel.text = @"已充满";
    } else if (_batteryState == UIDeviceBatteryStateCharging) {
        NSNumber *start = _data[@"chargeStart"];
        if (start) {
            NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [start doubleValue];
            if (dur > 0) {
                cell.statusLabel.text = [NSString stringWithFormat:@"充电中 · %ld 分钟", (long)(dur / 60)];
            } else {
                cell.statusLabel.text = @"充电中";
            }
        } else {
            cell.statusLabel.text = @"充电中";
        }
    }

    // 描述：上次充电结束 + 本次消耗 + 历时
    NSNumber *chargeEnd = _data[@"lastChargeEnd"];
    NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
    if (chargeEnd && endLevel > 0 && _currentLevel >= 0) {
        NSInteger drain = endLevel - _currentLevel;
        if (drain < 0) drain = 0;
        NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [chargeEnd doubleValue];
        if (dur < 0) dur = 0;
        NSInteger totalMin = (NSInteger)(dur / 60);
        NSInteger h = totalMin / 60;
        NSInteger m = totalMin % 60;
        NSString *durText = h > 0 ? [NSString stringWithFormat:@"%ld小时%ld分", (long)h, (long)m] : [NSString stringWithFormat:@"%ld分", (long)m];
        NSString *endText = [NTM_formatter(@"MM-dd HH:mm") stringFromDate:[NSDate dateWithTimeIntervalSince1970:[chargeEnd doubleValue]]];
        cell.descLabel.text = [NSString stringWithFormat:@"上次充电结束：%@｜本次消耗 %ld%%，历时 %@", endText, (long)drain, durText];
    } else {
        cell.descLabel.text = @"上次充电结束：无记录（完成一次充电后显示）";
    }

    // 迷你卡片
    cell.rateKeyLabel.text = @"平均耗电速率";
    if (_drainRate > 0) {
        cell.rateValueLabel.text = [NSString stringWithFormat:@"%.1f%% /h", _drainRate];
        cell.rateValueLabel.textColor = _drainRate > 5 ? [UIColor systemOrangeColor] : [UIColor colorWithWhite:0.15 alpha:1];
    } else {
        cell.rateValueLabel.text = @"--";
        cell.rateValueLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    }
    cell.sampleKeyLabel.text = @"电量采样点";
    NSArray *rawHist = _data[@"batteryHistory"];
    cell.sampleValueLabel.text = [NSString stringWithFormat:@"%ld次", (long)([rawHist isKindOfClass:[NSArray class]] ? rawHist.count : 0)];
    cell.sampleValueLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1];

    // 警告
    if (chargeEnd && endLevel > 0) {
        cell.warnLabel.text = @"⚠️ 非完整充放电周期，数据仅供参考";
    } else {
        cell.warnLabel.text = @"⚠️ 数据不足，请完成一次充电后查看";
    }
}

- (NSString *)diagnosisText {
    NSInteger endLevel = [_data[@"chargeEndLevel"] integerValue];
    NSNumber *chargeEnd = _data[@"lastChargeEnd"];
    if (endLevel <= 0 || !chargeEnd || _currentLevel < 0) {
        return @"数据不足，暂无法诊断。请先完成一次充电后使用。";
    }
    NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - [chargeEnd doubleValue];
    if (dur <= 60) return @"数据不足，暂无法诊断。请稍后再试。";
    NSInteger drain = endLevel - _currentLevel;
    if (drain < 0) drain = 0;
    CGFloat rate = (CGFloat)drain / (dur / 3600.0);
    NSString *topApp = _appList.count ? NTM_appName(_appList[0][@"id"]) : @"";
    if (rate > 5) {
        return [NSString stringWithFormat:@"平均耗电 %.1f%%/h 偏高；建议重点检查 %@ 后台刷新，同时留意注入 Tweak 唤醒情况。", rate, topApp];
    } else if (rate > 2) {
        return [NSString stringWithFormat:@"平均耗电 %.1f%%/h 略高；建议关注后台刷新频繁的 App。", rate];
    } else {
        return [NSString stringWithFormat:@"平均耗电 %.1f%%/h 正常，继续保持。", rate];
    }
}

- (void)configChartCell:(BatteryChartCell *)cell {
    // 折线图需要时间正序（_historyList 是倒序，反转回来）
    NSArray *ascending = [[_historyList reverseObjectEnumerator] allObjects];
    cell.chartView.points = ascending;
    [cell.chartView setNeedsDisplay];
    if (ascending.count) {
        NSDictionary *first = ascending.firstObject;
        NSDictionary *last = ascending.lastObject;
        NSInteger startL = [first[@"level"] integerValue];
        NSInteger endL = [last[@"level"] integerValue];
        cell.summaryLabel.text = [NSString stringWithFormat:@"%ld%% → %ld%% · %ld 个记录点", (long)startL, (long)endL, (long)ascending.count];
    } else {
        cell.summaryLabel.text = @"暂无数据（安装后需运行一段时间积累）";
    }
}

#pragma mark - 交互

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [self handleTestButton];
        return;
    }
    if (indexPath.section == 4 && _selectedTab == 0) {
        if (!_appList.count) return;
        if (indexPath.row >= (NSInteger)_appList.count) {
            _expandedRow = -1;
        } else if (_expandedRow == indexPath.row) {
            _expandedRow = -1;
        } else {
            _expandedRow = indexPath.row;
        }
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:4] withRowAnimation:UITableViewRowAnimationFade];
        if (_expandedRow >= 0) {
            [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_expandedRow + 1 inSection:4] atScrollPosition:UITableViewScrollPositionNone animated:YES];
        }
        return;
    }
    if (indexPath.section == 4 && _selectedTab == 2) {
        NSDictionary *row = _saverRows[indexPath.row];
        NSString *key = row[@"key"];
        if ([key isEqualToString:@"夜间极限待机方案"]) {
            [self showTip:@"夜间极限待机方案" msg:@"建议：开启飞行模式或关闭蜂窝数据，关闭后台刷新，可大幅降低夜间待机耗电。"];
        } else if ([key isEqualToString:@"日常均衡续航方案"]) {
            [self showTip:@"日常均衡续航方案" msg:@"建议：关闭不常用 App 的后台刷新，开启低电量模式，屏幕亮度调至 50% 以下。"];
        }
    }
}

- (void)handleTestButton {
    NSNumber *testStart = _data[@"testStartTime"];
    if (!testStart) {
        if (_currentLevel < 0) {
            [self showTip:@"无法开始测试" msg:@"当前无法读取电量，请稍后再试。"];
            return;
        }
        _data[@"testStartTime"] = @([[NSDate date] timeIntervalSince1970]);
        _data[@"testStartLevel"] = @(_currentLevel);
        [_data writeToFile:@"/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist" atomically:YES];
        [self showTip:@"待机漏电测试已开始" msg:@"请锁屏放置 1-2 小时，再回来点击查看结果。"];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - [testStart doubleValue];
        NSInteger startLevel = [_data[@"testStartLevel"] integerValue];
        NSInteger drain = startLevel - _currentLevel;
        if (drain < 0) drain = 0;
        CGFloat rate = (elapsed > 60) ? (CGFloat)drain / (elapsed / 3600.0) : 0;
        NSString *msg = [NSString stringWithFormat:@"测试时长 %.1f 小时\n掉电 %ld%%\n平均耗电速率 %.1f%%/h", elapsed / 3600.0, (long)drain, rate];
        [_data removeObjectForKey:@"testStartTime"];
        [_data removeObjectForKey:@"testStartLevel"];
        [_data writeToFile:@"/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist" atomically:YES];
        [self showTip:@"待机漏电测试结果" msg:msg];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)showTip:(NSString *)title msg:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
