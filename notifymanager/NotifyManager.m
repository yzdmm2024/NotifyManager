// NotifyManager —— rootless PreferenceBundle
// 单一滚动面板：顶部一键全开/全关，三段(用户应用/巨魔应用/系统应用)，
// 每个 App 总开关 + 锁屏/通知中心/横幅 3 个子开关。
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
- (void)setTarget:(id)target;
- (void)setButtonAction:(SEL)action;
@end
@interface NTMPrincipalController : PSListController @end

// standard cell 类型常量(同 Preferences.framework PSSpecifier.h)
static const long long NTM_SWITCH_CELL = 4;   // PSSwitchCell
static const long long NTM_LINK_LIST   = 3;   // PSLinkListCell(可执行 button action)

#pragma mark - 动态消息工具

static id NTM_msg0(id target, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}
static void NTM_msg1v(id target, const char *sel, id a1) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel_registerName(sel), a1);
}
static void NTM_setProp(id spec, NSString *key, id val) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), val, key);
}
static id NTM_getProp(id spec, NSString *key) {
    return ((id (*)(id, SEL, id))objc_msgSend)(spec, sel_registerName("propertyForKey:"), key);
}
static Class NTM_class(const char *name) { return objc_getClass(name); }

#pragma mark - 本地设置存取

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
    id spec = ((id (*)(id, SEL, id, id, SEL, SEL, id, long long, id))objc_msgSend)(
        (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        title, target, sSel, gSel, nil, NTM_SWITCH_CELL, nil);
    if (!spec) return nil;
    NTM_setProp(spec, @"appId", appId);
    NTM_setProp(spec, @"dim", dim);
    return spec;
}

// 可点击按钮行(一键全开 / 一键全关) —— 用 PSListController 标准的 target/action 机制
static id NTM_newButton(id target, NSString *title, SEL action, NSString *appId) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    id spec = ((id (*)(id, SEL, id, id, SEL, SEL, id, long long, id))objc_msgSend)(
        (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        title, target, NULL, NULL, nil, NTM_LINK_LIST, nil);
    if (!spec) return nil;
    // setTarget:/setAction: 是 PSSpecifier + PSListController 的标准按钮机制
    SEL tS = sel_registerName("setTarget:");
    SEL aS = sel_registerName("setAction:");
    if ([spec respondsToSelector:tS])
        ((void (*)(id, SEL, id))objc_msgSend)(spec, tS, target);
    if ([spec respondsToSelector:aS])
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, aS, action);
    if (appId) NTM_setProp(spec, @"appId", appId);
    return spec;
}

static id NTM_group(NSString *title) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)PS, sel_registerName("groupSpecifierWithName:"), title);
}

#pragma mark - 根页(单一滚动面板)

@implementation NTMPrincipalController

// ---- 开关 getter/setter ----
- (id)getEn:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), @"en")); }
- (void)setEn:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_write(NTM_getProp(spec, @"appId"), @"en", [value boolValue]);
    NTM_apply(NTM_getProp(spec, @"appId"));
}
- (id)getSub:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"))); }
- (void)setSub:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_write(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"), [value boolValue]);
    NTM_apply(NTM_getProp(spec, @"appId"));
}

// ---- 一键全开 / 一键全关 ----
- (void)enableAllNotifications { [self setAll:YES]; }
- (void)disableAllNotifications { [self setAll:NO]; }
- (void)setAll:(BOOL)on {
    for (NSDictionary *app in NTM_allApps()) {
        NSString *aid = app[@"id"];
        NTM_write(aid, @"en", on);
        NTM_apply(aid);
    }
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *arr = [NSMutableArray array];

    // 顶部：一键开/关
    id g0 = NTM_group(@"通知管理");
    if (g0) [arr addObject:g0];
    id btnOn  = NTM_newButton(self, @"一键开启所有通知", @selector(enableAllNotifications), nil);
    id btnOff = NTM_newButton(self, @"一键关闭所有通知", @selector(disableAllNotifications), nil);
    if (btnOn)  [arr addObject:btnOn];
    if (btnOff) [arr addObject:btnOff];

    // 三段
    for (NSString *cat in @[ @"用户应用", @"巨魔应用", @"系统应用" ]) {
        id grp = NTM_group(cat);
        if (grp) [arr addObject:grp];
        for (NSDictionary *app in NTM_allApps()) {
            if (![app[@"cat"] isEqualToString:cat]) continue;
            NSString *aid = app[@"id"];
            NSString *nm  = app[@"name"];

            // 每 App 一个分组标题 + 总开关 + 3 子开关
            NSString *bar = [NSString stringWithFormat:@"◆ %@", nm];
            id apGrp = NTM_group(bar);
            if (apGrp) [arr addObject:apGrp];
            id en = NTM_newSwitch(self, @"开启通知", aid, @"en", @selector(getEn:), @selector(setEn:));
            if (en) [arr addObject:en];
            NSArray *dims = @[ @[@"锁屏显示", @"lock"], @[@"通知中心", @"nc"], @[@"横幅", @"banner"] ];
            for (NSArray *pair in dims) {
                id sub = NTM_newSwitch(self, [@"    " stringByAppendingString:pair[0]],
                                       aid, pair[1], @selector(getSub:), @selector(setSub:));
                if (sub) [arr addObject:sub];
            }
        }
    }

    _specifiers = [arr copy];
    return _specifiers;
}
@end