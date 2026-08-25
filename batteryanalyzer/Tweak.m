// Tweak.m — 电池耗电监控（注入 SpringBoard）
// hook SBApplicationController 的 appProcessStateDidChange: 获取前台 App（FBApplicationProcess）
// 定时器每 5 秒累计前台/后台时间 + 电量变化
// 数据存到 /var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *NTM_plistPath(void) {
    return @"/var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist";
}

static NSMutableDictionary *NTM_load(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:NTM_plistPath()];
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

static void NTM_save(NSDictionary *d) {
    [d writeToFile:NTM_plistPath() atomically:YES];
}

// hook 记录的前台 app（bundle id），nil 表示当前无前台 app（主屏幕/锁屏）
static NSString *g_frontApp = nil;

// 获取当前电量
static NSInteger NTM_batteryLevel(void) {
    UIDevice *dev = [UIDevice currentDevice];
    dev.batteryMonitoringEnabled = YES;
    float level = dev.batteryLevel;
    if (level < 0) return -1;
    return (NSInteger)(level * 100 + 0.5);
}

static NSTimer *g_timer = nil;
static NSString *g_lastApp = nil;
static NSTimeInterval g_lastTick = 0;

static void NTM_tick(void) {
    NSMutableDictionary *data = NTM_load();
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval dt = (g_lastTick > 0) ? (now - g_lastTick) : 5.0;
    g_lastTick = now;
    if (dt <= 0 || dt > 60) dt = 5.0;

    NSString *front = g_frontApp;
    NSInteger level = NTM_batteryLevel();

    // 累计前台/后台时间：前台 app 累计 foreground，离开前台后累计 background
    if (g_lastApp) {
        NSMutableDictionary *apps = data[@"apps"];
        if (!apps) { apps = [NSMutableDictionary dictionary]; data[@"apps"] = apps; }
        NSMutableDictionary *info = apps[g_lastApp];
        if (!info) { info = [NSMutableDictionary dictionary]; apps[g_lastApp] = info; }
        if (front && [front isEqualToString:g_lastApp]) {
            info[@"foreground"] = @([info[@"foreground"] doubleValue] + dt);
        } else {
            info[@"background"] = @([info[@"background"] doubleValue] + dt);
        }
        info[@"lastSeen"] = @(now);
    }
    if (front) g_lastApp = front;

    // 电量历史：只在电量值变化时记录（相同电量不重复）
    NSMutableArray *hist = data[@"batteryHistory"];
    if (!hist) { hist = [NSMutableArray array]; data[@"batteryHistory"] = hist; }
    NSInteger prevLevel = [data[@"lastLevel"] integerValue];
    if (level >= 0 && level != prevLevel) {
        [hist addObject:@{@"ts": @(now), @"level": @(level)}];
        if (hist.count > 1440) {
            [hist removeObjectsInRange:NSMakeRange(0, hist.count - 1440)];
        }
    }

    // 充电检测：电量上升 = 充电中；由充转放 = 充电结束
    BOOL prevCharging = [data[@"charging"] boolValue];
    BOOL charging = (level > prevLevel) || (level == 100);
    if (charging && !prevCharging) {
        data[@"chargeStart"] = @(now);
    }
    if (!charging && prevCharging && prevLevel > 0) {
        data[@"lastChargeEnd"] = @(now);
        data[@"chargeEndLevel"] = @(prevLevel);
    }
    data[@"charging"] = @(charging);
    data[@"lastLevel"] = @(level);
    data[@"lastUpdate"] = @(now);

    NTM_save(data);
}

// hook SBMainWorkspace process:stateDidChangeFromState:toState:
// arg1: FBApplicationProcess（bundleIdentifier），arg3: FBProcessState（visibility: Foreground/Background）
static void (*orig_processStateDidChange)(id, SEL, id, id, id);
static void hook_processStateDidChange(id self, SEL _cmd, id process, id fromState, id toState) {
    orig_processStateDidChange(self, _cmd, process, fromState, toState);
    NSString *bundleId = [process valueForKey:@"bundleIdentifier"];
    if (![bundleId isKindOfClass:[NSString class]] || !bundleId.length) return;
    NSString *visibility = [toState valueForKey:@"visibility"];
    if ([visibility isEqualToString:@"Foreground"]) {
        g_frontApp = bundleId;
    } else if ([visibility isEqualToString:@"Background"]) {
        if ([g_frontApp isEqualToString:bundleId]) {
            g_frontApp = nil;
        }
    }
}

__attribute__((constructor))
static void NTM_init(void) {
    Class cls = NSClassFromString(@"SBMainWorkspace");
    SEL sel = NSSelectorFromString(@"process:stateDidChangeFromState:toState:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        orig_processStateDidChange = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_processStateDidChange);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        g_timer = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
            NTM_tick();
        }];
        [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
        NTM_tick();
    });
}
