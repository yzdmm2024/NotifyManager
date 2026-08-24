#import "CarCheckFloatingView.h"

%hook UIApplication

- (void)applicationDidBecomeActive:(id)application {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // App 完全就绪后才创建浮窗，避免卡死
        dispatch_async(dispatch_get_main_queue(), ^{
            [CarCheckFloatingView sharedView];
        });
    });
}

%end