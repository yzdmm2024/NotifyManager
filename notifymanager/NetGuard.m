// NetGuard.m — 进程级「彻底断网」(WiFi + 蜂窝)
//
// 背景: PSAppDataUsagePolicyCache -setUsagePoliciesForBundle:cellular:wifi: 只能真正切断
//       蜂窝数据，iOS 15/16/17 都没有「按 App 断 WiFi」的系统能力，所以原来设了断网、
//       连着 WiFi 时 App 照样有网。
//
// 做法: 本文件与 Tweak.m 一起编译进同一个 Tweak.dylib，随 TweakInject 注入到 App 进程。
//       只在 BSD 连接入口(connectx / connect / sendto / sendmsg)判断：若本进程所属 App
//       在插件里被设为「断网」(NTM_net_<bundleId> == 1)，就直接返回失败，从而同时切断
//       WiFi 与蜂窝。未配置断网的进程完全透传，行为零变化。
//
// 兼容: 仅使用 BSD socket 层与 substrate/ElleKit 的 MSHookFunction，
//       iOS 15 / 16 / 17 通用。取不到 hook 框架时静默跳过，不会崩溃。
//
// 已知边界: WKWebView 的网络在独立的 com.apple.WebKit.Networking 进程里、
//          后台 NSURLSession 由 nsurlsessiond 代发，这两类不经过本 App 进程，故不在拦截范围。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <errno.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static NSString *const kNGChanged = @"com.ntm.notifymanager.configChanged";

// Tweak.m（同一 dylib）：镜像优先 → 本进程 suite 的配置读取。
// 第三方 App 沙盒读不到面板 suite，SpringBoard 会把配置转写进各 App 容器的
// ntm_config.plist，由 NTM_prefObject 统一做「镜像优先、suite 兜底」。
extern id NTM_prefObject(NSString *key);

// policy: 0=wifi+流量 1=断网 2=只wifi 3=只流量（与设置面板一致）
static const NSInteger kNGPolicyBlocked = 1;

#pragma mark - 本进程身份与配置

static NSString *NG_bundleId(void) {
    NSString *bid = nil;
    @try { bid = [[NSBundle mainBundle] bundleIdentifier]; } @catch (NSException *e) {}
    return bid;
}

// 热路径只读 g_blocked，避免每次连接都碰 NSUserDefaults
static volatile BOOL g_blocked  = NO;
static volatile BOOL g_resolved = NO;
// 后台断网置位：App 切后台时由 Tweak.m 的前后台回调经 NG_setBgBlocked() 置位
static volatile BOOL g_bgBlocked = NO;

void NG_refresh(void) {
    // 先置位：万一 NSUserDefaults 内部再触发被 hook 的函数，也不会递归
    g_resolved = YES;

    NSString *bid = NG_bundleId();
    BOOL blocked = NO;
    if (bid.length) {
        @try {
            id v = NTM_prefObject([NSString stringWithFormat:@"NTM_net_%@", bid]);
            blocked = (v != nil) && ([v integerValue] == kNGPolicyBlocked);
        } @catch (NSException *e) {}
    }
    g_blocked = blocked;
}

// 构造期 mainBundle 偶发未就绪，故首次用到时再懒解析一次
static inline BOOL NG_blocked(void) {
    if (g_blocked || g_bgBlocked) return YES;
    if (!g_resolved) NG_refresh();
    return g_blocked || g_bgBlocked;
}

static void NG_onConfigChanged(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NG_refresh();
}

#pragma mark - 地址判定：回环 / 本机域放行

