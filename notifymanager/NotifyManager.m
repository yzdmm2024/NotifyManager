// NotifyManager —— rootless PreferenceBundle
// 三大分类页(用户/巨魔/系统) + 每 app: 总开关 + 锁屏/通知中心/横幅 3 子开关
// 全部动态 objc_msgSend，避免私有头 + ARC performSelector 问题。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 运行时接口声明(占位, 仅让编译器认识父类)

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (id)specifiers;
- (void)reloadSpecifiers;
- (id)specifier;
@end
@interface PSSpecifier : NSObject
- (void)setProperty:(id)prop forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end
@interface NTMAppsListController : PSListController
- (void)doSet:(NSNumber *)value spec:(PSSpecifier *)spec;
@end
@interface NTMPrincipalController : PSListController @end

// standard cell 类型常量(同 Preferences.framework PSSpecifier.h)
static const long long NTM_SWITCH_CELL = 4;   // PSSwitchCell
static const long long NTM_LINKLIST    = 3;   // PSLinkListCell

#pragma mark - 动态消息工具

static id NTM_msg0(id target, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static id NTM_msg1(id target, const char *sel, id a1) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel_registerName(sel), a1);
}
static id NTM_msg1s(id target, const char *sel, const char *a1) {
    return ((id (*)(id, SEL, const char *))objc_msgSend)(target, sel_registerName(sel), a1);
}
static id NTM_msg2(id target, const char *sel, id a1, id a2) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, sel_registerName(sel), a1, a2);
}
static void NTM_setProp(id spec, NSString *key, id val) {
    void (*f)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
    f(spec, sel_registerName("setProperty:forKey:"), val, key);
}
static id NTM_getProp(id spec, NSString *key) {
    return ((id (*)(id, SEL, id))objc_msgSend)(spec, sel_registerName("propertyForKey:"), key);
}

static Class NTM_class(const char *name) { return objc_getClass(name); }

static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES; // 默认开启
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:NTM_key(appId, dim)];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 把当前整组状态应用到系统
static void NTM_apply(NSString *appId) {
    BOOL on     = NTM_read(appId, @"en");
    BOOL lock   = on && NTM_read(appId, @"lock");
    BOOL nc     = on && NTM_read(appId, @"nc");
    BOOL banner = on && NTM_read(appId, @"banner");
    @try {
        Class gwCls    = NTM_class("BBSettingsGateway");
        Class infoCls  = NTM_class("BBSectionInfo");
        if (!gwCls || !infoCls) return;
        id gw = NTM_msg0((id)gwCls, "alloc");
        if (!gw) return;
        gw = NTM_msg0(gw, "init");
        id info = NTM_msg0((id)infoCls, "alloc");
        if (!info) return;
        info = NTM_msg0(info, "init");
        void (*setB)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
        setB(info, sel_registerName("setAllowsNotifications:"), on);
        setB(info, sel_registerName("setShowsOnLockScreen:"), lock);
        setB(info, sel_registerName("setShowsInNotificationCenter:"), nc);
        setB(info, sel_registerName("setShowsInBulletinBoard:"), banner);
        SEL selSI = sel_registerName("setSectionInfo:forSectionID:");
        if ([gw respondsToSelector:selSI]) {
            void (*msgSS)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            msgSS(gw, selSI, info, appId);
        }
    } @catch (NSException *e) { /* 私有API失败静默 */ }
}

#pragma mark - 枚举应用

static NSString *NTM_catOfPath(NSString *path) {
    NSString *p = path ?: @"";
    if ([p containsString:@"/System/Applications/"] ||
        [p containsString:@"/System/Library/"] ||
        ([p containsString:@"/Applications/"] && ![p containsString:@"/private/var/"])) {
        return @"系统应用";
    }
    return @"用户应用"; // 巨魔应用暂并入用户(均 adhoc/private/var)
}

static NSArray *NTM_allApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class wk = NTM_class("LSApplicationWorkspace");
    if (!wk) return out;
    id ws = NTM_msg0((id)wk, "defaultWorkspace");
    if (!ws) return out;
    NSArray *proxies = NTM_msg0(ws, "allApplications");
    for (id proxy in proxies) {
        NSString *bid  = NTM_msg0(proxy, "applicationIdentifier");
        NSURL *url     = NTM_msg0(proxy, "bundleURL");
        NSString *name = NTM_msg0(proxy, "localizedName");
        NSString *path = [(NSURL *)url path] ?: @"";
        if (!bid.length || !path.length) continue;
        [out addObject:@{ @"id":bid, @"name":(name.length? name: bid), @"path":path,
                          @"cat":NTM_catOfPath(path) }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        return [a[@"name"] compare:b[@"name"]];
    }];
    return out;
}

