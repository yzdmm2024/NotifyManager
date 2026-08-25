// Tweak.m — 电池耗电监控（注入 SpringBoard）
// 每 5 秒采样一次：记录当前前台 App 运行时间 + 电量变化
// 数据存到 /var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist
// 设置面板（BatteryPanel.bundle）读取同一份数据展示
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

// 当前前台 App 的 bundle id（私有 API）
static NSString *NTM_frontApp(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSString *bundleId = [app valueForKey:@"_accessibilityFrontMostApplication"];
    if (![bundleId isKindOfClass:[NSString class]] || !bundleId.length) return nil;
    return bundleId;
}

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

    NSString *front = NTM_frontApp();
    NSInteger level = NTM_batteryLevel();

    // 累计前台 App 运行时间
    if (g_lastApp && dt > 0) {
        NSMutableDictionary *apps = data[@"apps"];
        if (!apps) { apps = [NSMutableDictionary dictionary]; data[@"apps"] = apps; }
        NSMutableDictionary *info = apps[g_lastApp];
        if (!info) { info = [NSMutableDictionary dictionary]; apps[g_lastApp] = info; }
        info[@"foreground"] = @([info[@"foreground"] doubleValue] + dt);
        info[@"lastSeen"] = @(now);
    }
    g_lastApp = front;

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

__attribute__((constructor))
static void NTM_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_timer = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
            NTM_tick();
        }];
        [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
        NTM_tick();
    });
}
