// NotifyManager —— rootless PreferenceBundle
// 面板：顶部 3 分类分段控件（用户应用/巨魔应用/系统应用）切换，
//      每分类下列出 App（图标+名字），每 App 三个开关：
//      锁屏通知 / 通知中心 / 横幅。顶部一键开启/一键关闭。
// 全部动态 objc_msgSend，避免私有头 + ARC 问题。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 运行时接口声明(占位, 仅让编译器认识父类)

@interface PSListController : UIViewController {
    NSArray *_specifiers;
    id _specifier;
}
- (id)specifiers;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (id)readPreferenceValue:(id)specifier;
- (id)specifier;
- (void)lazyLoadBundle:(id)__unused bundle;
@end
@interface PSSpecifier : NSObject
- (void)setProperty:(id)prop forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setTarget:(id)target;
- (void)setButtonAction:(SEL)action;
- (void)setCellType:(long long)type;
- (void)setName:(NSString *)name;
@end
@interface NTMPrincipalController : PSListController @end

#pragma mark - PSCellType 权威枚举值 (theos PSSpecifier/PSTableCell.h)
static const long long CT_GROUP     = 0;   // PSGroupCell
static const long long CT_SWITCH    = 6;   // PSSwitchCell
static const long long CT_SEGMENT   = 9;   // PSSegmentCell
static const long long CT_BUTTON    = 13;  // PSButtonCell
static const long long CT_LINK      = 1;   // PSLinkCell

#pragma mark - 动态消息工具
typedef id (*msg0fn)(id, SEL);
typedef id (*msg1fn)(id, SEL, id);
typedef id (*msg2fn)(id, SEL, id, id);
typedef void (*vmsg0)(id, SEL);

static id NTM_msg0(id t, const char *s)   { return ((msg0fn)objc_msgSend)(t, sel_registerName(s)); }
static id NTM_msg1(id t, const char *s, id a) { return ((msg1fn)objc_msgSend)(t, sel_registerName(s), a); }
static void NTM_setProp(id spec, NSString *key, id val) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), val, key);
}
static id NTM_getProp(id spec, NSString *key) {
    return ((id (*)(id, SEL, id))objc_msgSend)(spec, sel_registerName("propertyForKey:"), key);
}
static Class NTM_class(const char *name) { return objc_getClass(name); }

#pragma mark - 本地设置存取 (默认开启)
static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:NTM_key(appId, dim)];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 应用当前状态到系统 (BBSettingsGateway)
static void NTM_apply(NSString *appId) {
    BOOL on     = NTM_read(appId, @"en");
    BOOL lock   = on && NTM_read(appId, @"lock");
    BOOL nc     = on && NTM_read(appId, @"nc");
    BOOL banner = on && NTM_read(appId, @"banner");
    @try {
        Class gwCls = NTM_class("BBSettingsGateway");
        if (!gwCls) return;
        id gw = NTM_msg0(NTM_msg0((id)gwCls, "alloc"), "init");
        if (!gw) return;
        // 尝试先取当前 section，保留其它字段；失败则新建空白
        id info = nil;
        SEL effSel = sel_registerName("effectiveSectionInfoForSectionID:");
        if ([gw respondsToSelector:effSel]) {
            id eff = ((id (*)(id, SEL, id))objc_msgSend)(gw, effSel, appId);
            // 仅传 appId alignment: eff 是 BBSectionInfo, 直接用其可变副本 or 原对象
            if (eff) info = eff;
        }
        if (!info) {
            Class infoCls = NTM_class("BBSectionInfo");
            if (infoCls) {
                info = NTM_msg0(NTM_msg0((id)infoCls, "alloc"), "init");
            }
        }
        if (!info) return;
        void (*setB)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
        setB(info, sel_registerName("setAllowsNotifications:"), on);
        setB(info, sel_registerName("setShowsOnLockScreen:"), lock);
        setB(info, sel_registerName("setShowsInNotificationCenter:"), nc);
        setB(info, sel_registerName("setShowsInBulletinBoard:"), banner);
        // 通知系统刷新
        void (*setSI)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        @try {
            setSI(gw, sel_registerName("setSectionInfo:forSectionID:"), info, appId);
        } @catch (NSException *e) {
            // withCompletion 变体
            @try {
                void (*setSIC)(id, SEL, id, id, id);
                setSIC = (void (*)(id, SEL, id, id, id))objc_msgSend;
                setSIC(gw, sel_registerName("setSectionInfo:forSectionID:withCompletion:"), info, appId, nil);
            } @catch (NSException *e2) {}
            return;
        }
        // 广播刷新通知中心
        @try {
            extern int notify_notify(const char *name, int *token);
            notify_notify("com.apple.BulletinBoard.SettingsSync", NULL);
        } @catch (NSException *e) {}
    } @catch (NSException *e) {}
}

