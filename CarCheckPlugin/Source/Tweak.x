#import "CarCheckFloatingView.h"

%ctor {
    // 直接在 %ctor 中注册通知，等待 App 激活后再创建浮窗
    // 不要用 %hook UIApplication，因为 applicationDidBecomeActive: 是 delegate 方法
    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果 App 已经激活，直接创建
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                [CarCheckFloatingView sharedView];
            });
        } else {
            // 等待激活通知
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    [CarCheckFloatingView sharedView];
                });
            }];
        }
    });
}