#import <UIKit/UIKit.h>

@interface AppCardView : UIView

@property (nonatomic, copy, readonly) NSString *appId;
@property (nonatomic, copy) void (^onValueChanged)(NSString *appId);

- (instancetype)initWithApp:(NSDictionary *)app;
- (void)reloadFromPrefs;

@end