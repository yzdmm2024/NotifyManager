#import "CarCheckFloatingView.h"
#import "VehicleDatabase.h"

@interface CarCheckFloatingView () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UIButton *dragBtn;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint panelOrigin;
@end

@implementation CarCheckFloatingView

static CarCheckFloatingView *sShared = nil;

+ (instancetype)sharedView {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sShared = [[self alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = 300, h = 220;
    CGFloat x = (screen.size.width - w) / 2;
    CGFloat y = 120;
    self = [super initWithFrame:screen];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 100;
        self.hidden = YES;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        // 半透明背景遮罩
        UIView *bg = [[UIView alloc] initWithFrame:screen];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
        bg.userInteractionEnabled = YES;
        [bg addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBgTap:)]];
        [self addSubview:bg];

        // 面板
        _panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
        _panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
        _panel.layer.cornerRadius = 16;
        _panel.layer.shadowColor = [UIColor blackColor].CGColor;
        _panel.layer.shadowOffset = CGSizeMake(0, 4);
        _panel.layer.shadowOpacity = 0.4;
        _panel.layer.shadowRadius = 12;
        _panel.clipsToBounds = NO;
        _panel.userInteractionEnabled = YES;
        [self addSubview:_panel];

        // 拖动按钮（标题栏）
        _dragBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _dragBtn.frame = CGRectMake(0, 0, w, 40);
        _dragBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        _dragBtn.layer.cornerRadius = 16;
        _dragBtn.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        _dragBtn.userInteractionEnabled = YES;
        [_dragBtn setTitle:@"OpenPilot 车型查询" forState:UIControlStateNormal];
        [_dragBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _dragBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_dragBtn addTarget:self action:@selector(dragPan:) forControlEvents:UIControlEventTouchDragInside];
        [_dragBtn addTarget:self action:@selector(dragPan:) forControlEvents:UIControlEventTouchDragOutside];
        [_dragBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
        [_panel addSubview:_dragBtn];

        // 关闭按钮
        _closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _closeBtn.frame = CGRectMake(w - 36, 4, 32, 32);
        _closeBtn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
        _closeBtn.layer.cornerRadius = 16;
        [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [_closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_closeBtn addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_closeBtn];

        // 输入框
        _inputField = [[UITextField alloc] initWithFrame:CGRectMake(16, 52, w - 32, 38)];
        _inputField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
        _inputField.textColor = [UIColor whiteColor];
        _inputField.font = [UIFont systemFontOfSize:15];
        _inputField.placeholder = @"输入车型，如: Civic 2022";
        _inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入车型，如: Civic 2022" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1]}];
        _inputField.layer.cornerRadius = 8;
        _inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 0)];
        _inputField.leftViewMode = UITextFieldViewModeAlways;
        _inputField.returnKeyType = UIReturnKeySearch;
        _inputField.delegate = self;
        _inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
        [_panel addSubview:_inputField];

        // 搜索按钮
        UIButton *searchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        searchBtn.frame = CGRectMake(w - 16 - 70, 52, 70, 38);
        [searchBtn setTitle:@"查询" forState:UIControlStateNormal];
        [searchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        searchBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1];
        searchBtn.layer.cornerRadius = 8;
        searchBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [searchBtn addTarget:self action:@selector(search) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:searchBtn];

        // 调整输入框宽度（给搜索按钮让位）
        CGRect tf = _inputField.frame;
        tf.size.width = w - 32 - 78;
        _inputField.frame = tf;

        // 结果标签
        _resultLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, w - 32, 100)];
        _resultLabel.textColor = [UIColor whiteColor];
        _resultLabel.font = [UIFont systemFontOfSize:14];
        _resultLabel.numberOfLines = 0;
        _resultLabel.textAlignment = NSTextAlignmentCenter;
        _resultLabel.text = @"输入车型名称，点击查询";
        _resultLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        [_panel addSubview:_resultLabel];
    }
    return self;
}

