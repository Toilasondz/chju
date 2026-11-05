#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VSLOG(fmt, ...) NSLog(@"[VideoStarTool] " fmt, ##__VA_ARGS__)

// ============================================================================
// MARK: - Forward Declarations & Helpers
// ============================================================================

static UIWindow *VSGetActiveKeyWindow(void) {
    if (![NSThread isMainThread]) {
        VSLOG(@"Warning: VSGetActiveKeyWindow called outside main thread!");
    }
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *connectedScenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *win in windowScene.windows) {
                    if (win.isKeyWindow) {
                        keyWindow = win;
                        break;
                    }
                }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    return keyWindow;
}

static UIViewController *VSGetTopViewController(UIViewController *root) {
    if (!root) {
        root = VSGetActiveKeyWindow().rootViewController;
    }
    if (!root) return nil;

    if ([root isKindOfClass:[UINavigationController class]]) {
        return VSGetTopViewController([(UINavigationController *)root visibleViewController]);
    } else if ([root isKindOfClass:[UITabBarController class]]) {
        return VSGetTopViewController([(UITabBarController *)root selectedViewController]);
    } else if (root.presentedViewController) {
        return VSGetTopViewController(root.presentedViewController);
    }
    return root;
}

// ============================================================================
// MARK: - 1. CƠ CHẾ LỌC LỚP THÔNG MINH (SMART LAYER FILTER)
// ============================================================================
/*
 * Quy tắc:
 * - CHỈ NHẬN: Image Layer, Video Layer, Photo/Movie Clip.
 * - LOẠI TRỪ: Lớp Rỗng (Empty), Zaps!, Vật 3D (3D Objects),
 *             Lớp Phủ (Overlay), Lớp Màu (Color), Chữ (Text).
 */
static BOOL VSIsEligibleMediaLayer(id layerObj) {
    if (!layerObj) return NO;

    @try {
        NSString *className = NSStringFromClass([layerObj class]);
        NSString *lowerName = [className lowercaseString];

        // 1. Danh sách từ khóa bị cấm (Blacklist check theo tên Class)
        NSArray<NSString *> *blacklistedKeywords = @[
            @"empty",     // Lớp rỗng
            @"zap",       // Zaps!
            @"3d",        // Vật 3D
            @"threed",    // 3D format khác
            @"overlay",   // Lớp phủ
            @"color",     // Lớp màu
            @"text",      // Chữ / Văn bản
            @"title",     // Tiêu đề chữ
            @"shape",     // Hình khối
            @"audioonly"  // Audio thuần
        ];

        for (NSString *keyword in blacklistedKeywords) {
            if ([lowerName containsString:keyword]) {
                VSLOG(@"-> Bỏ qua lớp không hợp lệ (Khớp Blacklist Class): %@", className);
                return NO;
            }
        }

        // 2. Kiểm tra thuộc tính nội bộ 'layerType' hoặc 'type' nếu có
        if ([layerObj respondsToSelector:@selector(layerType)]) {
            NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(layerObj, @selector(layerType));
            // Quy ước chuẩn engine VideoStar/MultiLayer:
            // 0: Empty, 1: Video, 2: Photo, 3: Color, 4: Text, 5: 3D/Zaps
            if (type == 0 || type >= 3) {
                VSLOG(@"-> Bỏ qua layerType = %ld", (long)type);
                return NO;
            }
        }

        // 3. Kiểm tra các cờ phủ định (flags)
        if ([layerObj respondsToSelector:@selector(isTextLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isTextLayer))) {
            return NO;
        }
        if ([layerObj respondsToSelector:@selector(isColorLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isColorLayer))) {
            return NO;
        }
        if ([layerObj respondsToSelector:@selector(isEmptyLayer)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(layerObj, @selector(isEmptyLayer))) {
            return NO;
        }

        // 4. Kiểm tra các khả năng nhận Media (Whitelist)
        if ([layerObj respondsToSelector:@selector(setMediaURL:)] ||
            [layerObj respondsToSelector:@selector(setImage:)] ||
            [layerObj respondsToSelector:@selector(setSourceImage:)] ||
            [layerObj respondsToSelector:@selector(replaceContent:)] ||
            [lowerName containsString:@"video"] ||
            [lowerName containsString:@"photo"] ||
            [lowerName containsString:@"image"] ||
            [lowerName containsString:@"clip"]) {
            return YES;
        }

        return NO;
    } @catch (NSException *exception) {
        VSLOG(@"Lỗi khi kiểm tra lớp: %@", exception);
        return NO;
    }
}

// ============================================================================
// MARK: - 2. TRÌNH QUẢN LÝ AUTO NHẬP ẢNH / VIDEO (LAYER AUTO-FILLER)
// ============================================================================
@interface VSLayerAutoFiller : NSObject <PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, weak) id currentEditorController;
@property (nonatomic, strong) NSMutableArray *cachedEligibleLayers;
+ (instancetype)sharedInstance;
- (void)startAutoFillProcessFromController:(UIViewController *)controller;
- (void)applyPickedMedia:(NSArray *)mediaItems toLayers:(NSArray *)layers;
@end

