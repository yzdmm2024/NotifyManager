// NotifyManager.m — PreferenceBundle 设置面板
// 枚举已安装 App，每个 App 显示总开关 + 锁屏/通知中心/横幅子开关
// 配置保存到 NSUserDefaults suiteName，Tweak 读取并拦截通知
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 接口声明
@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (id)specifiers;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (id)readPreferenceValue:(id)specifier;
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

#pragma mark - Cell 类型
static const long long CT_GROUP   = 0;
static const long long CT_SWITCH  = 6;
static const long long CT_SEGMENT = 9;
static const long long CT_BUTTON  = 13;

#pragma mark - 消息工具
static id NTM_msg0(id t, const char *s)   { return ((id(*)(id,SEL))objc_msgSend)(t, sel_registerName(s)); }
static void NTM_setProp(id spec, NSString *key, id val) {
    ((void(*)(id,SEL,id,id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), val, key);
}
static id NTM_getProp(id spec, NSString *key) {
    return ((id(*)(id,SEL,id))objc_msgSend)(spec, sel_registerName("propertyForKey:"), key);
}
static Class NTM_class(const char *name) { return objc_getClass(name); }

#pragma mark - 存储: NSUserDefaults suiteName (Tweak 读取同一份)
static NSString *NTM_suite = @"com.ntm.notifymanager";
static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    id v = [prefs objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    [prefs setBool:val forKey:NTM_key(appId, dim)];
    [prefs synchronize];
}

#pragma mark - 枚举 App (LSApplicationWorkspace)
static NSString *NTM_catOfProxy(id proxy) {
    NSString *type = NTM_msg0(proxy, "applicationType") ?: @"";
    NSString *bid  = NTM_msg0(proxy, "applicationIdentifier") ?: @"";
    if ([type isEqualToString:@"System"]) {
        return ([bid hasPrefix:@"com.apple."]) ? @"系统应用" : @"巨魔应用";
    }
    NSString *teamID = NTM_msg0(proxy, "teamID") ?: @"";
    BOOL appleSign = (teamID.length && ![teamID isEqualToString:@"adhoc"] && ![teamID isEqualToString:@"AdHoc"]);
    return appleSign ? @"用户应用" : @"巨魔应用";
}

static UIImage *NTM_iconFor(NSString *bid) {
    if (!bid.length) return nil;
    @try {
        id (*f)(id,SEL,id,long long,double) = (id(*)(id,SEL,id,long long,double))objc_msgSend;
        id icon = f((id)UIImage.class, sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:"), bid, 0, 2.0);
        if (icon && [icon isKindOfClass:UIImage.class]) return (UIImage *)icon;
    } @catch(NSException *e) {}
    return nil;
}

static NSArray *NTM_allApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    // 确保 LSApplicationWorkspace 可用
    Class wk = NTM_class("LSApplicationWorkspace");
    if (!wk) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        wk = NTM_class("LSApplicationWorkspace");
    }
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
        NSString *cat = NTM_catOfProxy(proxy);
        if ([cat isEqualToString:@"系统应用"] &&
            ([path hasPrefix:@"/System/Library/"] && ![bid hasPrefix:@"com.apple"])) continue;
        [out addObject:@{ @"id":bid, @"name":(name.length?name:bid), @"cat":cat,
                          @"icon":(NTM_iconFor(bid) ?: [NSNull null]) }];
    }
    NSArray *order = @[@"用户应用", @"巨魔应用", @"系统应用"];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        NSInteger ia = [order indexOfObject:a[@"cat"]];
        NSInteger ib = [order indexOfObject:b[@"cat"]];
        if (ia != ib) return ia<ib ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}

#pragma mark - PSSpecifier 工厂
typedef id (*nmsfn)(id,SEL,id,id,SEL,SEL,id,long long,id);
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
    id spec = NTM_BUILD(title, target, NULL, NULL, CT_BUTTON);
    if (!spec) return nil;
    if ([spec respondsToSelector:sel_registerName("setButtonAction:")])
        ((void(*)(id,SEL,SEL))objc_msgSend)(spec, sel_registerName("setButtonAction:"), action);
    return spec;
}

