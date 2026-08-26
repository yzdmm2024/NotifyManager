// Tweak.m — 电池耗电监控（注入 SpringBoard）
// 每 5 秒轮询前台 App（SBApplicationController isFrontmost），累计前台/后台时间 + 电量变化
// 数据存到 /var/mobile/Library/Preferences/com.ntm.batteryanalyzer.plist
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <unistd.h>
#import <notify.h>

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

// 获取当前前台 App 的 bundle id（主屏幕/锁屏返回 nil）
static NSString *NTM_frontmostApp(void) {
    @try {
        // 方法1：遍历 SBApplicationController 所有 App，找 isFrontmost == YES
        Class cls = NSClassFromString(@"SBApplicationController");
        if (cls) {
            id ctrl = [cls performSelector:@selector(sharedInstance)];
            if (ctrl && [ctrl respondsToSelector:@selector(applications)]) {
                NSArray *apps = [ctrl performSelector:@selector(applications)];
                SEL frontSel = NSSelectorFromString(@"isFrontmost");
                for (id app in apps) {
                    if (![app respondsToSelector:frontSel]) continue;
                    BOOL front = ((BOOL (*)(id, SEL))objc_msgSend)(app, frontSel);
                    if (front) {
                        NSString *bid = [app valueForKey:@"bundleIdentifier"];
                        if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
                    }
                }
            }
        }
        // 方法2：UIApplication 私有接口直接取前台 App
        id frontApp = [[UIApplication sharedApplication] performSelector:@selector(_accessibilityFrontMostApplication)];
        if (frontApp) {
            NSString *bid = [frontApp valueForKey:@"bundleIdentifier"];
            if ([bid isKindOfClass:[NSString class]] && bid.length &&
                ![bid isEqualToString:@"com.apple.springboard"]) return bid;
        }
    } @catch (NSException *e) {
    }
    return nil;
}

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

static void NTM_pruneApps(NSMutableDictionary *data);
static void NTM_executeCommand(NSDictionary *cmd);

// 只执行 30 秒内的新命令，防止重启后执行残留旧命令（避免意外开关飞行模式）
static BOOL NTM_commandIsFresh(NSDictionary *cmd) {
    NSNumber *at = cmd[@"at"];
    if (![at isKindOfClass:[NSNumber class]]) return NO;
    return ([[NSDate date] timeIntervalSince1970] - [at doubleValue]) < 30;
}

static void NTM_tick(void) {
    @try {
    NSMutableDictionary *data = NTM_load();
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval dt = (g_lastTick > 0) ? (now - g_lastTick) : 5.0;
    g_lastTick = now;
    if (dt <= 0 || dt > 60) dt = 5.0;

    // 兜底执行面板发来的续航方案命令（通知丢失时也能在 5 秒内执行）
    NSDictionary *pending = data[@"pendingCommand"];
    if ([pending isKindOfClass:[NSDictionary class]] && NTM_commandIsFresh(pending)) {
        NTM_executeCommand(pending);
    } else if ([pending isKindOfClass:[NSDictionary class]]) {
        [data removeObjectForKey:@"pendingCommand"]; // 清理残留旧命令
        NTM_save(data);
    }

    NSString *front = NTM_frontmostApp();
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

    // 充电检测：直接用系统电池状态（UIDeviceBatteryState），比"电量上升"判断更可靠
    UIDevice *dev = [UIDevice currentDevice];
    dev.batteryMonitoringEnabled = YES;
    UIDeviceBatteryState state = dev.batteryState;
    BOOL charging = (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
    BOOL prevCharging = [data[@"charging"] boolValue];
    if (charging && !prevCharging) {
        data[@"chargeStart"] = @(now);
    }
    if (!charging && prevCharging) {
        data[@"lastChargeEnd"] = @(now);
        data[@"chargeEndLevel"] = @(level > 0 ? level : prevLevel);
    }
    data[@"charging"] = @(charging);
    data[@"lastLevel"] = @(level);
    data[@"lastUpdate"] = @(now);

    NTM_pruneApps(data);
    NTM_save(data);
    } @catch (NSException *e) {
    }
}

// 限制 app 数量：只保留使用量（前台+后台）最大的前 15 个，防止数据无限增长
static void NTM_pruneApps(NSMutableDictionary *data) {
    NSMutableDictionary *apps = data[@"apps"];
    if (!apps || apps.count <= 15) return;
    NSArray *sorted = [apps keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"foreground"] doubleValue] + [a[@"background"] doubleValue];
        double tb = [b[@"foreground"] doubleValue] + [b[@"background"] doubleValue];
        if (ta == tb) return NSOrderedSame;
        return ta > tb ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSArray *keep = [sorted subarrayWithRange:NSMakeRange(0, 15)];
    NSMutableDictionary *newApps = [NSMutableDictionary dictionary];
    for (NSString *bid in keep) {
        newApps[bid] = apps[bid];
    }
    data[@"apps"] = newApps;
}