@implementation VSLayerAutoFiller

+ (instancetype)sharedInstance {
    static VSLayerAutoFiller *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VSLayerAutoFiller alloc] init];
        instance.cachedEligibleLayers = [NSMutableArray array];
    });
    return instance;
}

- (void)startAutoFillProcessFromController:(UIViewController *)controller {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentEditorController = controller;
        [self.cachedEligibleLayers removeAllObjects];

        // Tìm kiếm các lớp hiện có trong controller
        NSArray *rawLayers = nil;
        if ([controller respondsToSelector:@selector(layers)]) {
            rawLayers = [controller valueForKey:@"layers"];
        } else if ([controller respondsToSelector:@selector(clipLayers)]) {
            rawLayers = [controller valueForKey:@"clipLayers"];
        } else if ([controller respondsToSelector:@selector(allLayers)]) {
            rawLayers = [controller valueForKey:@"allLayers"];
        }

        if (rawLayers && [rawLayers isKindOfClass:[NSArray class]]) {
            for (id layer in rawLayers) {
                if (VSIsEligibleMediaLayer(layer)) {
                    [self.cachedEligibleLayers addObject:layer];
                }
            }
        }

        VSLOG(@"Tìm thấy %lu lớp hợp lệ (Image/Video) để nạp nội dung.", (unsigned long)self.cachedEligibleLayers.count);

        if (@available(iOS 14.0, *)) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.selectionLimit = 0; // Không giới hạn số lượng ảnh/video
            config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
                [PHPickerFilter imagesFilter],
                [PHPickerFilter videosFilter]
            ]];

            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
            picker.delegate = self;
            [controller presentViewController:picker animated:YES completion:nil];
        } else {
            // Fallback UIImagePickerController cho iOS cũ hơn
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.delegate = self;
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            [controller presentViewController:picker animated:YES completion:nil];
        }
    });
}

// PHPickerViewController Delegate (iOS 14+)
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) return;

    NSMutableArray *loadedMedia = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();

    for (PHPickerResult *result in results) {
        NSItemProvider *provider = result.itemProvider;

        // Xử lý nạp Video
        if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
            dispatch_group_enter(group);
            [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
                if (url && !error) {
                    // Sao chép video ra thư mục tạm an toàn
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
                    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
                    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
                    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
                    @synchronized (loadedMedia) {
                        [loadedMedia addObject:tempURL];
                    }
                }
                dispatch_group_leave(group);
            }];
        }
        // Xử lý nạp Ảnh
        else if ([provider canLoadObjectOfClass:[UIImage class]]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
                if ([object isKindOfClass:[UIImage class]] && !error) {
                    @synchronized (loadedMedia) {
                        [loadedMedia addObject:(UIImage *)object];
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        VSLOG(@"Tải hoàn tất %lu media, bắt đầu gán vào các lớp...", (unsigned long)loadedMedia.count);
        [self applyPickedMedia:loadedMedia toLayers:self.cachedEligibleLayers];
    });
}