#pragma mark - Actions

- (void)search {
    [self.inputField resignFirstResponder];
    NSString *query = [self.inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        self.resultLabel.text = @"请输入车型名称";
        self.resultLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        return;
    }

    // 搜索匹配
    NSString *lower = [query lowercaseString];
    NSMutableArray *matches = [NSMutableArray array];

    for (int i = 0; i < VEHICLE_COUNT; i++) {
        NSString *brand = [NSString stringWithUTF8String:kSupportedVehicles[i].brand];
        NSString *model = [NSString stringWithUTF8String:kSupportedVehicles[i].model];
        NSString *full = [NSString stringWithFormat:@"%@ %@", brand, model];
        NSString *fullLower = [full lowercaseString];

        // 检查是否包含查询关键词
        if ([fullLower containsString:lower]) {
            [matches addObject:full];
        }
    }

    // 也搜索品牌别名（中文品牌名）
    if (matches.count == 0) {
        int j = 0;
        while (kBrandAliases[j][0] != NULL) {
            NSString *alias = [NSString stringWithUTF8String:kBrandAliases[j][0]];
            NSString *engBrand = [NSString stringWithUTF8String:kBrandAliases[j][1]];
            if ([[alias lowercaseString] containsString:lower] ||
                [[engBrand lowercaseString] containsString:lower]) {
                // 找到品牌别名，搜索该品牌所有车型
                for (int i = 0; i < VEHICLE_COUNT; i++) {
                    NSString *brand = [NSString stringWithUTF8String:kSupportedVehicles[i].brand];
                    if ([[brand lowercaseString] isEqualToString:[engBrand lowercaseString]]) {
                        NSString *model = [NSString stringWithUTF8String:kSupportedVehicles[i].model];
                        [matches addObject:[NSString stringWithFormat:@"%@ %@", brand, model]];
                    }
                }
                break;
            }
            j++;
        }
    }

    // 显示结果
    if (matches.count > 0) {
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"✅ 支持\n\n" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1], NSFontAttributeName: [UIFont boldSystemFontOfSize:16]}]];

        for (NSString *match in matches) {
            [attr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"• %@\n", match] attributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:13]}]];
        }

        self.resultLabel.attributedText = attr;
    } else {
        self.resultLabel.text = [NSString stringWithFormat:@"❌ 不支持\n\n「%@」不在 OpenPilot 支持列表中", query];
        self.resultLabel.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    }
}

- (void)handleBgTap:(UITapGestureRecognizer *)gr {
    [self.inputField resignFirstResponder];
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint pt = [gr translationInView:self];
    CGPoint center = self.panel.center;
    center.x += pt.x;
    center.y += pt.y;
    self.panel.center = center;
    [gr setTranslation:CGPointZero inView:self];

    // 边界约束
    if (gr.state == UIGestureRecognizerStateEnded) {
        CGRect f = self.panel.frame;
        CGRect sb = [UIScreen mainScreen].bounds;
        f.origin.x = MAX(10, MIN(f.origin.x, sb.size.width - f.size.width - 10));
        f.origin.y = MAX(40, MIN(f.origin.y, sb.size.height - f.size.height - 40));
        [UIView animateWithDuration:0.2 animations:^{
            self.panel.frame = f;
        }];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self search];
    return YES;
}

#pragma mark - Show / Hide

- (void)show {
    self.hidden = NO;
    self.panel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    self.panel.alpha = 0;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.panel.transform = CGAffineTransformIdentity;
        self.panel.alpha = 1;
    } completion:nil];
    [self.inputField becomeFirstResponder];
}

- (void)hide {
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.transform = CGAffineTransformMakeScale(0.85, 0.85);
        self.panel.alpha = 0;
    } completion:^(BOOL f) {
        self.hidden = YES;
        self.panel.transform = CGAffineTransformIdentity;
        self.panel.alpha = 1;
    }];
}

@end