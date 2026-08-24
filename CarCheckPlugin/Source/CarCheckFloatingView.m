#import "CarCheckFloatingView.h"
#import "VehicleDatabase.h"

@interface CarCheckFloatingView () <UITextFieldDelegate>
// 悬浮按钮
@property (nonatomic, strong) UIView *floatBtn;
@property (nonatomic, assign) BOOL isDraggingBtn;
@property (nonatomic, assign) CGPoint btnDragStart;
// 面板
@property (nonatomic, strong) UIView *bgMask;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) CGFloat panelScale;
// 面板拖动
@property (nonatomic, assign) CGPoint panelDragOffset;
// 面板缩放
@property (nonatomic, assign) CGFloat lastPinchScale;
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
    self = [super initWithFrame:screen];
    if (self) {
        // 关联 windowScene（iOS 13+ 必需，否则咸鱼等 App 会卡死）
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) {
                    self.windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        self.windowLevel = 2100; // 替代 UIWindowLevelAlert + 100
        self.hidden = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.panelScale = 1.0;

        [self setupFloatButton];
        [self setupPanel];
    }
    return self;
}

#pragma mark - 悬浮按钮

- (void)setupFloatButton {
    CGFloat size = 48;
    CGFloat y = [UIScreen mainScreen].bounds.size.height * 0.4;
    // 用 UIView 替代 UIButton，避免 UIControl 与手势冲突
    _floatBtn = [[UIView alloc] initWithFrame:CGRectMake(0, y, size, size)];
    _floatBtn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.75];
    _floatBtn.layer.cornerRadius = size / 2;
    _floatBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatBtn.layer.shadowOffset = CGSizeMake(0, 2);
    _floatBtn.layer.shadowOpacity = 0.3;
    _floatBtn.layer.shadowRadius = 6;
    _floatBtn.alpha = 0.35;
    _floatBtn.userInteractionEnabled = YES;
    // 用 UILabel 显示 emoji（UIButton 的 title 在某些 App 中可能不渲染）
    UILabel *emoji = [[UILabel alloc] initWithFrame:_floatBtn.bounds];
    emoji.text = @"🚗";
    emoji.font = [UIFont systemFontOfSize:20];
    emoji.textAlignment = NSTextAlignmentCenter;
    emoji.userInteractionEnabled = NO;
    [_floatBtn addSubview:emoji];
    // 点击手势（不依赖 UIControlEvent）
    UITapGestureRecognizer *tapGR = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(floatBtnTapped)];
    tapGR.numberOfTapsRequired = 1;
    [_floatBtn addGestureRecognizer:tapGR];
    // 拖动手势
    UIPanGestureRecognizer *panGR = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFloatPan:)];
    panGR.cancelsTouchesInView = NO;
    panGR.delaysTouchesBegan = NO;
    panGR.delaysTouchesEnded = NO;
    [_floatBtn addGestureRecognizer:panGR];
    [self performSelector:@selector(fadeFloatBtn) withObject:nil afterDelay:2.0];
    [self addSubview:_floatBtn];
}

- (void)fadeFloatBtn {
    if (!_panelVisible) {
        [UIView animateWithDuration:0.5 animations:^{
            self.floatBtn.alpha = 0.25;
        }];
    }
}

- (void)wakeFloatBtn {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeFloatBtn) object:nil];
    self.floatBtn.alpha = 0.85;
    [self performSelector:@selector(fadeFloatBtn) withObject:nil afterDelay:3.0];
}

- (void)floatBtnTapped {
    self.isDraggingBtn = NO;
    [self show];
}

- (void)handleFloatPan:(UIPanGestureRecognizer *)gr {
    [self wakeFloatBtn];
    CGPoint pt = [gr locationInView:self];
    
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.isDraggingBtn = NO;
        self.btnDragStart = pt;
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = pt.x - self.btnDragStart.x;
        CGFloat dy = pt.y - self.btnDragStart.y;
        if (fabs(dx) > 8 || fabs(dy) > 8) {
            self.isDraggingBtn = YES;
        }
        CGPoint center = self.floatBtn.center;
        center.x += dx;
        center.y += dy;
        self.floatBtn.center = center;
        self.btnDragStart = pt;
    } else if (gr.state == UIGestureRecognizerStateEnded) {
        // 吸附到最近边缘
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat midX = self.floatBtn.center.x;
        CGFloat targetX = (midX < sb.size.width / 2) ? (self.floatBtn.frame.size.width / 2 - 4) : (sb.size.width - self.floatBtn.frame.size.width / 2 + 4);
        CGFloat targetY = MAX(self.floatBtn.frame.size.height / 2 + 30,
                              MIN(self.floatBtn.center.y,
                                  sb.size.height - self.floatBtn.frame.size.height / 2 - 30));
        
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.floatBtn.center = CGPointMake(targetX, targetY);
        } completion:nil];
    }
}

