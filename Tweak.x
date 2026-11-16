// ============================================================
//  VisibleIsland  2.10.1  (汉化版)
//  原版：https://github.com/ethxnn88/VisibleIsland
//
//  本版 = 原版功能 + 全量汉化 + 位置/隐藏修复。
//
//  1. 定位只用 transform，绝不碰 frame / center
//     原版 layoutSubviews 里先设 transform 再设 frame：
//       self.transform = CGAffineTransformMakeScale(scale, scale);
//       self.frame = frame;
//     UIKit 在 transform 非单位矩阵时调 setFrame: 会用 frame 反推 bounds，
//     窗口 center 因此漂移 —— 这就是「左右偏移」的根因。
//
//  2. 位置基准取「幕布」而不是容器
//     _SBSystemApertureMagiciansCurtainView 是灵动岛被看见的那块形状
//     （125pt、左右对称）；SBSystemApertureContainerView 是左右不对称的
//     命中区，中心比岛心偏右 8pt。拿容器当基准就会稳定偏右。
//
//  3. 保留 _SBSystemApertureMagiciansCurtainView
//     这块幕布是刘海形状、刘海宽度，系统原本用它填刘海和岛之间的空隙。
//     原版在挪动岛时把它隐藏，于是中间漏一条缝。
//
//  4. 「不使用时隐藏」做在视觉层
//     空闲判定用幕布尺寸（最小态 125×36.67），有活动时幕布会长出去。
//     只藏幕布 / 内容层 / gain map，绝不碰窗口 alpha ——
//     压窗口 alpha 一旦判错就是整个岛消失，没法恢复。
//     写的时候关掉隐式动画，立即生效。
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
#define VI_NOTIFY_DUMP     CFSTR("com.ethxnn88.visibleislandprefs-dump")
#define VI_DUMP_PATH       @"/var/mobile/visibleisland_geom.txt"

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

// 「不使用时隐藏」
//   gShouldHideIsland —— 当前是否处于「已隐藏空闲胶囊」状态
// 判定完全由幕布尺寸推出来，每一帧重算，没有锁存、没有定时器。
static BOOL gShouldHideIsland = NO;

// 前向声明
static void VISyncIdleVisibility(void);
static void VIApplyIdleHidden(BOOL hide);
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
// 它的中心就是灵动岛的视觉中心；SBSystemApertureContainerView 是左右不对称的
// 命中区（中心比岛心偏右 8pt），不能拿来当位置基准。
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
// 判定用纯几何：灵动岛最小态就是一块 125 × 36.67 的胶囊，
// 有活动时（放歌 / 计时 / 来电）幕布会横向或纵向长出去。
// 「幕布还停在最小尺寸」= 空闲。
//
// 这里刻意不用 SBSystemApertureController 的 containsAnyContent: ——
// 那个方法签名吃不准，参数读错就永远是「没内容」，
// 整个窗口被压成 alpha 0 —— 2.10.0 就是这么把岛弄没的。
//
// 也绝不碰窗口 alpha。只藏「看得见的那几层」，判错最多是岛不显示，
// 窗口本身还活着，下一帧幕布尺寸一变就自动恢复。

#define VI_MINIMAL_W 132.0
#define VI_MINIMAL_H 42.0

static BOOL VIIslandIsIdle(UIView *window) {
    UIView *curtain = VIFindCurtainView(window);
    if (!curtain) return NO;          // 找不到幕布就不藏，宁可不藏也别弄没
    CGSize sz = curtain.bounds.size;
    if (sz.width <= 0.0 || sz.height <= 0.0) return NO;
    return (sz.width <= VI_MINIMAL_W && sz.height <= VI_MINIMAL_H);
}

// 内容层（真正画东西的那一层）。隐藏只动它，不动容器 ——
// 容器还兼着触摸命中区，动了容易把交互一起弄坏。
static UIView *VIFindContentView(UIView *root) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"ContainerViewContentView"]) return root;
    for (UIView *v in root.subviews) {
        UIView *r = VIFindContentView(v);
        if (r) return r;
    }
    return nil;
}

static void VIApplyIdleHidden(BOOL hide) {
    UIView *w = gApertureWindow;
    if (!w) return;

    UIView *curtain = VIFindCurtainView(w);
    UIView *content = VIFindContentView(w);
    CGFloat a = hide ? 0.0 : 1.0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];   // 立即生效，不等 0.25s 淡出
    if (curtain) {
        if (curtain.hidden != hide) curtain.hidden = hide;
        if (fabs(curtain.alpha - a) > 0.001) curtain.alpha = a;
    }
    if (content) {
        if (fabs(content.alpha - a) > 0.001) content.alpha = a;
    }
    [CATransaction commit];
}

static void VISyncIdleVisibility(void) {
    if (!gApertureWindow) return;

    BOOL hide = (hideEnabled && VIIslandIsIdle(gApertureWindow));

    if (hide == gShouldHideIsland) {
        // 状态没变，但系统可能在动画里把东西写回来了，补一刀
        if (hide) {
            UIView *curtain = VIFindCurtainView(gApertureWindow);
            UIView *content = VIFindContentView(gApertureWindow);
            if ((curtain && !curtain.hidden) || (content && content.alpha > 0.01)) {
                VIApplyIdleHidden(YES);
            }
        }
        return;
    }

    gShouldHideIsland = hide;
    VIApplyIdleHidden(hide);
}

