#import <Foundation/Foundation.h>

/// 与 Tweak 共享 NSUserDefaults suiteName 的存储层
/// 键格式: NTM_<dim>_<bundleId>  /  NTM_net_<bundleId>
/// Tweak 在 SpringBoard 中读取同一份配置，实现通知拦截
/// 同时通过 BBSettingsGateway / PSAppDataUsagePolicyCache 同步到系统设置
@interface StorageManager : NSObject

@property (nonatomic, class, readonly) NSString *suiteName;

+ (instancetype)shared;

/// 维度 key 列表
- (NSArray<NSDictionary *> *)allDims;
- (NSString *)dimKeyAtIndex:(NSInteger)index;
- (NSString *)dimTitleAtIndex:(NSInteger)index;

/// 读取/写入通知开关
- (BOOL)readEnabledForApp:(NSString *)appId dim:(NSString *)dim;
- (void)writeEnabled:(BOOL)enabled forApp:(NSString *)appId dim:(NSString *)dim;

/// 总开关快捷方法（联动所有子开关）
- (BOOL)readMasterForApp:(NSString *)appId;
- (void)writeMaster:(BOOL)enabled forApp:(NSString *)appId;

/// 网络策略
- (NSInteger)readNetPolicyForApp:(NSString *)appId;
- (void)writeNetPolicy:(NSInteger)policy forApp:(NSString *)appId;

/// 通知 Tweak 清空缓存
- (void)postConfigChanged;

/// 重置单应用为默认值（全部开启）
- (void)resetApp:(NSString *)appId;

/// 批量写入（含系统同步）
- (void)batchWrite:(BOOL)enabled forApps:(NSArray<NSString *> *)appIds netPolicy:(NSInteger)netPolicy;

/// 快照（用于批量操作恢复）
- (NSDictionary *)snapshotForApps:(NSArray<NSDictionary *> *)apps;
- (void)restoreSnapshot:(NSDictionary *)snapshot;

/// 导出/导入配置
- (NSArray *)exportConfigForAllApps:(NSArray<NSDictionary *> *)allApps;
- (NSInteger)importConfig:(NSArray *)config;

/// === 系统同步（TrollStore 下可用） ===

/// 同步单个 App 的通知设置到系统 BBSettingsGateway
- (void)syncSystemNotificationForApp:(NSString *)appId;

/// 同步单个 App 的蜂窝网络策略到系统 PSAppDataUsagePolicyCache
- (void)syncSystemCellularForApp:(NSString *)appId;

/// 后台异步同步
- (void)syncSystemNotificationAsync:(NSString *)appId;
- (void)syncSystemCellularAsync:(NSString *)appId policy:(NSInteger)policy;

@end