#pragma mark - 面板

- (void)setupPanel {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = 300, h = 230;
    CGFloat x = (screen.size.width - w) / 2;
    CGFloat y = 100;

    // 遮罩
    _bgMask = [[UIView alloc] initWithFrame:screen];
    _bgMask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    _bgMask.userInteractionEnabled = YES;
    _bgMask.hidden = YES;
    [_bgMask addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBgTap:)]];
    [self addSubview:_bgMask];

    // 面板
    _panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    _panel.layer.cornerRadius = 16;
    _panel.layer.shadowColor = [UIColor blackColor].CGColor;
    _panel.layer.shadowOffset = CGSizeMake(0, 4);
    _panel.layer.shadowOpacity = 0.4;
    _panel.layer.shadowRadius = 12;
    _panel.clipsToBounds = YES;
    _panel.userInteractionEnabled = YES;
    _panel.hidden = YES;
    [self addSubview:_panel];

    // 面板全区域拖动手势
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    [_panel addGestureRecognizer:panelPan];

    // 双指缩放手势
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [_panel addGestureRecognizer:pinch];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 36)];
    title.text = @"OpenPilot 车型查询";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textAlignment = NSTextAlignmentCenter;
    title.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    [_panel addSubview:title];

    // 拖动指示条
    UIView *dragBar = [[UIView alloc] initWithFrame:CGRectMake((w - 36) / 2, 30, 36, 4)];
    dragBar.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.5];
    dragBar.layer.cornerRadius = 2;
    [_panel addSubview:dragBar];

    // 关闭按钮
    _closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeBtn.frame = CGRectMake(w - 34, 2, 32, 32);
    _closeBtn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    _closeBtn.layer.cornerRadius = 16;
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_closeBtn addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_closeBtn];

    // 输入框容器
    UIView *inputRow = [[UIView alloc] initWithFrame:CGRectMake(12, 44, w - 24, 38)];
    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, inputRow.frame.size.width - 78, 38)];
    _inputField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    _inputField.textColor = [UIColor whiteColor];
    _inputField.font = [UIFont systemFontOfSize:14];
    _inputField.placeholder = @"输入车型，如: Civic 2022";
    _inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入车型，如: Civic 2022" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1]}];
    _inputField.layer.cornerRadius = 8;
    _inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 0)];
    _inputField.leftViewMode = UITextFieldViewModeAlways;
    _inputField.returnKeyType = UIReturnKeySearch;
    _inputField.delegate = self;
    _inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [inputRow addSubview:_inputField];

    UIButton *searchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    searchBtn.frame = CGRectMake(inputRow.frame.size.width - 74, 0, 74, 38);
    [searchBtn setTitle:@"查询" forState:UIControlStateNormal];
    [searchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    searchBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1];
    searchBtn.layer.cornerRadius = 8;
    searchBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [searchBtn addTarget:self action:@selector(search) forControlEvents:UIControlEventTouchUpInside];
    [inputRow addSubview:searchBtn];
    [_panel addSubview:inputRow];

    // 结果标签
    _resultLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 92, w - 24, h - 104)];
    _resultLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    _resultLabel.font = [UIFont systemFontOfSize:13];
    _resultLabel.numberOfLines = 0;
    _resultLabel.textAlignment = NSTextAlignmentCenter;
    _resultLabel.text = @"输入车型名称，点击查询";
    [_panel addSubview:_resultLabel];
}

#pragma mark - 面板拖动

- (void)handlePanelPan:(UIPanGestureRecognizer *)gr {
    CGPoint pt = [gr translationInView:self];
    CGPoint center = self.panel.center;
    center.x += pt.x;
    center.y += pt.y;
    self.panel.center = center;
    [gr setTranslation:CGPointZero inView:self];

    if (gr.state == UIGestureRecognizerStateEnded) {
        CGRect sb = [UIScreen mainScreen].bounds;
        CGRect f = self.panel.frame;
        f.origin.x = MAX(10, MIN(f.origin.x, sb.size.width - f.size.width - 10));
        f.origin.y = MAX(40, MIN(f.origin.y, sb.size.height - f.size.height - 40));
        [UIView animateWithDuration:0.2 animations:^{
            self.panel.frame = f;
        }];
    }
}

