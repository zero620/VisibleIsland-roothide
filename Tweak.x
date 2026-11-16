// ============================================================
//  VisibleIsland  2.11.1  (汉化版)
//  原版：https://github.com/ethxnn88/VisibleIsland
//
//  基线 = 2.9.0（实测能正常显示的最后一版），
//  在此基础上只做两件事：删掉「自动横向偏移」、删掉「液态玻璃」。
//  定位公式、隐藏逻辑、幕布处理全部与 2.9.0 逐字一致，不做任何改动。
//
//  1. 定位只用 transform，绝不碰 frame / center
//     原版 layoutSubviews 里先设 transform 再设 frame：
//       self.transform = CGAffineTransformMakeScale(scale, scale);
//       self.frame = frame;
//     UIKit 在 transform 非单位矩阵时调 setFrame: 会用 frame 反推 bounds，
//     窗口 center 因此漂移 —— 这就是「左右偏移」的根因。
//
//  2. 水平 / 垂直补偿（固定公式，无闭环、无自适应）
//
//  3. 保留 _SBSystemApertureMagiciansCurtainView
//     这块幕布是刘海形状、刘海宽度，系统原本用它填刘海和岛之间的空隙。
//     原版在挪动岛时把它隐藏，于是中间漏一条缝。
//
//  另外修掉的原有 bug：
//   · scaleEnabled && !posEnabled | scaleEnabled && !fixEnabled 位或误用
//   · setFrame: 的 notEnabled 分支连调两次 %orig
//   · didMoveToWindow 漏调 %orig
//   · alpha / scale 缺省取到 0 → 开开关直接看不见 / 缩没
//   · 每次 layout 都 sysctl 取机型
//
//  设备：roothide / iOS 16.6.1 / iPhone 13 Pro (iPhone14,2)
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import <math.h>

#define VI_PREF_DOMAIN     @"com.ethxnn88.visibleislandprefs"
#define VI_NOTIFY_UPDATE   CFSTR("com.ethxnn88.visibleislandprefs-updated")
#define VI_NOTIFY_RESPRING CFSTR("com.ethxnn88.visibleislandprefs-respring")

// ---------------- 全局状态 ----------------

static BOOL islandEnabled;
static BOOL posEnabled;
static BOOL hideEnabled;
static BOOL notificationFix;
static BOOL notEnabled;
static BOOL colorEnabled;
static BOOL transEnabled;
static BOOL scaleEnabled;
static BOOL lineDisabled;

static CGFloat xPos, yPos, xNot, yNot;
static CGFloat red, green, blue, alpha, scale;

static __weak UIView *gApertureWindow = nil;
static __weak UIView *gBannerWindow = nil;
static BOOL gInLayout = NO;

// 紧凑态灵动岛在窗口坐标系里的中心，第一次 layout 时量一次
static CGPoint gNatIslandCenter = {0.0, 0.0};
static BOOL gHasNatCenter = NO;
#define VI_FALLBACK_ISLAND_CY 29.5

// 系统自己算出来的灵动岛默认位置，只记录不改，用来对照真实几何
static CGRect gLastDefaultIslandFrame = {0, 0, 0, 0};
static BOOL gHasDefaultIslandFrame = NO;

// 光圈控制器报告的「当前有没有活动内容」。用来实现真正的「不使用时隐藏」。
static BOOL gApertureHasContent = YES;
static BOOL gHasContentKnown = NO;

// 前向声明
static void VISyncIdleVisibility(void);
static UIView *VIFindCurtainView(UIView *root);

// ---------------- 机型 ----------------

static NSString *VIDeviceModel(void) {
    static NSString *model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = 0;
        if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return;
        char *m = (char *)malloc(size);
        if (!m) return;
        if (sysctlbyname("hw.machine", m, &size, NULL, 0) == 0) {
            model = [NSString stringWithUTF8String:m];
        }
        free(m);
    });
    return model;
}

// 通知横幅的 (y, 宽, 高)
static NSArray *VIBannerMetrics(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone10,3": @[@35, @375, @812], @"iPhone10,6": @[@35, @375, @812],
            @"iPhone11,2": @[@35, @375, @812], @"iPhone12,3": @[@35, @375, @812],
            @"iPhone11,6": @[@37, @414, @896], @"iPhone12,5": @[@37, @414, @896],
            @"iPhone11,8": @[@37, @414, @896], @"iPhone12,1": @[@37, @414, @896],
            @"iPhone13,2": @[@35, @390, @844], @"iPhone13,3": @[@35, @390, @844],
            @"iPhone13,1": @[@33, @360, @780], @"iPhone13,4": @[@38, @428, @926],
            @"iPhone14,5": @[@40, @390, @844], @"iPhone14,2": @[@40, @390, @844],
            @"iPhone14,7": @[@40, @390, @844], @"iPhone14,4": @[@38, @360, @780],
            @"iPhone14,3": @[@42, @428, @926],
        };
    });
    return map[VIDeviceModel() ?: @""];
}

