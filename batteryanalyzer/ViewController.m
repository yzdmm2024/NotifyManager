#import "ViewController.h"
#import "BatteryData.h"

// 玻璃拟态卡片 cell：半透明白色模糊背景 + 大圆角 + 微弱外阴影 + 按压缩放
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

        // 玻璃模糊背景（磨砂半透明）
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

// 按压缩放交互
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

@interface ViewController ()
@property (nonatomic, strong) BatteryData *data;
@end

@implementation ViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"电池耗电分析";
    _data = [BatteryData shared];
    [_data loadData];

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
    self.tableView.backgroundView = bg;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(4, 0, 20, 0);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;

    // 导航栏透明，透出渐变背景
    self.navigationController.navigationBar.translucent = YES;
    [self.navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    self.navigationController.navigationBar.shadowImage = [UIImage new];
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.15 alpha:1],
        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
    };

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    self.navigationItem.rightBarButtonItem = refresh;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.backgroundView.frame = self.view.bounds;
    CAGradientLayer *g = (CAGradientLayer *)self.tableView.backgroundView.layer.sublayers.firstObject;
    g.frame = self.view.bounds;
}

- (void)refresh {
    [_data loadData];
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 5;
    if (section == 1) return MAX(_data.hourlyUsages.count, 1);
    if (section == 2) return MAX(_data.appUsages.count, 1);
    if (section == 3) return MAX(_data.selfHistory.count, 1);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"电池总览";
        case 1: return @"每小时运行 App 数（最近 24 小时）";
        case 2: return @"App 耗电排行（前台/后台时间）";
        case 3: return @"自记录电量历史";
        default: return @"说明";
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
        if (_data.hourlyUsages.count) {
            HourlyUsage *h = _data.hourlyUsages[indexPath.row];
            cell.titleLabel.text = h.label;
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld 个 App", (long)h.appCount];
        } else {
            cell.titleLabel.text = @"暂无数据";
            cell.valueLabel.text = @"";
        }
    } else if (indexPath.section == 2) {
        if (_data.appUsages.count) {
            AppUsage *u = _data.appUsages[indexPath.row];
            cell.titleLabel.text = u.appName;
            NSInteger fg = (NSInteger)(u.screenOnTime / 60);
            NSInteger bg = (NSInteger)(u.backgroundTime / 60);
            cell.valueLabel.text = [NSString stringWithFormat:@"前台 %ld分 · 后台 %ld分", (long)fg, (long)bg];
        } else {
            cell.titleLabel.text = @"暂无数据";
            cell.valueLabel.text = @"";
        }
    } else if (indexPath.section == 3) {
        if (_data.selfHistory.count) {
            NSDictionary *e = _data.selfHistory[indexPath.row];
            NSDate *ts = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"MM-dd HH:mm";
            cell.titleLabel.text = [df stringFromDate:ts];
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)[e[@"level"] integerValue]];
        } else {
            cell.titleLabel.text = @"暂无记录";
            cell.valueLabel.text = @"";
        }
    } else {
        cell.titleLabel.text = @"数据来自系统 Powerlog 数据库（/var/mobile/Library/Logs/CrashReporter/Powerlog_*.PLSQL）。\n"
                              @"若设备上未找到 Powerlog 数据库，则显示实时电量、电池健康与自记录历史。\n"
                              @"每 App 耗电与每小时 App 数依赖 Powerlog，设备上无此数据库时无法获取。\n"
                              @"电池健康需要系统生成分析文件（iOS 16 为 Analytics-*.ips）：设置→隐私与安全性→分析与改进→开启「共享 iPhone 分析」，等待 24 小时后重新打开本 App。\n"
                              @"右上角刷新按钮可重新读取最新数据。";
        cell.titleLabel.numberOfLines = 0;
        cell.titleLabel.font = [UIFont systemFontOfSize:13];
        cell.titleLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        cell.valueLabel.text = @"";
    }
    return cell;
}

- (void)configOverviewCell:(GlassCell *)cell row:(NSInteger)row {
    if (_data.errorMessage) {
        cell.titleLabel.text = _data.errorMessage;
        cell.titleLabel.numberOfLines = 0;
        cell.titleLabel.font = [UIFont systemFontOfSize:13];
        cell.titleLabel.textColor = [UIColor systemRedColor];
        cell.valueLabel.text = @"";
        return;
    }
    cell.titleLabel.numberOfLines = 1;
    switch (row) {
        case 0: {
            cell.titleLabel.text = @"当前电量";
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)_data.currentLevel];
            break;
        }
        case 1: {
            cell.titleLabel.text = @"电池健康";
            if (_data.cycleCount > 0) {
                NSInteger health = 0;
                if (_data.designCapacity > 0) {
                    health = (NSInteger)lround((double)_data.maxCapacity / _data.designCapacity * 100);
                }
                cell.valueLabel.text = [NSString stringWithFormat:@"%ld 次 · %ld%%",
                                        (long)_data.cycleCount, (long)health];
            } else {
                cell.valueLabel.text = @"暂无数据";
                cell.titleLabel.text = @"电池健康（未找到 Analytics 文件）";
            }
            break;
        }
        case 2: {
            cell.titleLabel.text = @"上次充电结束";
            if (_data.lastChargeEnd) {
                NSDateFormatter *df = [NSDateFormatter new];
                df.dateFormat = @"MM-dd HH:mm";
                cell.valueLabel.text = [df stringFromDate:_data.lastChargeEnd];
            } else {
                cell.valueLabel.text = @"无记录";
            }
            break;
        }
        case 3: {
            cell.titleLabel.text = @"本次耗电";
            NSInteger drain = _data.chargeEndLevel - _data.currentLevel;
            if (drain < 0) drain = 0;
            cell.valueLabel.text = [NSString stringWithFormat:@"%ld%% → %ld%%（消耗 %ld%%）",
                                    (long)_data.chargeEndLevel, (long)_data.currentLevel, (long)drain];
            break;
        }
        case 4: {
            cell.titleLabel.text = @"本次时长";
            if (_data.lastChargeEnd) {
                NSTimeInterval dur = [[NSDate date] timeIntervalSinceDate:_data.lastChargeEnd];
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