#pragma mark - 双指缩放

- (void)handlePinch:(UIPinchGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.lastPinchScale = self.panelScale;
    }
    CGFloat newScale = self.lastPinchScale * gr.scale;
    newScale = MAX(0.6, MIN(newScale, 1.5));
    self.panelScale = newScale;
    self.panel.transform = CGAffineTransformMakeScale(newScale, newScale);
}

#pragma mark - 搜索

- (void)search {
    [self.inputField resignFirstResponder];
    NSString *query = [self.inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        self.resultLabel.text = @"请输入车型名称";
        self.resultLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        return;
    }

    NSString *lower = [query lowercaseString];
    NSMutableArray *matches = [NSMutableArray array];

    for (int i = 0; i < VEHICLE_COUNT; i++) {
        NSString *brand = [NSString stringWithUTF8String:kSupportedVehicles[i].brand];
        NSString *model = [NSString stringWithUTF8String:kSupportedVehicles[i].model];
        NSString *full = [NSString stringWithFormat:@"%@ %@", brand, model];
        if ([[full lowercaseString] containsString:lower]) {
            [matches addObject:full];
        }
    }

    if (matches.count == 0) {
        int j = 0;
        while (kBrandAliases[j][0] != NULL) {
            NSString *alias = [NSString stringWithUTF8String:kBrandAliases[j][0]];
            NSString *engBrand = [NSString stringWithUTF8String:kBrandAliases[j][1]];
            if ([[alias lowercaseString] containsString:lower] ||
                [[engBrand lowercaseString] containsString:lower]) {
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

    if (matches.count > 0) {
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"✅ 支持\n\n" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1], NSFontAttributeName: [UIFont boldSystemFontOfSize:15]}]];
        for (NSString *match in matches) {
            [attr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"• %@\n", match] attributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:12]}]];
        }
        self.resultLabel.attributedText = attr;
    } else {
        NSString *msg = [NSString stringWithFormat:@"❌ 不支持\n\n「%@」\n不在 OpenPilot 支持列表中", query];
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:msg];
        [attr addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1] range:NSMakeRange(0, msg.length)];
        [attr addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:15] range:NSMakeRange(0, 4)];
        [attr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:13] range:NSMakeRange(4, msg.length - 4)];
        self.resultLabel.attributedText = attr;
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self search];
    return YES;
}

- (void)handleBgTap:(UITapGestureRecognizer *)gr {
    [self.inputField resignFirstResponder];
}

#pragma mark - Show / Hide

- (void)show {
    // 取消可能残留的 hide 动画
    [self.panel.layer removeAllAnimations];
    [self.bgMask.layer removeAllAnimations];
    [self wakeFloatBtn];
    self.panelVisible = YES;
    self.panel.hidden = NO;
    self.bgMask.hidden = NO;
    self.floatBtn.hidden = YES;
    self.panel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    self.panel.alpha = 0;
    self.bgMask.alpha = 0;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.panel.transform = CGAffineTransformMakeScale(self.panelScale, self.panelScale);
        self.panel.alpha = 1;
        self.bgMask.alpha = 1;
    } completion:nil];
    [self.inputField becomeFirstResponder];
}

- (void)hide {
    self.panelVisible = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.transform = CGAffineTransformMakeScale(0.85, 0.85);
        self.panel.alpha = 0;
        self.bgMask.alpha = 0;
    } completion:^(BOOL f) {
        self.panel.hidden = YES;
        self.bgMask.hidden = YES;
        self.floatBtn.hidden = NO;
        self.panel.transform = CGAffineTransformMakeScale(self.panelScale, self.panelScale);
        self.panel.alpha = 1;
        [self performSelector:@selector(fadeFloatBtn) withObject:nil afterDelay:2.0];
    }];
    [self.inputField resignFirstResponder];
}

#pragma mark - 触摸穿透（核心修复：面板隐藏时不拦截触摸）

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.panelVisible) {
        // 面板隐藏时：只响应悬浮按钮，其他触摸穿透到下方 App
        CGPoint btnPoint = [self convertPoint:point toView:self.floatBtn];
        if (CGRectContainsPoint(self.floatBtn.bounds, btnPoint)) {
            return self.floatBtn;
        }
        return nil; // 放行触摸，让下方 App 正常响应
    }
    // 面板显示时：正常响应
    return [super hitTest:point withEvent:event];
}

@end