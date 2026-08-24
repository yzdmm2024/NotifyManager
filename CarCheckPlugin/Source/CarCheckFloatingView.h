#import <UIKit/UIKit.h>

@interface CarCheckFloatingView : UIWindow

+ (instancetype)sharedView;
- (void)show;
- (void)hide;

@end