// Phân bổ nội dung đã chọn vào đúng các lớp hợp lệ
- (void)applyPickedMedia:(NSArray *)mediaItems toLayers:(NSArray *)layers {
    if (mediaItems.count == 0 || layers.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thông báo"
                                                                           message:@"Không tìm thấy lớp Hình ảnh/Video hợp lệ nào để nạp dữ liệu!"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
            [VSGetTopViewController(nil) presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    NSUInteger assignCount = MIN(mediaItems.count, layers.count);

    for (NSUInteger i = 0; i < assignCount; i++) {
        id media = mediaItems[i];
        id layer = layers[i];

        @try {
            if ([media isKindOfClass:[UIImage class]]) {
                UIImage *img = (UIImage *)media;
                if ([layer respondsToSelector:@selector(replaceContentWithImage:)]) {
                    [layer performSelector:@selector(replaceContentWithImage:) withObject:img];
                } else if ([layer respondsToSelector:@selector(setImage:)]) {
                    [layer performSelector:@selector(setImage:) withObject:img];
                } else if ([layer respondsToSelector:@selector(setSourceImage:)]) {
                    [layer performSelector:@selector(setSourceImage:) withObject:img];
                }
            } else if ([media isKindOfClass:[NSURL class]]) {
                NSURL *videoURL = (NSURL *)media;
                if ([layer respondsToSelector:@selector(replaceContentWithVideoURL:)]) {
                    [layer performSelector:@selector(replaceContentWithVideoURL:) withObject:videoURL];
                } else if ([layer respondsToSelector:@selector(setMediaURL:)]) {
                    [layer performSelector:@selector(setMediaURL:) withObject:videoURL];
                } else if ([layer respondsToSelector:@selector(setVideoURL:)]) {
                    [layer performSelector:@selector(setVideoURL:) withObject:videoURL];
                }
            }

            // Gọi làm mới giao diện lớp
            if ([layer respondsToSelector:@selector(setNeedsDisplay)]) {
                [layer performSelector:@selector(setNeedsDisplay)];
            }
        } @catch (NSException *ex) {
            VSLOG(@"Lỗi gán media tại lớp chỉ số %lu: %@", (unsigned long)i, ex);
        }
    }

    // Làm mới toàn bộ trình đa lớp nếu có phương thức reload
    if ([self.currentEditorController respondsToSelector:@selector(reloadLayers)]) {
        [self.currentEditorController performSelector:@selector(reloadLayers)];
    } else if ([self.currentEditorController respondsToSelector:@selector(refreshTimeline)]) {
        [self.currentEditorController performSelector:@selector(refreshTimeline)];
    }

    UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"Auto Nhập Hoàn Tất"
                                                                       message:[NSString stringWithFormat:@"Đã nạp thành công %lu media vào %lu lớp (Đã loại trừ toàn bộ chữ, 3D, Zaps, overlay).", (unsigned long)assignCount, (unsigned long)layers.count]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [doneAlert addAction:[UIAlertAction actionWithTitle:@"Tuyệt vời" style:UIAlertActionStyleCancel handler:nil]];
    [VSGetTopViewController(nil) presentViewController:doneAlert animated:YES completion:nil];
}

@end

// ============================================================================
// MARK: - 3. THANH CÔNG CỤ CHIA BEAT (BEAT MAPPING TOOLBAR VIEW)
// ============================================================================
@interface VSBeatToolbarView : UIView
@property (nonatomic, strong) UIButton *btnPrevBeat;
@property (nonatomic, strong) UIButton *btnNextBeat;
@property (nonatomic, strong) UIButton *btnSettings;
@property (nonatomic, strong) UIButton *btnSpeed;
@property (nonatomic, strong) UIButton *btnSplit;
@property (nonatomic, assign) CGFloat beatInterval; // Khoảng cách nhịp (giây)
@property (nonatomic, assign) CGFloat currentSpeed;  // Tốc độ: 0.5x, 1x, 2x
@property (nonatomic, weak) id activeTimelineController;
+ (instancetype)sharedToolbar;
- (void)toggleVisibility;
@end

@implementation VSBeatToolbarView

+ (instancetype)sharedToolbar {
    static VSBeatToolbarView *toolbar = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        toolbar = [[VSBeatToolbarView alloc] initWithFrame:CGRectZero];
    });
    return toolbar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _beatInterval = 0.5; // Mặc định 120 BPM (~0.5s/beat)
        _currentSpeed = 1.0;
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    self.layer.cornerRadius = 16.0;
    self.layer.borderColor = [[UIColor systemPurpleColor] colorWithAlphaComponent:0.8].CGColor;
    self.layer.borderWidth = 1.2;
    self.clipsToBounds = YES;
    self.hidden = YES;

    // Hiệu ứng mờ nền Blurring
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:blurView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
    ]];

    // 1. Nút Lùi Beat (<)
    self.btnPrevBeat = [self createButtonWithTitle:@"◀" action:@selector(onPrevBeatClicked)];
    [stack addArrangedSubview:self.btnPrevBeat];

    // 2. Nút Tiến Beat (>)
    self.btnNextBeat = [self createButtonWithTitle:@"▶" action:@selector(onNextBeatClicked)];
    [stack addArrangedSubview:self.btnNextBeat];

    // 3. Nút 1x Tốc độ
    self.btnSpeed = [self createButtonWithTitle:@"1.0x" action:@selector(onSpeedClicked)];
    [stack addArrangedSubview:self.btnSpeed];

    // 4. Nút Cắt / Chia Beat
    self.btnSplit = [self createButtonWithTitle:@"✂ Chia" action:@selector(onSplitClicked)];
    self.btnSplit.backgroundColor = [UIColor systemRedColor];
    [stack addArrangedSubview:self.btnSplit];

    // 5. Nút Cài đặt Beat
    self.btnSettings = [self createButtonWithTitle:@"⚙ Cài đặt" action:@selector(onSettingsClicked)];
    [stack addArrangedSubview:self.btnSettings];
}

