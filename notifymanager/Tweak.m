// Tweak.m — 注入 SpringBoard，hook 通知展示
// 使用 Objective-C runtime API 直接 swizzle，无需 CydiaSubstrate
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

#pragma mark - 读取配置
static BOOL NTM_isEnabled(NSString *appId) {
    if (!appId.length) return YES;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    if (!prefs) return YES;
    id val = [prefs objectForKey:[NSString stringWithFormat:@"NTM_en_%@", appId]];
    return val ? [val boolValue] : YES;
}

#pragma mark - Hook 函数
// SBNotificationPresenter -presentNotification:forDestination:
static void (*orig_present)(id, SEL, id, id);
static void hook_present(id self, SEL _cmd, id notification, id dest) {
    NSString *bid = nil;
    @try {
        // NCNotification 的 bundleIdentifier 属性
        bid = [notification performSelector:@selector(bundleIdentifier)];
    } @catch(NSException *e) {}
    if (bid.length && !NTM_isEnabled(bid)) {
        // 总开关关闭 → 拦截通知，不展示
        return;
    }
    if (orig_present)
        orig_present(self, _cmd, notification, dest);
}

// 尝试 hook 多个类/方法，兼容不同 iOS 版本
static void tryHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        SEL sel = sel_registerName("presentNotification:forDestination:");

        // 优先尝试 SBNotificationPresenter (iOS 16)
        tryHook(objc_getClass("SBNotificationPresenter"),
                sel, (IMP)hook_present, (IMP *)&orig_present);

        // 如果没 hook 到，尝试 NCNotificationPresenter
        if (!orig_present) {
            tryHook(objc_getClass("NCNotificationPresenter"),
                    sel, (IMP)hook_present, (IMP *)&orig_present);
        }
    }
}