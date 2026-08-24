#import "CarCheckFloatingView.h"

// 手势触发辅助类
@interface _CarCheckTrigger : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)gr;
@end

@implementation _CarCheckTrigger
+ (instancetype)shared {
    static _CarCheckTrigger *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}
- (void)handleTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateRecognized) {
        [[CarCheckFloatingView sharedView] show];
    }
}
@end

%hook UIApplication

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // 延迟等窗口就绪后再添加手势
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWin = nil;
        if (@available(iOS 13, *)) {
            NSSet *scenes = [[UIApplication sharedApplication] valueForKey:@"connectedScenes"];
            for (UIScene *scene in scenes) {
                if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")] &&
                    scene.activationState == UISceneActivationStateForegroundActive) {
                    id delegate = [scene valueForKey:@"delegate"];
                    if ([delegate respondsToSelector:@selector(window)]) {
                        keyWin = [delegate valueForKey:@"window"];
                    }
                    break;
                }
            }
        }
        if (!keyWin) {
            keyWin = [[UIApplication sharedApplication] keyWindow];
        }
        if (keyWin) {
            UITapGestureRecognizer *tap5 = [[UITapGestureRecognizer alloc]
                initWithTarget:[_CarCheckTrigger shared] action:@selector(handleTap:)];
            tap5.numberOfTapsRequired = 5;
            tap5.numberOfTouchesRequired = 1;
            [keyWin addGestureRecognizer:tap5];
        }
    });
}

%end

%ctor {
    // 预初始化浮窗，确保后续 show 时 UI 已就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [CarCheckFloatingView sharedView];
    });
}