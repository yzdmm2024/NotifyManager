#import <Foundation/Foundation.h>

@interface AppUsage : NSObject
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic) double screenOnTime;    // 秒
@property (nonatomic) double backgroundTime;  // 秒
@end

@interface HourlyUsage : NSObject
@property (nonatomic, copy) NSString *label;  // 如 "08-25 14:00"
@property (nonatomic) NSInteger appCount;
@end

@interface BatteryData : NSObject
@property (nonatomic) NSInteger currentLevel;      // 当前电量 %
@property (nonatomic, strong) NSDate *lastChargeEnd; // 上次充电结束时间
@property (nonatomic) NSInteger chargeEndLevel;    // 上次充电结束时的电量 %
@property (nonatomic, strong) NSArray<AppUsage *> *appUsages;
@property (nonatomic, strong) NSArray<HourlyUsage *> *hourlyUsages;
@property (nonatomic, strong) NSArray<NSString *> *relatedFiles; // 扫描到的所有相关文件
@property (nonatomic) NSInteger cycleCount;        // 电池循环次数
@property (nonatomic) NSInteger maxCapacity;       // 最大容量 mAh
@property (nonatomic) NSInteger designCapacity;    // 设计容量 mAh
@property (nonatomic, strong) NSArray<NSDictionary *> *selfHistory; // 自记录电量历史
@property (nonatomic, copy) NSString *errorMessage;
+ (instancetype)shared;
- (void)loadData;
@end
