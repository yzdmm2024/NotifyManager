// Tweak.m — 注入 SpringBoard，hook SBNotificationPresenter 拦截通知展示
// 读取 PreferenceBundle 保存的配置，控制通知放行/拦截
#import <substrate.h>
#import <Foundation/Foundation.h>

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

#pragma mark - 读取配置
static BOOL NTM_isEnabled(NSString *appId) {
    if (!appId.length) return YES;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    if (!prefs) return YES;
    id val = [prefs objectForKey:[NSString stringWithFormat:@"NTM_en_%@", appId]];
    return val ? [val boolValue] : YES;
}

static BOOL NTM_subEnabled(NSString *appId, NSString *dim) {
    if (!appId.length) return YES;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    if (!prefs) return YES;
    id val = [prefs objectForKey:[NSString stringWithFormat:@"NTM_%@_%@", dim, appId]];
    return val ? [val boolValue] : YES;
}

#pragma mark - Hook SBNotificationPresenter: 通知即将展示
static void (*orig_present)(id, SEL, id, id);
static void hook_present(id self, SEL _cmd, id notification, id dest) {
    NSString *bid = nil;
    @try { bid = [notification performSelector:@selector(bundleIdentifier)]; } @catch(NSException *e) {}
    if (bid.length && !NTM_isEnabled(bid)) {
        // 总开关关闭 → 彻底拦截
        return;
    }
    orig_present(self, _cmd, notification, dest);
}

// 可选: 区分锁屏/通知中心/横幅需要 hook 更细粒度的类
// 但第一版先做总开关拦截，三个子开关后续加

#pragma mark - 构造器
__attribute__((constructor)) static void init() {
    @autoreleasepool {
        // 尝试 hook SBNotificationPresenter
        Class cls = objc_getClass("SBNotificationPresenter");
        if (cls) {
            MSHookMessageEx(cls,
                @selector(presentNotification:forDestination:),
                (IMP)hook_present,
                (IMP *)&orig_present);
        }
        // 可选: 也 hook NCNotificationPresenter / NCNotificationDestinations
    }
}