#pragma mark - 枚举应用 (正确分类)
static NSString *NTM_catOfProxy(id proxy) {
    // applicationType -> "System"/"User"; signerIdentity -> Apple/AppStore vs adhoc
    NSString *type  = NTM_msg0(proxy, "applicationType") ?: @"";
    NSString *signer = NTM_msg0(proxy, "signerIdentity") ?: @"";
    NSURL *url      = NTM_msg0(proxy, "bundleURL");
    NSString *path  = [(NSURL *)url path] ?: @"";
    BOOL adhoc = (signer.length && ([signer containsString:@"adhoc"] || [signer containsString:@"AdHoc"] || [signer containsString:@"app-signed"] || [signer containsString:@"App"]) == NO);
    if ([type isEqualToString:@"System"]) return @"系统应用";
    if ([path containsString:@"/private/var/containers/Bundle/Application/"]) {
        // App Store 应用 signer 含 "Apple"; TrollStore/巨魔 是 adhoc
        BOOL isApple = ([signer containsString:@"Apple"] || [signer containsString:@"App Store"] || [signer containsString:@"iPhone Developer"]);
        return isApple ? @"用户应用" : @"巨魔应用";
    }
    return @"用户应用";
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
        NSData *iconData = nil;
        @try {
            id idata = ((id (*)(id, SEL, long long))objc_msgSend)(proxy, sel_registerName("iconDataForVariant:"), 0);
            if (idata) iconData = idata;
        } @catch (NSException *e) {}
        [out addObject:@{ @"id":bid, @"name":(name.length? name: bid), @"path":path,
                          @"cat":NTM_catOfProxy(proxy),
                          @"icon":(iconData? iconData:[NSNull null]) }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        NSArray *order = @[ @"用户应用", @"巨魔应用", @"系统应用" ];
        NSInteger ia = [order indexOfObject:a[@"cat"]];
        NSInteger ib = [order indexOfObject:b[@"cat"]];
        if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}

#pragma mark - PSSpecifier 工厂
// factory: name:target:set:get:detail:cell:edit:  (set SEL 在前, get SEL 在后; cell 为整数)
typedef id (*nmsfn)(id, SEL, id, id, SEL, SEL, id, long long, id);
#define NTM_BUILD(title,target,setSel,getSel,cellType) \
    ((nmsfn)objc_msgSend)((id)NTM_class("PSSpecifier"), \
        sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"), \
        title, target, setSel, getSel, nil, (long long)(cellType), 0)

static id NTM_newSwitch(NSString *title, id target, NSString *appId, NSString *dim, SEL g, SEL s) {
    id spec = NTM_BUILD(title, target, s, g, CT_SWITCH);
    if (!spec) return nil;
    NTM_setProp(spec, @"appId", appId);
    NTM_setProp(spec, @"dim", dim);
    return spec;
}

static id NTM_newButton(id target, NSString *title, SEL action) {
    id spec = NTM_BUILD(title, target, 0, 0, CT_BUTTON);
    if (!spec) return nil;
    if ([spec respondsToSelector:sel_registerName("setButtonAction:")])
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, sel_registerName("setButtonAction:"), action);
    return spec;
}

static id NTM_group(NSString *title) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)((id)PS, sel_registerName("groupSpecifierWithName:"), title);
}

