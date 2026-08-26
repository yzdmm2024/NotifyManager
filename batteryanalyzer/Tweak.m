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
// 用 thread_info(THREAD_BASIC_INFO) 的 cpu_usage（内核维护的真实 CPU 占比），
// 比纯 PC 采样计数更准确；无 Tweak 命中时返回 _idle 标记，面板显示"空闲"而非"采样中"
static NSDictionary *NTM_sampleTweakCpu(void) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) return nil;
    @try {
        for (int round = 0; round < 4; round++) {
            for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
                // 线程实时 CPU 使用率（cpu_usage 单位：百分之一百分比，100 = 1%）
                thread_basic_info_t basic;
                mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
                double cpu = 0;
                if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &bc) == KERN_SUCCESS) {
                    cpu = basic->cpu_usage / 100.0;
                }
                // 通过 PC 归属到具体 dylib：直接用 state.__pc 字段（编译器保证正确布局），
                // 避免硬编码偏移量导致读到垃圾地址引发 dladdr 段错误（段错误无法被 @try 捕获）
                arm_thread_state64_t state;
                mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
                uint64_t pc = 0;
                if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state, &sc) == KERN_SUCCESS) {
                    pc = state.__pc;
                }
                if (pc) {
                    Dl_info info;
                    if (dladdr((const void *)pc, &info) && info.dli_fname) {
                        NSString *name = [NSString stringWithUTF8String:info.dli_fname];
                        if ([name containsString:@"TweakInject"] || [name containsString:@"DynamicLibraries"]) {
                            NSString *file = [name lastPathComponent];
                            counts[file] = @([counts[file] doubleValue] + MAX(cpu, 0.01));
                        }
                    }
                }
            }
            usleep(30000);
        }
    } @catch (NSException *e) {
    }
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
    if (!counts.count) return @{@"_idle": @1};
    return counts;
}

static dispatch_queue_t g_cpuQueue = nil;

// 每 60 秒后台采样一次 Tweak CPU，写入 plist 供设置面板读取（首次 60 秒后开始，避开 SpringBoard 启动繁忙期）
static void NTM_scheduleCpuSample(void) {
    if (!g_cpuQueue) g_cpuQueue = dispatch_queue_create("com.ntm.battery.cpu", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), g_cpuQueue, ^{
        @try {
            NSMutableDictionary *data = NTM_load();
            data[@"tweakCpu"] = NTM_sampleTweakCpu();
            data[@"tweakCpuAt"] = @([[NSDate date] timeIntervalSince1970]);
            NTM_save(data);
        } @catch (NSException *e) {
        }
        NTM_scheduleCpuSample();
    });
}

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
                g_timer = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
                    NTM_tick();
                }];
                [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
                NTM_tick();
                // 记录已注入的 Tweak 列表（面板 Tab1 展示）
                NSMutableDictionary *data = NTM_load();
                data[@"tweaks"] = NTM_loadedTweaks();
                NTM_save(data);
                // 后台采样 Tweak CPU（首次 60 秒后，每 60 秒一次）
                NTM_scheduleCpuSample();
                // 监听续航方案命令
                NTM_registerCommandListener();
            } @catch (NSException *e) {
            }
        });
    } @catch (NSException *e) {
    }
}