// ---------------- 几何导出（诊断用，手动触发） ----------------

static void VIDumpView(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 7) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" "
                                   startingAtIndex:0];
    [out appendFormat:@"%@%@ f=%@ b=%@ hid=%d a=%.2f t=%@\n",
                      pad,
                      NSStringFromClass([v class]),
                      NSStringFromCGRect(v.frame),
                      NSStringFromCGRect(v.bounds),
                      (int)v.hidden,
                      (double)v.alpha,
                      CGAffineTransformIsIdentity(v.transform) ? @"id" : NSStringFromCGAffineTransform(v.transform)];
    for (UIView *sub in v.subviews) {
        VIDumpView(sub, depth + 1, out);
    }
}

static void VIDumpMethods(NSString *cls, NSMutableString *out) {
    Class c = NSClassFromString(cls);
    if (!c) {
        [out appendFormat:@"\n[class %@] 不存在\n", cls];
        return;
    }
    [out appendFormat:@"\n[class %@]\n  方法:\n", cls];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n && i < 250; i++) {
        [out appendFormat:@"    - %s\n", sel_getName(method_getName(ms[i]))];
    }
    free(ms);

    unsigned int pn = 0;
    objc_property_t *ps = class_copyPropertyList(c, &pn);
    [out appendString:@"  属性:\n"];
    for (unsigned int i = 0; i < pn && i < 250; i++) {
        [out appendFormat:@"    %s\n", property_getName(ps[i])];
    }
    free(ps);
}

static void VIDumpGeometry(void) {
    @try {
        NSMutableString *out = [NSMutableString string];
        UIScreen *sc = [UIScreen mainScreen];

        [out appendFormat:@"===== VisibleIsland 几何导出 %@ =====\n", [NSDate date]];
        [out appendFormat:@"device=%@\n", VIDeviceModel() ?: @"?"];
        [out appendFormat:@"screen bounds=%@ scale=%.2f\n",
                          NSStringFromCGRect(sc.bounds), (double)sc.scale];
        [out appendFormat:@"状态: island=%d pos=%d scaleEn=%d scale=%.2f x=%.1f y=%.1f hide=%d hiding=%d idle=%d\n",
                          islandEnabled, posEnabled, scaleEnabled,
                          (double)scale, (double)xPos, (double)yPos,
                          hideEnabled, gShouldHideIsland,
                          gApertureWindow ? VIIslandIsIdle(gApertureWindow) : -1];
        [out appendFormat:@"自然岛中心: has=%d (%.1f, %.1f)\n",
                          gHasNatCenter,
                          (double)gNatIslandCenter.x,
                          (double)gNatIslandCenter.y];
        [out appendFormat:@"系统默认岛位置: has=%d %@\n",
                          gHasDefaultIslandFrame,
                          gHasDefaultIslandFrame ? NSStringFromCGRect(gLastDefaultIslandFrame) : @"<未取到>"];

        [out appendString:@"\n----- 窗口栈 -----\n"];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            [out appendFormat:@"%@ level=%.1f f=%@ hid=%d root=%@\n",
                              NSStringFromClass([w class]),
                              (double)w.windowLevel,
                              NSStringFromCGRect(w.frame),
                              (int)w.hidden,
                              NSStringFromClass([[w rootViewController] class])];
        }

        [out appendString:@"\n----- 光圈窗口视图树 -----\n"];
        UIView *aw = gApertureWindow;
        if (aw) {
            [out appendFormat:@"window center=%@ bounds=%@\n",
                              NSStringFromCGPoint(aw.center),
                              NSStringFromCGRect(aw.bounds)];
            VIDumpView(aw, 0, out);
        } else {
            [out appendString:@"gApertureWindow 为 nil\n"];
        }

        [out appendString:@"\n----- 状态栏窗口 -----\n"];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSString *cn = NSStringFromClass([w class]);
            if ([cn containsString:@"Status"]) VIDumpView(w, 0, out);
        }

        VIDumpMethods(@"SBSystemApertureController", out);
        VIDumpMethods(@"SBSystemApertureSettings", out);
        VIDumpMethods(@"SBSystemApertureWindow", out);
        VIDumpMethods(@"_SBSystemApertureContainerViewContentView", out);
        VIDumpMethods(@"_SBSystemApertureMagiciansCurtainView", out);

        NSError *err = nil;
        BOOL ok = [out writeToFile:VI_DUMP_PATH
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&err];
        NSLog(@"[VisibleIsland] 几何导出 %@ -> %@ (%lu 字节)%@",
              ok ? @"成功" : @"失败", VI_DUMP_PATH, (unsigned long)out.length,
              err ? [NSString stringWithFormat:@" err=%@", err.localizedDescription] : @"");
    } @catch (NSException *e) {
        NSLog(@"[VisibleIsland] 几何导出异常 %@", e.reason);
    }
}

