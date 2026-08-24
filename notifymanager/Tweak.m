// Tweak.m — 注入 SpringBoard，hook 通知展示 (iOS 16.6)
// 总开关: NCNotificationDispatcher -postNotificationWithRequest:
// 横幅:   SBDashBoardNotificationPresenter -presentModalBannerAndExpandForNotificationRequest:
// 声音:   SBNCSoundController -canPlaySoundForNotificationRequest:
// 角标:   SBApplication -setBadgeValue:
// 列表:   NCNotificationStructuredListViewController / NCNotificationCombinedListViewController -insertNotificationRequest...
// 设置面板通过 NSUserDefaults suiteName 通信
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

static BOOL NTM_isDimEnabled(NSString *appId, NSString *dim) {
    if (!appId.length) return YES;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    if (!prefs) return YES;
    id val = [prefs objectForKey:[NSString stringWithFormat:@"NTM_%@_%@", dim, appId]];
    return val ? [val boolValue] : YES;
}

// 子维度是否应拦截：总开关关闭 → 全部拦截；否则按该维度开关
static BOOL NTM_shouldBlock(NSString *appId, NSString *dim) {
    if (!NTM_isDimEnabled(appId, @"en")) return YES;
    return !NTM_isDimEnabled(appId, dim);
}

static NSString *NTM_sectionOf(id request) {
    if (!request) return nil;
    NSString *sectionId = nil;
    @try {
        sectionId = [request performSelector:@selector(sectionIdentifier)];
    } @catch(NSException *e) {}
    return sectionId;
}

#pragma mark - Hook NCNotificationDispatcher (总开关)
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && !NTM_isDimEnabled(sectionId, @"en")) {
        return; // 总开关关闭 → 拦截整个通知
    }
    if (orig_postRequest)
        orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"banner")) {
        return; // 拦截横幅
    }
    if (orig_presentBanner)
        orig_presentBanner(self, _cmd, request);
}

#pragma mark - Hook SBNCSoundController (声音)
static BOOL (*orig_canPlaySound)(id, SEL, id);
static BOOL hook_canPlaySound(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"sound")) {
        return NO; // 拦截声音
    }
    return orig_canPlaySound ? orig_canPlaySound(self, _cmd, request) : YES;
}

#pragma mark - Hook SBApplication (角标)
static void (*orig_setBadgeValue)(id, SEL, id);
static void hook_setBadgeValue(id self, SEL _cmd, id value) {
    NSString *bundleId = nil;
    @try {
        bundleId = [self performSelector:@selector(bundleIdentifier)];
    } @catch(NSException *e) {}
    if (bundleId.length && NTM_shouldBlock(bundleId, @"badge")) {
        return; // 拦截角标更新
    }
    if (orig_setBadgeValue)
        orig_setBadgeValue(self, _cmd, value);
}

#pragma mark - Hook 通知列表插入 (锁屏/通知中心)
// iOS 16 锁屏与通知中心共用同一列表，任一关闭即不展示在列表中
static BOOL (*orig_insertRequest)(id, SEL, id);
static BOOL hook_insertRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc"))) {
        return YES; // 拦截列表插入
    }
    return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
}

static BOOL (*orig_insertRequestCoalesced)(id, SEL, id, id);
static BOOL hook_insertRequestCoalesced(id self, SEL _cmd, id request, id coalesce) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc"))) {
        return YES; // 拦截列表插入
    }
    return orig_insertRequestCoalesced ? orig_insertRequestCoalesced(self, _cmd, request, coalesce) : YES;
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
        // 总开关
        tryHook(objc_getClass("NCNotificationDispatcher"),
                sel_registerName("postNotificationWithRequest:"),
                (IMP)hook_postRequest, (IMP *)&orig_postRequest);

        // 横幅
        tryHook(objc_getClass("SBDashBoardNotificationPresenter"),
                sel_registerName("presentModalBannerAndExpandForNotificationRequest:"),
                (IMP)hook_presentBanner, (IMP *)&orig_presentBanner);

        // 声音
        tryHook(objc_getClass("SBNCSoundController"),
                sel_registerName("canPlaySoundForNotificationRequest:"),
                (IMP)hook_canPlaySound, (IMP *)&orig_canPlaySound);

        // 角标
        tryHook(objc_getClass("SBApplication"),
                sel_registerName("setBadgeValue:"),
                (IMP)hook_setBadgeValue, (IMP *)&orig_setBadgeValue);

        // 列表 (锁屏/通知中心)
        tryHook(objc_getClass("NCNotificationStructuredListViewController"),
                sel_registerName("insertNotificationRequest:"),
                (IMP)hook_insertRequest, (IMP *)&orig_insertRequest);

        tryHook(objc_getClass("NCNotificationCombinedListViewController"),
                sel_registerName("insertNotificationRequest:forCoalescedNotification:"),
                (IMP)hook_insertRequestCoalesced, (IMP *)&orig_insertRequestCoalesced);
    }
}