// 枚举当前进程（SpringBoard）已注入的 Tweak dylib 列表
static NSArray *NTM_loadedTweaks(void) {
    NSMutableArray *names = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path containsString:@"TweakInject"] || [path containsString:@"DynamicLibraries"]) {
            NSString *file = [path lastPathComponent];
            if (file.length && ![names containsObject:file]) [names addObject:file];
        }
    }
    return names;
}

// 采样当前进程所有线程的 CPU 使用率，按线程 PC 归属到各 Tweak dylib
// Tweak CPU 采样已彻底移除：task_threads/thread_get_state/dladdr 在 iOS 16.6 上会触发段错误，
// 导致 SpringBoard 崩溃进安全模式（@try 无法捕获段错误），故不再提供该功能

// 执行设置面板发来的续航方案命令（本 Tweak 运行在 SpringBoard 内，私有类可用）
static void NTM_executeCommand(NSDictionary *cmd) {
    NSString *action = cmd[@"action"];
    BOOL on = [cmd[@"on"] boolValue];
    BOOL ok = NO;
    @try {
        if ([action isEqualToString:@"airplane"]) {
            // 本 Tweak 运行在 SpringBoard 内，优先用 SBAirplaneModeController（原生、BOOL 参数安全）
            Class cls = NSClassFromString(@"SBAirplaneModeController");
            id ctrl = cls ? [cls performSelector:NSSelectorFromString(@"sharedInstance")] : nil;
            if (ctrl) {
                SEL sel = NSSelectorFromString(@"setAirplaneMode:");
                if ([ctrl respondsToSelector:sel]) {
                    void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[ctrl methodForSelector:sel];
                    fn(ctrl, sel, on);
                    ok = YES;
                }
            }
            // 兜底 SpringBoardServices 的 SBSSetAirplaneModeEnabled（注意参数是 CFBooleanRef，传 BOOL 会崩溃）
            if (!ok) {
                void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
                if (h) {
                    void (*fn)(CFBooleanRef) = (void (*)(CFBooleanRef))dlsym(h, "SBSSetAirplaneModeEnabled");
                    if (fn) {
                        fn(on ? kCFBooleanTrue : kCFBooleanFalse);
                        ok = YES;
                    }
                }
            }
        } else if ([action isEqualToString:@"lowpower"]) {
            NSProcessInfo *pi = [NSProcessInfo processInfo];
            SEL sel = NSSelectorFromString(@"setLowPowerModeEnabled:");
            if ([pi respondsToSelector:sel]) {
                void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[pi methodForSelector:sel];
                fn(pi, sel, on);
                ok = YES;
            }
        }
    } @catch (NSException *e) {
        ok = NO;
    }
    NSMutableDictionary *data = NTM_load();
    data[@"lastCommandResult"] = @{@"action": action ?: @"", @"ok": @(ok), @"at": @([[NSDate date] timeIntervalSince1970])};
    [data removeObjectForKey:@"pendingCommand"];
    NTM_save(data);
}

static int g_cmdToken = 0;
static int g_ctlToken = 0;

// 面板打开时开始采样，关闭时完全静默（省电）
static void NTM_startSampling(void) {
    if (g_timer) return;
    g_lastTick = 0;
    g_timer = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        NTM_tick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
}

static void NTM_stopSampling(void) {
    if (!g_timer) return;
    [g_timer invalidate];
    g_timer = nil;
}

// 监听面板开关（com.ntm.battery.control + plist 的 sampling 标记）
static void NTM_registerControlListener(void) {
    notify_register_dispatch("com.ntm.battery.control", &g_ctlToken, dispatch_get_main_queue(), ^(int token) {
        NSDictionary *data = NTM_load();
        BOOL on = [data[@"sampling"] boolValue];
        if (on) NTM_startSampling();
        else NTM_stopSampling();
    });
}

// 监听设置面板的 Darwin 通知，读取 pendingCommand 并执行
static void NTM_registerCommandListener(void) {
    notify_register_dispatch("com.ntm.battery.command", &g_cmdToken, dispatch_get_main_queue(), ^(int token) {
        NSMutableDictionary *data = NTM_load();
        NSDictionary *cmd = data[@"pendingCommand"];
        if ([cmd isKindOfClass:[NSDictionary class]] && NTM_commandIsFresh(cmd)) {
            NTM_executeCommand(cmd);
        }
    });
}

__attribute__((constructor))
static void NTM_init(void) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // 记录已注入的 Tweak 列表（面板 Tab1 展示）
                NSMutableDictionary *data = NTM_load();
                data[@"tweaks"] = NTM_loadedTweaks();
                // 默认静默：只有面板打开时才采样（省电）
                BOOL on = [data[@"sampling"] boolValue];
                NTM_save(data);
                if (on) NTM_startSampling();
                // 监听面板开关 + 续航方案命令
                NTM_registerControlListener();
                NTM_registerCommandListener();
            } @catch (NSException *e) {
            }
        });
    } @catch (NSException *e) {
    }
}