// 放行回环(127/8、::1)与 Unix 域套接字，否则会把 App 与本地服务、系统 XPC 的通信也打断
static BOOL NG_isLocal(const struct sockaddr *sa) {
    if (!sa) return YES;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
        return ((ntohl(in->sin_addr.s_addr) >> 24) == 127);
    }
    if (sa->sa_family == AF_INET6) {
        const uint8_t *b = (const uint8_t *)&((const struct sockaddr_in6 *)sa)->sin6_addr;
        static const uint8_t loopback[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        if (memcmp(b, loopback, 16) == 0) return YES;
        static const uint8_t v4mapped[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
        if (memcmp(b, v4mapped, 12) == 0 && b[12] == 127) return YES;
        return NO;
    }
    return YES; // AF_UNIX / AF_SYSTEM 等非 IP 地址
}

#pragma mark - 后台断网 (Tweak.m 的 UIApplication 前后台回调调用)

// 已建立的连接不经过 connect()，只置 g_bgBlocked 拦不住：
// 进后台时把本进程所有指向远端的 socket 直接 shutdown，让内核层面的收发停掉；
// 回前台后由 App 自己按常规网络错误重连（新连接此时已恢复放行）。
static void NG_closeRemoteSockets(void) {
    int maxfd = getdtablesize();
    if (maxfd <= 0) return;
    struct sockaddr_storage ss;
    socklen_t sl;
    for (int fd = 0; fd < maxfd; fd++) {
        sl = sizeof(ss);
        if (getpeername(fd, (struct sockaddr *)&ss, &sl) != 0) continue; // 未连接/非 socket
        if (NG_isLocal((struct sockaddr *)&ss)) continue;                // 本机通信放行
        shutdown(fd, SHUT_RDWR);
    }
}

// on=YES: 进后台 → 关闭已建立的远端连接并开始拒绝新连接；on=NO: 回前台 → 恢复
void NG_setBgBlocked(BOOL on) {
    g_bgBlocked = on;
    if (on) NG_closeRemoteSockets();
}

#pragma mark - Hook 实现

typedef int (*NG_connectx_t)(int, const sa_endpoints_t *, sae_associd_t, unsigned int,
                             const struct iovec *, unsigned int, size_t *, sae_connid_t *);
static NG_connectx_t NG_orig_connectx = NULL;

static int NG_connectx(int fd, const sa_endpoints_t *ep, sae_associd_t associd, unsigned int flags,
                       const struct iovec *iov, unsigned int iovcnt, size_t *len, sae_connid_t *connid) {
    if (NG_blocked() && ep && !NG_isLocal(ep->sae_dstaddr)) {
        errno = ECONNREFUSED;
        return -1;
    }
    return NG_orig_connectx(fd, ep, associd, flags, iov, iovcnt, len, connid);
}

typedef int (*NG_connect_t)(int, const struct sockaddr *, socklen_t);
static NG_connect_t NG_orig_connect = NULL;

static int NG_connect(int fd, const struct sockaddr *addr, socklen_t addrlen) {
    if (NG_blocked() && !NG_isLocal(addr)) {
        errno = ECONNREFUSED;
        return -1;
    }
    return NG_orig_connect(fd, addr, addrlen);
}

typedef ssize_t (*NG_sendto_t)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static NG_sendto_t NG_orig_sendto = NULL;

static ssize_t NG_sendto(int fd, const void *buf, size_t len, int flags,
                         const struct sockaddr *dst, socklen_t dstlen) {
    if (NG_blocked() && dst && !NG_isLocal(dst)) {
        errno = ENETUNREACH;
        return -1;
    }
    return NG_orig_sendto(fd, buf, len, flags, dst, dstlen);
}

typedef ssize_t (*NG_sendmsg_t)(int, const struct msghdr *, int);
static NG_sendmsg_t NG_orig_sendmsg = NULL;

static ssize_t NG_sendmsg(int fd, const struct msghdr *msg, int flags) {
    if (NG_blocked() && msg && msg->msg_name &&
        !NG_isLocal((const struct sockaddr *)msg->msg_name)) {
        errno = ENETUNREACH;
        return -1;
    }
    return NG_orig_sendmsg(fd, msg, flags);
}

#pragma mark - 取 MSHookFunction（substrate / ElleKit）

typedef void (*NG_MSHookFunction_t)(void *, void *, void **);

static NG_MSHookFunction_t NG_hookFunction(void) {
    static NG_MSHookFunction_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // rootless(ElleKit) 与 rootful 两条路径都试一遍
        const char *paths[] = {
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/usr/lib/libsubstrate.dylib",
            "/usr/lib/libellekit.dylib",
        };
        for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !fn; i++) {
            void *h = dlopen(paths[i], RTLD_NOW);
            if (h) fn = (NG_MSHookFunction_t)dlsym(h, "MSHookFunction");
        }
        if (!fn) fn = (NG_MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    });
    return fn;
}

__attribute__((constructor)) static void NG_init(void) {
    @autoreleasepool {
        // 注入范围由 Tweak.plist 决定(SpringBoard + 含 UNUserNotificationCenter 的 App 进程)。
        // 这里统一装 hook，是否拦截完全由 g_blocked 决定，未配置断网的进程行为不变。
        NG_refresh();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        NG_onConfigChanged,
                                        (__bridge CFStringRef)kNGChanged, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        NG_MSHookFunction_t hook = NG_hookFunction();
        if (!hook) return; // 没有 hook 框架就保持原样，避免崩溃

        void *sym = NULL;
        if ((sym = dlsym(RTLD_DEFAULT, "connectx")))
            hook(sym, (void *)NG_connectx, (void **)&NG_orig_connectx);
        if ((sym = dlsym(RTLD_DEFAULT, "connect")))
            hook(sym, (void *)NG_connect, (void **)&NG_orig_connect);
        if ((sym = dlsym(RTLD_DEFAULT, "sendto")))
            hook(sym, (void *)NG_sendto, (void **)&NG_orig_sendto);
        if ((sym = dlsym(RTLD_DEFAULT, "sendmsg")))
            hook(sym, (void *)NG_sendmsg, (void **)&NG_orig_sendmsg);
    }
}