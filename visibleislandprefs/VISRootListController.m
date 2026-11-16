#import <Foundation/Foundation.h>
#include "VISRootListController.h"
#include <sys/sysctl.h>
#import <UIKit/UIKit.h>


static void VIPostUpdate(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ethxnn88.visibleislandprefs-updated"),
                                         NULL, NULL, YES);
}

@implementation VISRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
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

+ (NSString *)deviceModel {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;

    char *machine = (char *)malloc(size);
    if (!machine) return nil;

    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == -1) {
        free(machine);
        return nil;
    }

    NSString *deviceModel = [NSString stringWithUTF8String:machine];
    free(machine);
    return deviceModel;
}

// 把 ArtworkDeviceSubType 改成灵动岛机型的值（2556），系统才会渲染灵动岛
+ (BOOL)writeArtworkSubtype:(int)subtype {
    NSString *plistPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";

    NSMutableDictionary *plistDictionary = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plistDictionary) {
        return NO;
    }

    NSMutableDictionary *cacheExtraDictionary = plistDictionary[@"CacheExtra"];
    if (!cacheExtraDictionary) {
        cacheExtraDictionary = [NSMutableDictionary dictionary];
        plistDictionary[@"CacheExtra"] = cacheExtraDictionary;
    }

    NSMutableDictionary *nestedDictionary = cacheExtraDictionary[@"oPeik/9e8lQWMszEjbPzng"];
    if (!nestedDictionary) {
        nestedDictionary = [NSMutableDictionary dictionary];
        cacheExtraDictionary[@"oPeik/9e8lQWMszEjbPzng"] = nestedDictionary;
    }

    nestedDictionary[@"ArtworkDeviceSubType"] = @(subtype);

    return [plistDictionary writeToFile:plistPath atomically:YES];
}

+ (void)fixUnsupported {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"该机型暂无官方偏移量"
                         message:@"VisibleIsland 还没有为这台设备实测过偏移量，用「自动修正」可能对不齐。建议改用「自定义位置」，或者打开「测试模式」直接拖动调。"
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];

    UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    if (rootViewController) {
        [rootViewController presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - 按钮动作

- (void)applyNow {
    [self.view endEditing:YES];
    VIPostUpdate();
}

- (void)sourceCode {
    NSURL *url = [NSURL URLWithString:@"https://github.com/ethxnn88/VisibleIsland"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)twitter {
    NSURL *url = [NSURL URLWithString:@"https://twitter.com/ethxnn88"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - 开关联动

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];

    if ([key isEqualToString:@"islandEnabled"]) {
        if ([value boolValue]) {
            [VISRootListController writeArtworkSubtype:2556];
        } else {
            [VISRootListController writeArtworkSubtype:0];
        }
    } else if ([key isEqualToString:@"fixEnabled"]) {
        if ([value boolValue]) {
            NSString *deviceModel = [VISRootListController deviceModel];
            NSArray *supportedModels = @[@"iPhone10,3", @"iPhone10,6", @"iPhone11,2", @"iPhone12,3",
                                         @"iPhone11,6", @"iPhone12,5", @"iPhone11,8", @"iPhone12,1",
                                         @"iPhone14,2", @"iPhone14,5", @"iPhone14,7",
                                         @"iPhone14,3", @"iPhone14,4"];
            if (![supportedModels containsObject:deviceModel]) {
                [VISRootListController fixUnsupported];
            }
        }
    }
}

@end