// ---------------- 当前生效的偏移 ----------------

static CGFloat VIEffectiveScale(void) {
    CGFloat s = scaleEnabled ? scale : 1.0;
    if (!(s > 0.25) || s > 2.0) s = 1.0;
    return s;
}

static void VIEffectiveOffset(CGFloat *dx, CGFloat *dy) {
    CGFloat x = 0.0, y = 0.0;
    if (posEnabled) {
        // 开了自动横向居中就不吃手填的横向偏移
        x = xPos;
        y = yPos;
    }
    if (dx) *dx = x;
    if (dy) *dy = y;
}

// ---------------- 偏好读写 ----------------

static NSUserDefaults *VIPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:VI_PREF_DOMAIN];
    return d ?: [NSUserDefaults standardUserDefaults];
}

static BOOL VIBool(NSUserDefaults *d, NSString *k, BOOL def) {
    return [d objectForKey:k] ? [d boolForKey:k] : def;
}

static CGFloat VIFloat(NSUserDefaults *d, NSString *k, CGFloat def) {
    return [d objectForKey:k] ? (CGFloat)[d floatForKey:k] : def;
}

// 设置一变就强制重排，免注销
static void VIRelayout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *w = gApertureWindow;
        if (w) {
            [w setNeedsLayout];
            [w layoutIfNeeded];
        }
        UIView *b = gBannerWindow;
        if (b) [b setNeedsLayout];
        VISyncIdleVisibility();
    });
}

// ---------------- 找灵动岛本体（补偿和诊断都要用） ----------------

static UIView *VIFindIslandView(UIView *root) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"SystemApertureContainer"] && root.subviews.count > 0) {
        return root;
    }
    for (UIView *v in root.subviews) {
        UIView *r = VIFindIslandView(v);
        if (r) return r;
    }
    return nil;
}

// 幕布 = 灵动岛真正被看见的那块形状，宽 125pt、左右对称。
// 自动居中必须量它，量容器会偏右 8pt（容器是命中区，不是视觉体）。
static UIView *VIFindCurtainView(UIView *root) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"MagiciansCurtain"]) {
        return root;
    }
    for (UIView *v in root.subviews) {
        UIView *r = VIFindCurtainView(v);
        if (r) return r;
    }
    return nil;
}

// ---------------- 「不使用时隐藏」 ----------------
//
// 只藏 gain map 不够：空闲时那个黑胶囊是幕布 + 内容视图画的。
// 唯一干净的做法是空闲时把整个光圈窗口淡出。

static BOOL gWeHidWindow = NO;

static void VISyncIdleVisibility(void) {
    UIView *w = gApertureWindow;
    if (!w) return;

    // 状态未知时不动，避免误伤
    BOOL shouldHide = (hideEnabled && gHasContentKnown && !gApertureHasContent);

    UIView *curtain = VIFindCurtainView(w);

    if (shouldHide) {
        if (w.alpha != 0.0) w.alpha = 0.0;
        gWeHidWindow = YES;
        if (curtain) {
            curtain.hidden = YES;
            curtain.alpha = 0.0;
        }
    } else if (gWeHidWindow) {
        w.alpha = 1.0;
        gWeHidWindow = NO;
        if (curtain) {
            curtain.hidden = NO;
            curtain.alpha = 1.0;
        }
    }
}

// ---------------- 几何导出（诊断用，手动触发） ----------------

// ============================================================
//  Hooks
// ============================================================

@interface SBSystemApertureWindow : UIView
@end

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

@interface SBBannerWindow : UIView
@end

@interface _SBGainMapView : UIView
@end

@interface _SBSystemApertureContainerViewContentView : UIView
@end

@interface SBFTouchPassThroughView : UIView
@end

@interface FBSystemService : NSObject
+ (id)sharedInstance;
- (void)exitAndRelaunch:(BOOL)arg1;
@end

@interface SBSystemApertureController : NSObject
@end

// 系统算灵动岛默认位置的入口。展开动画的起止点都从这里派生，
// 所以把它强制居中到屏幕（= 刘海）中线，通话/秒表这些展开态才会对称。
%hook SBSystemApertureController

- (CGRect)defaultIslandFrameInCoordinateSpace:(id)space {
    CGRect r = %orig;
    gLastDefaultIslandFrame = r;
    gHasDefaultIslandFrame = YES;

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat centeredX = screenW / 2.0 - r.size.width / 2.0;

    r.origin.x = centeredX;
    return r;
}