- (UIButton *)createButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    btn.layer.cornerRadius = 8.0;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)toggleVisibility {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = VSGetActiveKeyWindow();
        if (!window) return;

        if (!self.superview) {
            CGFloat width = window.bounds.size.width - 32;
            CGFloat height = 50.0;
            CGFloat yPos = window.bounds.size.height - height - 90.0; // Vị trí nằm trên thanh tab/home indicator
            self.frame = CGRectMake(16, yPos, width, height);
            [window addSubview:self];
        }

        self.hidden = !self.hidden;
        if (!self.hidden) {
            [self.superview bringSubviewToFront:self];
            self.transform = CGAffineTransformMakeScale(0.9, 0.9);
            [UIView animateWithDuration:0.25 animations:^{
                self.transform = CGAffineTransformIdentity;
                self.alpha = 1.0;
            }];
        }
    });
}

// Logic chuyển lùi Playhead
- (void)onPrevBeatClicked {
    [self stepPlayheadBySeconds:-(self.beatInterval * (1.0 / self.currentSpeed))];
}

// Logic chuyển tới Playhead
- (void)onNextBeatClicked {
    [self stepPlayheadBySeconds:(self.beatInterval * (1.0 / self.currentSpeed))];
}

- (void)stepPlayheadBySeconds:(CGFloat)delta {
    @try {
        UIViewController *topVC = VSGetTopViewController(nil);
        id timeline = nil;
        if ([topVC respondsToSelector:@selector(timelineView)]) {
            timeline = [topVC valueForKey:@"timelineView"];
        } else if ([topVC respondsToSelector:@selector(audioEngine)]) {
            timeline = [topVC valueForKey:@"audioEngine"];
        }

        if (timeline && [timeline respondsToSelector:@selector(currentTime)]) {
            CMTime cur = [((NSValue *)[timeline valueForKey:@"currentTime"]) CMTimeValue];
            Float64 currentSec = CMTimeGetSeconds(cur);
            Float64 newSec = MAX(0.0, currentSec + delta);
            CMTime newTime = CMTimeMakeWithSeconds(newSec, 600);

            if ([timeline respondsToSelector:@selector(seekToTime:)]) {
                ((void (*)(id, SEL, CMTime))objc_msgSend)(timeline, @selector(seekToTime:), newTime);
            }
            VSLOG(@"Đã dịch Playhead tới: %.2f giây", newSec);
        }
    } @catch (NSException *ex) {
        VSLOG(@"Lỗi nhảy Beat: %@", ex);
    }
}

// Thay đổi tốc độ nhịp
- (void)onSpeedClicked {
    if (self.currentSpeed == 0.5) {
        self.currentSpeed = 1.0;
    } else if (self.currentSpeed == 1.0) {
        self.currentSpeed = 1.5;
    } else if (self.currentSpeed == 1.5) {
        self.currentSpeed = 2.0;
    } else {
        self.currentSpeed = 0.5;
    }
    [self.btnSpeed setTitle:[NSString stringWithFormat:@"%.1fx", self.currentSpeed] forState:UIControlStateNormal];
}

// Cắt / Chèn Marker phân cảnh
- (void)onSplitClicked {
    @try {
        UIViewController *topVC = VSGetTopViewController(nil);
        if ([topVC respondsToSelector:@selector(splitCurrentClip)]) {
            [topVC performSelector:@selector(splitCurrentClip)];
            VSLOG(@"Đã thực hiện splitCurrentClip");
        } else if ([topVC respondsToSelector:@selector(addMarkerAtCurrentTime)]) {
            [topVC performSelector:@selector(addMarkerAtCurrentTime)];
            VSLOG(@"Đã thực hiện addMarkerAtCurrentTime");
        } else {
            VSLOG(@"Không tìm thấy selector Split tương thích trên controller hiện tại.");
        }
    } @catch (NSException *e) {
        VSLOG(@"Lỗi thực thi cắt phân cảnh: %@", e);
    }
}