static id NTM_group(NSString *title) {
    return ((id(*)(id,SEL,id))objc_msgSend)((id)NTM_class("PSSpecifier"),
        sel_registerName("groupSpecifierWithName:"), title);
}

static id NTM_newAppHeader(NSString *title, UIImage *icon) {
    Class PS = NTM_class("PSSpecifier");
    if (!PS) return nil;
    id spec = ((id(*)(id,SEL,id,id,SEL,SEL,id,long long,id))objc_msgSend)(
        (id)PS, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
        title, nil, NULL, NULL, nil, (long long)CT_GROUP, 0);
    if (spec && icon && [spec respondsToSelector:sel_registerName("setProperty:forKey:")])
        ((void(*)(id,SEL,id,id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), icon, @"iconImage");
    return spec;
}

#pragma mark - 控制器
static NSInteger NTM_curCat = 0;

@implementation NTMPrincipalController

- (id)getCat:(PSSpecifier *)spec { return @(NTM_curCat); }
- (void)setCat:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_curCat = [value integerValue];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)getEn:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), @"en")); }
- (void)setEn:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_write(NTM_getProp(spec, @"appId"), @"en", [value boolValue]);
}
- (id)getSub:(PSSpecifier *)spec { return @(NTM_read(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"))); }
- (void)setSub:(NSNumber *)value specifier:(PSSpecifier *)spec {
    NTM_write(NTM_getProp(spec, @"appId"), NTM_getProp(spec, @"dim"), [value boolValue]);
}

- (void)enableAllNotifications {
    for (NSDictionary *app in NTM_allApps()) {
        NTM_write(app[@"id"], @"en", YES);
    }
    _specifiers = nil; [self reloadSpecifiers];
}
- (void)disableAllNotifications {
    for (NSDictionary *app in NTM_allApps()) {
        NTM_write(app[@"id"], @"en", NO);
    }
    _specifiers = nil; [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *all = NTM_allApps();

    // 日志到文件，便于调试 app 列表问题
    @try {
        NSString *log = [NSString stringWithFormat:@"NTM_allApps count=%lu\n", (unsigned long)all.count];
        [log writeToFile:@"/tmp/ntm_prefs.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch(NSException *e) {}

    id g0 = NTM_group(@"通知管理");
    if (g0) [arr addObject:g0];

    // 分类分段控件
    {
        id spec = NTM_BUILD(@"分类", self, @selector(setCat:specifier:), @selector(getCat:), CT_SEGMENT);
        if (spec) {
            NTM_setProp(spec, @"validValues", @[@(0), @(1), @(2)]);
            NTM_setProp(spec, @"validTitles", @[@"用户应用", @"巨魔应用", @"系统应用"]);
            [arr addObject:spec];
        }
    }

    // 一键按钮
    id btnOn  = NTM_newButton(self, @"一键开启所有通知", @selector(enableAllNotifications));
    id btnOff = NTM_newButton(self, @"一键关闭所有通知", @selector(disableAllNotifications));
    if (btnOn)  [arr addObject:btnOn];
    if (btnOff) [arr addObject:btnOff];

    // 当前分类 App 列表
    NSString *cats[] = {@"用户应用", @"巨魔应用", @"系统应用"};
    NSString *cat = cats[NTM_curCat];
    NSInteger shown = 0;
    for (NSDictionary *app in all) {
        if (![app[@"cat"] isEqualToString:cat]) continue;
        if (shown == 0) {
            id grp = NTM_group(cat);
            if (grp) [arr addObject:grp];
        }
        shown++;
        id hdr = NTM_newAppHeader(app[@"name"], (app[@"icon"] != [NSNull null]) ? app[@"icon"] : nil);
        if (hdr) [arr addObject:hdr];
        NSArray *dims = @[@[@"🔒 锁屏通知", @"lock"], @[@"💬 通知中心", @"nc"], @[@"📋 横幅", @"banner"]];
        for (NSArray *pair in dims) {
            id sub = NTM_newSwitch(pair[0], self, app[@"id"], pair[1],
                                   @selector(getSub:), @selector(setSub:specifier:));
            if (sub) [arr addObject:sub];
        }
    }
    if (shown == 0) {
        [arr addObject:NTM_group([cat stringByAppendingString:@"（无应用）"])];
    }

    _specifiers = [arr copy];
    return _specifiers;
}
@end