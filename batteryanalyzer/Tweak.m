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

static void NTM_tick(void) {
    NSMutableDictionary *data = NTM_load();
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval dt = (g_lastTick > 0) ? (now - g_lastTick) : 5.0;
    g_lastTick = now;
    if (dt <= 0 || dt > 60) dt = 5.0;

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

// 采样当前进程所有线程的 PC，统计各 Tweak dylib 的 CPU 占用（绝对占比 = 该 dylib 采样数 / 总采样数）
static NSDictionary *NTM_sampleTweakCpu(void) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSInteger total = 0;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) return nil;
    for (int round = 0; round < 20; round++) {
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            arm_thread_state64_t state;
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state, &sc) != KERN_SUCCESS) continue;
            uint64_t pc = state.__pc;
            if (!pc) continue;
            total++;
            Dl_info info;
            if (dladdr((const void *)pc, &info) && info.dli_fname) {
                NSString *name = [NSString stringWithUTF8String:info.dli_fname];
                if ([name containsString:@"TweakInject"] || [name containsString:@"DynamicLibraries"]) {
                    NSString *file = [name lastPathComponent];
                    counts[file] = @([counts[file] integerValue] + 1);
                }
            }
        }
        usleep(50000);
    }
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
    if (total == 0) return @{};
    NSMutableDictionary *pct = [NSMutableDictionary dictionary];
    for (NSString *k in counts) {
        pct[k] = @((double)[counts[k] integerValue] / total * 100.0);
    }
    return pct;
}

static dispatch_queue_t g_cpuQueue = nil;

// 每 15 秒后台采样一次 Tweak CPU，写入 plist 供设置面板读取
static void NTM_scheduleCpuSample(void) {
    if (!g_cpuQueue) g_cpuQueue = dispatch_queue_create("com.ntm.battery.cpu", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), g_cpuQueue, ^{
        NSMutableDictionary *data = NTM_load();
        data[@"tweakCpu"] = NTM_sampleTweakCpu();
        data[@"tweakCpuAt"] = @([[NSDate date] timeIntervalSince1970]);
        NTM_save(data);
        NTM_scheduleCpuSample();
    });
}

__attribute__((constructor))
static void NTM_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_timer = [NSTimer timerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
            NTM_tick();
        }];
        [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
        NTM_tick();
        // 记录已注入的 Tweak 列表（面板 Tab1 展示）
        NSMutableDictionary *data = NTM_load();
        data[@"tweaks"] = NTM_loadedTweaks();
        NTM_save(data);
        // 后台采样 Tweak CPU（每 15 秒）
        NTM_scheduleCpuSample();
    });
}