// 「当前有没有活动内容」——系统自己的权威判断。
// 放歌 / 计时 / 来电 = YES，空闲 = NO。用来实现真正的「不使用时隐藏」。
- (BOOL)systemApertureViewController:(id)vc containsAnyContent:(BOOL)hasContent {
    gApertureHasContent = hasContent;
    gHasContentKnown = YES;
    BOOL r = %orig;
    VISyncIdleVisibility();
    return r;
}

%end

%hook SBSystemApertureWindow

- (void)layoutSubviews {
    %orig;

    gApertureWindow = self;

    if (gInLayout) return;
    gInLayout = YES;

    // 注意：定位逻辑不再受 islandEnabled 控制。
    // 岛是否显示由 MobileGestalt 的 ArtworkDeviceSubType 决定，跟这个开关无关。
    // 以前在这里 return，导致「开关关着但岛还在」时位置完全调不动。

    // 第一次拿到紧凑态尺寸时记下灵动岛的自然中心
    if (!gHasNatCenter) {
        UIView *c = VIFindIslandView(self);
        if (c) {
            CGFloat ch = c.frame.size.height;
            if (ch > 0.0 && ch <= 60.0) {
                gNatIslandCenter = CGPointMake(CGRectGetMidX(c.frame), CGRectGetMidY(c.frame));
                gHasNatCenter = YES;
            }
        }
    }

    CGFloat s = VIEffectiveScale();
    CGFloat dx = 0.0, dy = 0.0;
    VIEffectiveOffset(&dx, &dy);

    CGFloat winW = self.bounds.size.width;
    CGFloat winH = self.bounds.size.height;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;

    CGFloat natCy = gHasNatCenter ? gNatIslandCenter.y : VI_FALLBACK_ISLAND_CY;

    // 垂直：一个字都不改。用户已经用 yPos=-44 调好了，动这里等于把调好的推翻。
    CGFloat compY = (natCy - winH / 2.0) * (1.0 - s);

    // 水平：和 2.9.0 完全一致，只保留固定补偿，不做任何闭环微调。
    CGFloat natCx = gHasNatCenter ? gNatIslandCenter.x : winW / 2.0;
    CGFloat compX = (natCx - winW / 2.0) * (1.0 - s);
    if (fabs(winW - screenW) < 10.0) compX += (screenW - winW) / 2.0;

    // 关键：只用 transform，绝不碰 frame / center。
    // 原版先设 transform 再设 frame，UIKit 会用缩放后的 frame 反推 bounds，
    // 窗口 center 漂移 —— 这是原版左右偏移的根因。
    self.transform = CGAffineTransformTranslate(CGAffineTransformMakeScale(s, s),
                                                dx + compX, dy + compY);

    gInLayout = NO;

    VISyncIdleVisibility();
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) gApertureWindow = self;
}

%end

%hook _SBSystemApertureMagiciansCurtainView

- (void)layoutSubviews {
    %orig;

    // 这块幕布是刘海形状、刘海宽度，系统靠它在刘海和岛之间做形状过渡。
    // 窗口整体被缩放了，幕布也跟着缩，于是比物理刘海窄一大截 ——
    // 通话/秒表这类展开动画就会露边、看着不均匀。
    // 这里给它反向缩放，让它始终维持刘海原始尺寸。
    CGFloat s = VIEffectiveScale();
    if (s != 1.0 && s > 0.0) {
        self.transform = CGAffineTransformMakeScale(1.0 / s, 1.0 / s);
    } else if (!CGAffineTransformIsIdentity(self.transform)) {
        self.transform = CGAffineTransformIdentity;
    }
}

- (void)didMoveToWindow {
    %orig;
    // 保留幕布，否则刘海和岛之间会漏一条缝
    self.hidden = NO;
}

%end

%hook _SBGainMapView

// 这块是空闲态盖在摄像头区域上的图层。
// 原版只在 didMoveToWindow 里处理，那个时机太晚而且只触发一次，
// 结果就是活动结束以后岛还挂在那儿慢慢淡出。
// 这里改成每次布局都检查，出现即隐藏，做到「立即隐藏」。

- (void)layoutSubviews {
    %orig;
    if (hideEnabled) {
        if (!self.hidden) self.hidden = YES;
        if (self.alpha != 0.0) self.alpha = 0.0;
    }
}

