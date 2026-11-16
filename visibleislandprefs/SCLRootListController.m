#import <Foundation/Foundation.h>
#include "SCLRootListController.h"
#import <UIKit/UIKit.h>

static NSString *const kVIDomain = @"com.ethxnn88.visibleislandprefs";

static void VIPostUpdate(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ethxnn88.visibleislandprefs-updated"),
                                         NULL, NULL, YES);
}

@implementation SCLRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Scale" target:self];
	}

	return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIBarButtonItem *respring = [[UIBarButtonItem alloc] initWithTitle:@"注销"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(respringAsk:)];
    self.navigationItem.rightBarButtonItem = respring;
}

- (void)respringAsk:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"注销主屏幕"
                         message:@"即将注销主屏幕，屏幕会黑一下然后回到锁屏。"
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"注销"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                [self respring];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respring {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ethxnn88.visibleislandprefs-respring"),
                                         NULL, NULL, YES);
}

// 预设按钮用无参方法，避免 Preferences 调用约定差异带来的风险
- (void)applyScale:(float)value {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kVIDomain];
    [d setFloat:value forKey:@"scale"];
    [d setBool:YES forKey:@"scaleEnabled"];
    [d synchronize];

    [self reloadSpecifiers];
    VIPostUpdate();
}

- (void)preset085 { [self applyScale:0.85f]; }
- (void)preset092 { [self applyScale:0.92f]; }
- (void)preset100 { [self applyScale:1.00f]; }
- (void)preset110 { [self applyScale:1.10f]; }

@end