// Hộp thoại tinh chỉnh thông số Beat
- (void)onSettingsClicked {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cài Đặt Nhịp Beat"
                                                                   message:@"Nhập BPM (Beats Per Minute) hoặc khoảng cách nhịp (giây):"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Khoảng cách giây (VD: 0.5 = 120 BPM)";
        textField.text = [NSString stringWithFormat:@"%.2f", self.beatInterval];
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *field = alert.textFields.firstObject;
        CGFloat val = [field.text floatValue];
        if (val > 0.05) {
            self.beatInterval = val;
            VSLOG(@"Khoảng cách Beat mới: %.3f s", self.beatInterval);
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [VSGetTopViewController(nil) presentViewController:alert animated:YES completion:nil];
}

@end

// ============================================================================
// MARK: - 4. NÚT NỔI (DRAGGABLE FLOATING BUTTON & ACTION SHEET)
// ============================================================================
@interface VSFloatingMenuButton : UIButton
+ (instancetype)sharedButton;
- (void)attachToKeyWindow;
@end

@implementation VSFloatingMenuButton

+ (instancetype)sharedButton {
    static VSFloatingMenuButton *btn = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        btn = [VSFloatingMenuButton buttonWithType:UIButtonTypeCustom];
        [btn setupDesign];
    });
    return btn;
}

- (void)setupDesign {
    self.frame = CGRectMake(20, 150, 52, 52);
    self.layer.cornerRadius = 26;
    self.layer.masksToBounds = NO;
    self.backgroundColor = [UIColor colorWithRed:0.55 green:0.15 blue:0.95 alpha:0.9];
    self.layer.borderColor = [UIColor whiteColor].CGColor;
    self.layer.borderWidth = 2.0;

    // Đổ bóng nổi bật
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowOpacity = 0.4;
    self.layer.shadowRadius = 6.0;

    [self setTitle:@"★" forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    // Cử chỉ kéo thả (Draggable Pan Gesture)
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    [self addTarget:self action:@selector(onMenuTapped) forControlEvents:UIControlEventTouchUpInside];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIWindow *window = self.superview ? (UIWindow *)self.superview : VSGetActiveKeyWindow();
    if (!window) return;

    CGPoint translation = [pan translationInView:window];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    // Giữ nút không bị trôi ra ngoài màn hình
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW, MIN(window.bounds.size.width - halfW, newCenter.x));
    newCenter.y = MAX(halfH + 40, MIN(window.bounds.size.height - halfH - 40, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:window];

    // Khi thả tay: Tự động hít vào cạnh màn hình gần nhất (Left hoặc Right)
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat snapX = (self.center.x < window.bounds.size.width / 2.0) ? (halfW + 8) : (window.bounds.size.width - halfW - 8);
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.center = CGPointMake(snapX, self.center.y);
        } completion:nil];
    }
}

- (void)onMenuTapped {
    UIViewController *top = VSGetTopViewController(nil);
    if (!top) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"⭐ VIDEO STAR TOOL PRO ⭐"
                                                                   message:@"Tùy chọn công cụ xử lý cao cấp:"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Tính năng 1: Auto Nhập Ảnh/Video
    [sheet addAction:[UIAlertAction actionWithTitle:@"📥 Auto Nhập Ảnh / Video (Đã Lọc Lớp)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [[VSLayerAutoFiller sharedInstance] startAutoFillProcessFromController:top];
    }]];

    // Tính năng 2: Bật / Tắt Thanh Chia Beat
    [sheet addAction:[UIAlertAction actionWithTitle:@"🎵 Bật / Tắt Thanh Chia Beat"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [[VSBeatToolbarView sharedToolbar] toggleVisibility];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng Menu" style:UIAlertActionStyleCancel handler:nil]];

    // Hỗ trợ hiển thị chuẩn trên iPad
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self;
        sheet.popoverPresentationController.sourceRect = self.bounds;
    }

    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)attachToKeyWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = VSGetActiveKeyWindow();
        if (window && !self.superview) {
            [window addSubview:self];
            [window bringSubviewToFront:self];
            VSLOG(@"Floating Menu Button đã được gắn lên KeyWindow an toàn!");
        }
    });
}

@end

// ============================================================================
// MARK: - 5. LOGOS HOOKS & KHỞI TẠO AN TOÀN (LIFECYCLE HOOKS)
// ============================================================================

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // Đảm bảo nút nổi luôn hiển thị ở lớp trên cùng sau mỗi màn hình xuất hiện
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VSFloatingMenuButton sharedButton] attachToKeyWindow];
    });
}

%end

// Constructor khởi động Tweak an toàn sau khi ứng dụng chạy xong
%ctor {
    @autoreleasepool {
        VSLOG(@"VideoStarTool dylib đã được nạp thành công vào tiến trình!");

        // Lắng nghe sự kiện UIApplicationDidFinishLaunching để trì hoãn 2.5s (Chống crash khởi động)
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[VSFloatingMenuButton sharedButton] attachToKeyWindow];
                VSLOG(@"Khởi động giao diện Tweak thành công sau delay.");
            });
        }];
    }
}
