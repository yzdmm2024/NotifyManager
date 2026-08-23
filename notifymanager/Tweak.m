// Tweak.m — 注入 SpringBoard，hook 通知展示 (iOS 16.6 正确类名)
// Hook NCNotificationDispatcher -postNotificationWithRequest: 拦截通知分发
// 设置面板通过 NSUserDefaults suiteName 通信
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

static BOOL NTM_isEnabled(NSString *appId) {
    if (!appId.length) return YES;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    if (!prefs) return YES;
    id val = [prefs objectForKey:[NSString stringWithFormat:@"NTM_en_%@", appId]];
    return val ? [val boolValue] : YES;
}

#pragma mark - Hook NCNotificationDispatcher
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = nil;
    @try {
        sectionId = [request performSelector:@selector(sectionIdentifier)];
    } @catch(NSException *e) {}
    if (sectionId.length && !NTM_isEnabled(sectionId)) {
        return; // 拦截通知
    }
    if (orig_postRequest)
        orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅备份)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    NSString *sectionId = nil;
    @try {
        sectionId = [request performSelector:@selector(sectionIdentifier)];
    } @catch(NSException *e) {}
    if (sectionId.length && !NTM_isEnabled(sectionId)) {
        return; // 拦截横幅
    }
    if (orig_presentBanner)
        orig_presentBanner(self, _cmd, request);
}

static void tryHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        // 主拦截: NCNotificationDispatcher -postNotificationWithRequest:
        tryHook(objc_getClass("NCNotificationDispatcher"),
                sel_registerName("postNotificationWithRequest:"),
                (IMP)hook_postRequest, (IMP *)&orig_postRequest);

        // 备用: SBDashBoardNotificationPresenter -presentModalBannerAndExpandForNotificationRequest:
        tryHook(objc_getClass("SBDashBoardNotificationPresenter"),
                sel_registerName("presentModalBannerAndExpandForNotificationRequest:"),
                (IMP)hook_presentBanner, (IMP *)&orig_presentBanner);
    }
}