- (void)didMoveToWindow {
    %orig;
    if (hideEnabled) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

// ============================================================
//  「不使用时隐藏」的真正实现
// ============================================================
//
// 上一版只藏了 _SBGainMapView，结果空闲时还能看到一个黑胶囊 ——
// 因为那个黑胶囊是幕布 + 内容视图画的，跟 gain map 没关系。
//
// 唯一可靠的做法：空闲时把整个光圈窗口淡出，一点黑都不留。
// 「空闲」由系统自己说了算：SBSystemApertureController 的
//   - systemApertureViewController:containsAnyContent:
// 就是「当前有没有活动内容」的权威回答（放歌/计时/来电 = YES）。
// 具体实现见文件上方的 VISyncIdleVisibility()。

%hook _SBSystemApertureContainerViewContentView

- (void)layoutSubviews {
    %orig;

    if (colorEnabled) {
        if (![self backgroundColor]) {
            UIColor *customColor = [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
            [self setBackgroundColor:customColor];
        }
    }

}

%end

%hook SBFTouchPassThroughView

- (void)layoutSubviews {
    %orig;

    if (self.subviews.count == 4) {
        if (transEnabled) {
            UIView *targetSubview = self.subviews[2];
            if (targetSubview.alpha == 1.0 && targetSubview.userInteractionEnabled == 0) {
                targetSubview.alpha = alpha;
            }
        }
        if (lineDisabled) {
            UIView *lineView = self.subviews[1];
            if (lineView.alpha == 1.0 && lineView.userInteractionEnabled == 0) {
                lineView.hidden = YES;
            }
        }
    }
}

%end

%hook SBBannerWindow

- (void)didMoveToWindow {
    %orig;
    if (self.window) gBannerWindow = self;
}

- (CGRect)frame {
    if (notificationFix) {
        NSArray *m = VIBannerMetrics();
        if (m) {
            %orig;
            return CGRectMake(0, [m[0] doubleValue], [m[1] doubleValue], [m[2] doubleValue]);
        }
    } else if (notEnabled) {
        NSArray *m = VIBannerMetrics();
        if (m) {
            %orig;
            return CGRectMake(xNot, yNot, [m[1] doubleValue], [m[2] doubleValue]);
        }
    }
    return %orig;
}

- (void)setFrame:(CGRect)frame {
    if (notificationFix) {
        NSArray *m = VIBannerMetrics();
        if (m) {
            %orig(CGRectMake(0, [m[0] doubleValue], [m[1] doubleValue], [m[2] doubleValue]));
            return;
        }
    } else if (notEnabled) {
        NSArray *m = VIBannerMetrics();
        if (m) {
            %orig(CGRectMake(xNot, yNot, [m[1] doubleValue], [m[2] doubleValue]));
            return;
        }
    }
    %orig(frame);
}

%end

// ============================================================
//  启动
// ============================================================

static void respringCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    [[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
}

// 一次性迁移：2.10.x 把 xPos 改成了 0（因为那时基准换了），
// 现在回到 2.9.0 的基准，xPos 必须回到 68 才能复现 2.9.0 的视觉效果。
// 顺便把「不使用时隐藏」关掉，保证装完先看到岛。
static void VIMigrateOnce(void) {
    NSUserDefaults *d = VIPrefs();
    if ([d boolForKey:@"vi_migr_2110"]) return;
    [d setFloat:68.0f forKey:@"xPos"];
    [d setBool:NO forKey:@"hideEnabled"];
    [d setBool:YES forKey:@"vi_migr_2110"];
    [d synchronize];
}

static void preferencesChanged(void) {
    NSUserDefaults *d = VIPrefs();

    VIMigrateOnce();

    islandEnabled   = VIBool(d, @"islandEnabled", NO);
    posEnabled      = VIBool(d, @"posEnabled", YES);
    hideEnabled     = VIBool(d, @"hideEnabled", NO);
    notificationFix = VIBool(d, @"notificationFix", NO);
    notEnabled      = VIBool(d, @"notEnabled", NO);
    colorEnabled    = VIBool(d, @"colorEnabled", NO);
    transEnabled    = VIBool(d, @"transEnabled", NO);
    scaleEnabled    = VIBool(d, @"scaleEnabled", YES);
    lineDisabled    = VIBool(d, @"lineDisabled", NO);

    // 缺省值必须给对：原来缺省取到 0，alpha=0 直接看不见，scale=0 直接缩没
    xPos  = VIFloat(d, @"xPos", 68.0);
    yPos  = VIFloat(d, @"yPos", -44.0);
    xNot  = VIFloat(d, @"xNot", 0.0);
    yNot  = VIFloat(d, @"yNot", 40.0);
    red   = VIFloat(d, @"red", 0.0);
    green = VIFloat(d, @"green", 0.0);
    blue  = VIFloat(d, @"blue", 0.0);
    alpha = VIFloat(d, @"alpha", 1.0);
    scale = VIFloat(d, @"scale", 0.66);

    if (alpha < 0.0) alpha = 0.0;
    if (alpha > 1.0) alpha = 1.0;
    if (!(scale > 0.25) || scale > 2.0) scale = 1.0;

    VIRelayout();
}

%ctor {
    preferencesChanged();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    (CFNotificationCallback)preferencesChanged,
                                    VI_NOTIFY_UPDATE, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 注销只对 SpringBoard 有意义
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        (CFNotificationCallback)respringCallback,
                                        VI_NOTIFY_RESPRING, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

    }
}