static void VIDumpCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VIDumpGeometry();
    });
}

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

    NSLog(@"[VisibleIsland] defaultIslandFrame %@ -> x=%.2f (screenW=%.1f) space=%@",
          NSStringFromCGRect(r), (double)centeredX, (double)screenW, space);

    r.origin.x = centeredX;
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

    // 第一次拿到紧凑态尺寸时记下灵动岛的自然中心。
    // 必须量幕布，不能量 SBSystemApertureContainerView ——
    // 后者是左右不对称的命中区，中心比岛心偏右 8pt，
    // 拿它当基准就会稳定偏右（上一版「有点偏右」就是这么来的）。
    if (!gHasNatCenter) {
        UIView *c = VIFindCurtainView(self) ?: VIFindIslandView(self);
        if (c) {
            CGFloat ch = c.bounds.size.height;
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

    CGFloat natCx = gHasNatCenter ? gNatIslandCenter.x : winW / 2.0;
    CGFloat natCy = gHasNatCenter ? gNatIslandCenter.y : VI_FALLBACK_ISLAND_CY;

    // 补偿：让岛在缩放时原地不动。
    //
    // 推导：窗口未变换时岛在屏幕上的位置 = center - bounds/2 + natC。
    // 变换后视觉中心 = center + (natC - bounds/2) * s + t。
    // 要求「视觉中心 = 自然位置 + 用户偏移」，解出
    //   t = offset + (natC - bounds/2) * (1 - s)
    //
    // natC 取幕布中心（≈ 窗口中心），所以 compX ≈ 0，
    // 「横向偏移 0」就是正中，正数向右。
    CGFloat compX = (natCx - winW / 2.0) * (1.0 - s);
    CGFloat compY = (natCy - winH / 2.0) * (1.0 - s);

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
    // 保留幕布，否则刘海和岛之间会漏一条缝。
    // 空闲隐藏状态下不要再把它打开，否则藏了等于没藏。
    if (gShouldHideIsland) {
        self.hidden = YES;
        self.alpha = 0.0;
    } else {
        self.hidden = NO;
        self.alpha = 1.0;
    }
}

%end

%hook _SBGainMapView

// 这块是空闲态盖在摄像头区域上的图层。
// 原版只在 didMoveToWindow 里处理，那个时机太晚而且只触发一次，
// 结果就是活动结束以后岛还挂在那儿慢慢淡出。
// 现在跟着「空闲隐藏」的裁决走，出现即藏。

- (void)layoutSubviews {
    %orig;
    if (gShouldHideIsland) {
        if (!self.hidden) self.hidden = YES;
        if (self.alpha != 0.0) self.alpha = 0.0;
    } else if (hideEnabled) {
        // 不在空闲态就别乱动，交还给系统
        if (self.hidden) self.hidden = NO;
        if (self.alpha != 1.0) self.alpha = 1.0;
    }
}

- (void)didMoveToWindow {
    %orig;
    if (gShouldHideIsland) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

// ============================================================
//  内容层颜色
// ============================================================
//
// 「不使用时隐藏」的具体实现见文件上方的 VISyncIdleVisibility() /
// VIApplyIdleHidden()。判定靠幕布尺寸，不碰窗口 alpha。

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

// 一次性迁移
//
// 1) 2.8 之前 xPos=68 是为了补「基准量错」的 bug，现在基准改成幕布中心，
//    「横向偏移 0」才是正中。不清掉旧值会直接右移 68pt。
// 2) 2.10.0 的隐藏逻辑把窗口 alpha 压成 0 且再也回不来，升级后先把
//    「不使用时隐藏」关掉，确认岛回来，再让用户自己决定要不要开。
static void VIMigrateOnce(void) {
    NSUserDefaults *d = VIPrefs();

    if (![d boolForKey:@"vi_migr_290"]) {
        [d setFloat:0.0f forKey:@"xPos"];
        [d setBool:YES forKey:@"vi_migr_290"];
    }
    if (![d boolForKey:@"vi_migr_2101"]) {
        [d setBool:NO forKey:@"hideEnabled"];
        [d setBool:YES forKey:@"vi_migr_2101"];
    }
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
    xPos  = VIFloat(d, @"xPos", 0.0);
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

    // 关掉「不使用时隐藏」时立刻把岛放出来，不能等下一次布局
    if (!hideEnabled) {
        gShouldHideIsland = NO;
        VIApplyIdleHidden(NO);
    }

    VIRelayout();
}

%ctor {
    preferencesChanged();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    (CFNotificationCallback)preferencesChanged,
                                    VI_NOTIFY_UPDATE, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 注销和几何导出只对 SpringBoard 有意义
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        (CFNotificationCallback)respringCallback,
                                        VI_NOTIFY_RESPRING, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        (CFNotificationCallback)VIDumpCallback,
                                        VI_NOTIFY_DUMP, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        // 启动 12 秒后静默导一份几何数据，界面上没有入口，不影响使用。
        // 位置要是还不对，直接拿这个文件就能定位，不用再加按钮重发一版。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VIDumpGeometry();
        });
    }
}

// build retrigger 2.10.1