#pragma mark - PSSpecifier 工厂(直接 msgSend 构建)

static id NTM_newSwitch(id target, NSString *title, NSString *appId, NSString *dim,
                        SEL gSel, SEL sSel) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    // +preferenceSpecifierNamed:target:set:get:detail:cell:edit:
    void (*pref)(id, SEL, id, id, SEL, SEL, id, long long, id) =
        (void (*)(id, SEL, id, id, SEL, SEL, id, long long, id))objc_msgSend;
    id spec = ((id (*)(id, SEL, id, id, SEL, SEL, id, long long, id))pref)(
        (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        title, target, sSel, gSel, nil, NTM_SWITCH_CELL, nil);
    if (!spec) return nil;
    NTM_setProp(spec, @"appId", appId);
    NTM_setProp(spec, @"dim", dim);
    return spec;
}

static id NTM_newLink(id target, NSString *title, NSString *cat) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    void (*pref)(id, SEL, id, id, SEL, SEL, id, long long, id) =
        (void (*)(id, SEL, id, id, SEL, SEL, id, long long, id))objc_msgSend;
    id spec = ((id (*)(id, SEL, id, id, SEL, SEL, id, long long, id))pref)(
        (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        title, target, NULL, @selector(getLinks:),
        NTM_class("NTMAppsListController"), NTM_LINKLIST, nil);
    if (spec) NTM_setProp(spec, @"cat", cat);
    return spec;
}

static id NTM_group(NSString *title) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    void (*g)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    return ((id (*)(id, SEL, id))g)((id)PS, sel_registerName("groupSpecifierWithName:"), title);
}

#pragma mark - Apps 分类页

@implementation NTMAppsListController

- (NSString *)catOfSelf {
    id spec = [self specifier];
    if (spec) {
        id c = NTM_getProp(spec, @"cat");
        if ([c isKindOfClass:[NSString class]]) return c;
    }
    return @"用户应用";
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSString *cat = [self catOfSelf];
    NSMutableArray *arr = [NSMutableArray array];
    id grp = NTM_group(cat);
    if (grp) [arr addObject:grp];
    for (NSDictionary *app in NTM_allApps()) {
        if (![app[@"cat"] isEqualToString:cat]) continue;
        NSString *aid = app[@"id"];
        NSString *nm  = app[@"name"];
        id g = NTM_group(nm);
        if (g) [arr addObject:g];
        // 总开关
        id en = NTM_newSwitch(self, @"开启通知", aid, @"en", @selector(getEn:), @selector(setEn:));
        if (en) [arr addObject:en];
        // 子开关
        NSArray *dims = @[ @[@"锁屏", @"lock"], @[@"通知中心", @"nc"], @[@"横幅", @"banner"] ];
        for (NSArray *pair in dims) {
            id sub = NTM_newSwitch(self, pair[0], aid, pair[1], @selector(getSub:), @selector(setSub:));
            if (sub) [arr addObject:sub];
        }
    }
    _specifiers = [arr copy];
    return _specifiers;
}

#pragma mark switch getter/setter
- (id)getEn:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"))); }
- (void)setEn:(NSNumber *)value specifier:(PSSpecifier *)spec { [self doSet:value spec:spec]; }
- (id)getSub:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"))); }
- (void)setSub:(NSNumber *)value specifier:(PSSpecifier *)spec { [self doSet:value spec:spec]; }
- (void)doSet:(NSNumber *)value spec:(PSSpecifier *)spec {
    NSString *appId = NTM_getProp(spec, @"appId");
    NSString *dim   = NTM_getProp(spec, @"dim");
    if (!appId || !dim) return;
    NTM_write(appId, dim, [value boolValue]);
    NTM_apply(appId);
}
@end

#pragma mark - 根页

@implementation NTMPrincipalController
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *arr = [NSMutableArray array];
    id g = NTM_group(@"通知管理");
    if (g) [arr addObject:g];
    for (NSString *cat in @[ @"用户应用", @"巨魔应用", @"系统应用" ]) {
        id link = NTM_newLink(self, cat, cat);
        if (link) [arr addObject:link];
    }
    _specifiers = [arr copy];
    return _specifiers;
}
- (id)getLinks:(PSSpecifier *)spec { return nil; }
@end