// 当前分类 (分段控件状态)
static NSInteger NTM_curCat = 0; // 0=用户 1=巨魔 2=系统
static NSDictionary *NTM_lastApps = nil; // 缓存一次

@implementation NTMPrincipalController

- (id)getCat:(PSSpecifier *)spec {
    return [NSNumber numberWithInteger:NTM_curCat];
}
- (void)setCat:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_curCat = [value integerValue];
    _specifiers = nil;
    [self reloadSpecifiers];
    // 通知刷新
    @try {
        extern int notify_notify(const char *name, int *token);
        notify_notify("com.apple.Preferences.switchNotificationSettings", NULL);
    } @catch (NSException *e) {}
}

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

- (void)enableAllNotifications { [self setAll:YES]; }
- (void)disableAllNotifications { [self setAll:NO]; }
- (void)setAll:(BOOL)on {
    for (NSDictionary *app in NTM_allApps()) {
        NSString *aid = app[@"id"];
        NTM_write(aid, @"en", on);
        NTM_apply(aid);
    }
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *all = NTM_allApps();

    id g0 = NTM_group(@"通知管理");
    if (g0) [arr addObject:g0];

    // 分类分段控件
    {
        Class PS = NTM_class("PSSpecifier");
        id spec = ((msg2fn)objc_msgSend)(
            (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
            @"分类", self,
            [NSValue valueWithPointer:@selector(setCat:specifier:)],
            [NSValue valueWithPointer:@selector(getCat:)],
            nil, [NSNumber numberWithLongLong:CT_SEGMENT], nil);
        if (spec) {
            NTM_setProp(spec, @"validValues", @[ @(0), @(1), @(2) ]);
            NTM_setProp(spec, @"validTitles", @[ @"用户应用", @"巨魔应用", @"系统应用" ]);
            NTM_setProp(spec, @"appId", @"__cat__");
            [arr addObject:spec];
        }
    }

    // 顶部按钮
    id btnOn  = NTM_newButton(self, @"一键开启所有通知", @selector(enableAllNotifications));
    id btnOff = NTM_newButton(self, @"一键关闭所有通知", @selector(disableAllNotifications));
    if (btnOn)  [arr addObject:btnOn];
    if (btnOff) [arr addObject:btnOff];

    // 当前分类 app 列表
    NSString *cats[] = { @"用户应用", @"巨魔应用", @"系统应用" };
    NSString *cat = cats[NTM_curCat];
    NSInteger shown = 0;
    for (NSDictionary *app in all) {
        if (![app[@"cat"] isEqualToString:cat]) continue;
        if (shown == 0) {
            id grp = NTM_group(cat);
            if (grp) [arr addObject:grp];
        }
        shown++;
        NSString *aid = app[@"id"];
        // App 标题(带图标): 用 group cell 标题 + cellType? 更好用 iconImage 的 PSLinkCell
        id hdr = NTM_group(app[@"name"]);
        if (hdr) [arr addObject:hdr];
        NSArray *dims = @[ @[@"锁屏通知", @"lock"], @[@"通知中心", @"nc"], @[@"横幅", @"banner"] ];
        for (NSArray *pair in dims) {
            id sub = NTM_newSwitch(pair[0], self, aid, pair[1],
                                   @selector(getSub:), @selector(setSub:specifier:));
            if (sub) [arr addObject:sub];
        }
    }
    if (shown == 0) {
        id grp = NTM_group([cat stringByAppendingString:@"（无应用）"]);
        if (grp) [arr addObject:grp];
    }

    _specifiers = [arr copy];
    return _specifiers;
}
@end