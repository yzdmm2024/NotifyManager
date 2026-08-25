#import "ViewController.h"
#import "BatteryData.h"

@interface ViewController ()
@property (nonatomic, strong) BatteryData *data;
@end

@implementation ViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"电池耗电分析";
    _data = [BatteryData shared];
    [_data loadData];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    self.navigationItem.rightBarButtonItem = refresh;
}

- (void)refresh {
    [_data loadData];
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return _data.hourlyUsages.count;
    if (section == 2) return _data.appUsages.count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"电池总览";
        case 1: return @"每小时运行 App 数（最近 24 小时）";
        case 2: return @"App 耗电排行（前台/后台时间）";
        default: return @"说明";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15];

    if (indexPath.section == 0) {
        [self configOverviewCell:cell row:indexPath.row];
    } else if (indexPath.section == 1) {
        HourlyUsage *h = _data.hourlyUsages[indexPath.row];
        cell.textLabel.text = h.label;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 个 App", (long)h.appCount];
    } else if (indexPath.section == 2) {
        AppUsage *u = _data.appUsages[indexPath.row];
        cell.textLabel.text = u.appName;
        NSInteger fg = (NSInteger)(u.screenOnTime / 60);
        NSInteger bg = (NSInteger)(u.backgroundTime / 60);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"前台 %ld分 · 后台 %ld分", (long)fg, (long)bg];
    } else {
        cell.textLabel.text = @"数据来自系统 Powerlog 数据库（/var/mobile/Library/Logs/CrashReporter/Powerlog_*.PLSQL）。\n"
                              @"耗电排行按前台+后台运行时间估算，实际耗电以系统「设置→电池」为准。\n"
                              @"右上角刷新按钮可重新读取最新数据。";
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
    }
    return cell;
}

- (void)configOverviewCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (_data.errorMessage) {
        cell.textLabel.text = _data.errorMessage;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.detailTextLabel.text = nil;
        return;
    }
    switch (row) {
        case 0: {
            cell.textLabel.text = @"当前电量";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%%", (long)_data.currentLevel];
            break;
        }
        case 1: {
            cell.textLabel.text = @"上次充电结束";
            if (_data.lastChargeEnd) {
                NSDateFormatter *df = [NSDateFormatter new];
                df.dateFormat = @"MM-dd HH:mm";
                cell.detailTextLabel.text = [df stringFromDate:_data.lastChargeEnd];
            } else {
                cell.detailTextLabel.text = @"无记录";
            }
            break;
        }
        case 2: {
            cell.textLabel.text = @"本次耗电";
            NSInteger drain = _data.chargeEndLevel - _data.currentLevel;
            if (drain < 0) drain = 0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%% → %ld%%（消耗 %ld%%）",
                                         (long)_data.chargeEndLevel, (long)_data.currentLevel, (long)drain];
            break;
        }
        case 3: {
            cell.textLabel.text = @"本次时长";
            if (_data.lastChargeEnd) {
                NSTimeInterval dur = [[NSDate date] timeIntervalSinceDate:_data.lastChargeEnd];
                if (dur < 0) dur = 0;
                NSInteger h = (NSInteger)(dur / 3600);
                NSInteger m = (NSInteger)((NSInteger)dur % 3600) / 60;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)h, (long)m];
            } else {
                cell.detailTextLabel.text = @"无记录";
            }
            break;
        }
    }
}

@end
