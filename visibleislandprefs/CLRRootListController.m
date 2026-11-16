#import <Foundation/Foundation.h>
#include "CLRRootListController.h"
#import <UIKit/UIKit.h>

static NSString *const kVIDomain = @"com.ethxnn88.visibleislandprefs";

static void VIPostUpdate(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ethxnn88.visibleislandprefs-updated"),
                                         NULL, NULL, YES);
}

@implementation CLRRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Color" target:self];
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

- (void)resetColor {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kVIDomain];
    [d setFloat:0.0f forKey:@"red"];
    [d setFloat:0.0f forKey:@"green"];
    [d setFloat:0.0f forKey:@"blue"];
    [d setFloat:1.0f forKey:@"alpha"];
    [d synchronize];

    [self reloadSpecifiers];
    VIPostUpdate();
}

@end
