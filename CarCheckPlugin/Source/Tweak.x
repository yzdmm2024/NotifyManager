#import "CarCheckFloatingView.h"

%ctor {
    // 延迟初始化浮窗，等待 UI 就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [CarCheckFloatingView sharedView];
    });
}