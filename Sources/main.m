#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import "WhisperEngine.h"

typedef struct {
    const char *title;
    const char *size;
    const char *filename;
    uint64_t bytes;
    const char *sha256;
} Model;

static const Model models[] = {
    {"Whisper Large v3 Turbo", "574 MB", "ggml-large-v3-turbo-q5_0.bin", 574041195,
     "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"},
    {"Whisper Base", "60 MB", "ggml-base-q5_1.bin", 59707625,
     "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"},
    {"Whisper Tiny", "32 MB", "ggml-tiny-q5_1.bin", 32152673,
     "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"},
    {"Whisper Small", "190 MB", "ggml-small-q5_1.bin", 190085487,
     "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"},
    {"Whisper Medium", "539 MB", "ggml-medium-q5_0.bin", 539212467,
     "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"}
};
static const NSInteger modelCount = sizeof(models) / sizeof(models[0]);
static const NSInteger noModel = -1;
static NSString *const defaultShortcut = @"⌥⇧Space";
static NSString *const modelOrigin =
    @"https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1";

typedef NS_ENUM(NSUInteger, Phase) {
    Idle, Downloading, CancelingDownload, Verifying, RequestingMicrophone, Recording, Transcribing
};

static NSStackView *Stack(NSUserInterfaceLayoutOrientation orientation, NSArray<NSView *> *views,
                          CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation;
    stack.spacing = spacing;
    return stack;
}

static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

static NSImage *Symbol(NSString *name, NSString *description, CGFloat size) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
    return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size
                                                                                               weight:NSFontWeightMedium]];
}

@interface ShortcutButton : NSButton
@property (copy) void (^capture)(NSEvent *event);
@property (strong) NSEvent *capturedKeyDown;
@end

@implementation ShortcutButton
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (self.capture) {
        if (!event.isARepeat) self.capturedKeyDown = event;
    }
    else [super keyDown:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!self.capture || self.window.firstResponder != self) return [super performKeyEquivalent:event];
    [self keyDown:event];
    return YES;
}
- (void)keyUp:(NSEvent *)event {
    void (^capture)(NSEvent *) = self.capture;
    if (capture) {
        NSEvent *keyDown = self.capturedKeyDown;
        if (keyDown && keyDown.keyCode == event.keyCode) {
            self.capturedKeyDown = nil;
            capture(keyDown);
        }
    } else [super keyUp:event];
}
- (BOOL)resignFirstResponder {
    self.capturedKeyDown = nil;
    void (^capture)(NSEvent *) = self.capture;
    if (capture) capture(nil);
    return [super resignFirstResponder];
}
@end

@interface VoiceKey : NSObject <NSApplicationDelegate, NSWindowDelegate, NSURLSessionDataDelegate, AVAudioRecorderDelegate>
@property Phase phase;
@property NSInteger selectedModel;
@property OSStatus shortcutStatus;
@property EventHotKeyRef hotKey;
@property EventHandlerRef hotKeyHandler;
@property UInt32 shortcutID;
@property UInt32 shortcutKey;
@property UInt32 shortcutModifiers;
@property (copy) NSString *shortcutTitle;
@property (strong) NSWindow *settingsWindow;
@property (strong) ShortcutButton *shortcutButton;
@property (strong) NSTextField *shortcutMessage;
@property (strong) NSButton *loginButton;
@property (strong) NSTextField *loginMessage;
@property (strong) NSButton *loginSettingsButton;
@property (strong) NSPopUpButton *settingsPicker;
@property (strong) NSButton *settingsDownload;
@property (strong) NSButton *unloadButton;
@property (strong) NSButton *removeButton;
@property (strong) NSTextField *settingsModelStatus;
@property (strong) NSProgressIndicator *settingsProgress;
@property BOOL autoCopy;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@property (strong) NSStackView *page;
@property (strong) NSTextField *headline;
@property (strong) NSTextField *detail;
@property (strong) NSTextField *modelLabel;
@property (strong) NSTextField *keyLabel;
@property (strong) NSImageView *stateImage;
@property (strong) NSProgressIndicator *progress;
@property (strong) NSPopUpButton *modelPicker;
@property (strong) NSButton *recordButton;
@property (strong) NSButton *transcriptCopyButton;
@property (strong) NSButton *downloadButton;
@property (strong) NSStackView *transcriptSection;
@property (strong) NSTextView *transcriptView;
@property (strong) NSURLSession *session;
@property (strong) NSURLSessionDataTask *downloadTask;
@property (strong) AVAudioRecorder *recorder;
@property (strong) NSURL *recordingFolder;
@property (strong) NSTimer *timer;
@property (copy) NSString *transcript;
@property (copy) NSString *notice;
@property BOOL failed;
@property double downloadedFraction;
@property uint64_t receivedBytes;
@property NSInteger retryCount;
@property (strong) NSFileHandle *partialFile;
@property (strong) NSTimer *retryTimer;
@property (strong) NSButton *uninstallButton;
- (void)toggleRecording:(id)sender;
@end

static OSStatus ShortcutReleased(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID identifier;
    OSStatus result = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                        NULL, sizeof(identifier), NULL, &identifier);
    VoiceKey *app = (__bridge VoiceKey *)context;
    if (result != noErr || identifier.signature != 0x564b4559 || identifier.id != app.shortcutID) {
        return eventNotHandledErr;
    }
    if (!app.shortcutButton.capture) [app toggleRecording:nil];
    return noErr;
}

@implementation VoiceKey

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"shortcutKey": @(kVK_Space), @"shortcutModifiers": @(optionKey | shiftKey),
                                 @"shortcutTitle": defaultShortcut, @"autoCopy": @YES}];
    NSInteger saved = [defaults integerForKey:@"selectedModel"];
    self.selectedModel = saved >= noModel && saved < modelCount ? saved : 0;
    self.autoCopy = [defaults boolForKey:@"autoCopy"];
    self.shortcutKey = (UInt32)[defaults integerForKey:@"shortcutKey"];
    self.shortcutModifiers = (UInt32)[defaults integerForKey:@"shortcutModifiers"];
    self.shortcutTitle = [defaults stringForKey:@"shortcutTitle"];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    [self buildPopover];

    const EventTypeSpec event = {kEventClassKeyboard, kEventHotKeyReleased};
    self.shortcutStatus = InstallEventHandler(GetApplicationEventTarget(), ShortcutReleased,
        1, &event, (__bridge void *)self, &_hotKeyHandler);
    if (self.shortcutStatus == noErr) {
        self.shortcutID = 1;
        const EventHotKeyID identifier = {0x564b4559, self.shortcutID};
        self.shortcutStatus = RegisterEventHotKey(self.shortcutKey, self.shortcutModifiers, identifier,
            GetApplicationEventTarget(), kEventHotKeyExclusive, &_hotKey);
    }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.timeoutIntervalForResource = 6 * 60 * 60;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self
                                            delegateQueue:NSOperationQueue.mainQueue];
    [self refresh];
    if (![defaults boolForKey:@"hasLaunched"]) {
        [defaults setBool:YES forKey:@"hasLaunched"];
        if (![self modelExists]) dispatch_async(dispatch_get_main_queue(), ^{ [self showPopover]; });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    if (self.hotKeyHandler) RemoveEventHandler(self.hotKeyHandler);
    [self.retryTimer invalidate];
    [self.partialFile closeFile];
    [self.session invalidateAndCancel];
    [self.recorder stop];
    [self cleanRecording];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (self.settingsWindow.visible) [self updateLoginControls];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (self.shortcutButton.capture) [self endShortcutCapture:@"Shortcut unchanged."];
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

- (NSPopUpButton *)newModelPicker {
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSInteger i = 0; i < modelCount; i++) [picker addItemWithTitle:@(models[i].title)];
    [picker addItemWithTitle:@"No active model"];
    [picker selectItemAtIndex:self.selectedModel == noModel ? modelCount : self.selectedModel];
    [picker setAccessibilityLabel:@"Speech recognition model"];
    picker.target = self;
    picker.action = @selector(selectModel:);
    return picker;
}

- (void)showSettings:(id)sender {
    [self.popover performClose:sender];
    if (!self.settingsWindow) [self buildSettings];
    [self updateLoginControls];
    [self refresh];
    [NSApp activate];
    [self.settingsWindow makeKeyAndOrderFront:sender];
}

- (void)buildSettings {
    NSColor *primary = NSColor.labelColor;
    NSColor *secondary = NSColor.secondaryLabelColor;
    self.shortcutButton = [[ShortcutButton alloc] initWithFrame:NSZeroRect];
    self.shortcutButton.title = self.shortcutTitle;
    self.shortcutButton.bezelStyle = NSBezelStyleRounded;
    self.shortcutButton.target = self;
    self.shortcutButton.action = @selector(captureShortcut:);
    [self.shortcutButton setAccessibilityLabel:@"Change global recording shortcut"];
    NSButton *reset = [self button:@"Reset" action:@selector(resetShortcut:)];
    NSStackView *shortcutRow = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[self.shortcutButton, reset], 8);
    self.shortcutMessage = Label(@"Click the shortcut, then press a new key combination.", 12, NSFontWeightRegular, secondary);

    self.settingsPicker = [self newModelPicker];
    self.settingsDownload = [self button:@"Download" action:@selector(downloadModel:)];
    self.unloadButton = [self button:@"Unload" action:@selector(unloadModel:)];
    self.removeButton = [self button:@"Move to Trash" action:@selector(removeModel:)];
    NSStackView *modelRow = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.settingsPicker, self.settingsDownload, self.unloadButton, self.removeButton], 7);
    self.settingsModelStatus = [NSTextField wrappingLabelWithString:@""];
    self.settingsModelStatus.font = [NSFont systemFontOfSize:12];
    self.settingsModelStatus.textColor = secondary;
    self.settingsProgress = [NSProgressIndicator new];
    self.settingsProgress.indeterminate = NO;
    self.settingsProgress.maxValue = 1;
    self.settingsProgress.controlSize = NSControlSizeSmall;
    [self.settingsProgress setAccessibilityLabel:@"Model download progress"];

    self.loginButton = [NSButton checkboxWithTitle:@"Start VoiceKey at login" target:self action:@selector(toggleLogin:)];
    self.loginSettingsButton = [self button:@"Open Login Items" action:@selector(openLoginSettings:)];
    NSStackView *loginRow = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.loginButton, self.loginSettingsButton], 8);
    self.loginMessage = [NSTextField wrappingLabelWithString:@""];
    self.loginMessage.font = [NSFont systemFontOfSize:12];
    self.loginMessage.textColor = secondary;
    NSButton *copy = [NSButton checkboxWithTitle:@"Copy new transcripts to the clipboard" target:self action:@selector(toggleAutoCopy:)];
    copy.state = self.autoCopy ? NSControlStateValueOn : NSControlStateValueOff;

    NSTextField *shortcutHeading = Label(@"Global shortcut", 14, NSFontWeightSemibold, primary);
    NSTextField *modelsHeading = Label(@"Local models", 14, NSFontWeightSemibold, primary);
    NSTextField *generalHeading = Label(@"General", 14, NSFontWeightSemibold, primary);
    self.uninstallButton = [self button:@"Uninstall VoiceKey…" action:@selector(uninstall:)];
    NSStackView *body = Stack(NSUserInterfaceLayoutOrientationVertical,
        @[shortcutHeading, shortcutRow, self.shortcutMessage, modelsHeading, modelRow, self.settingsModelStatus,
          self.settingsProgress, generalHeading, loginRow, self.loginMessage, copy, self.uninstallButton], 7);
    body.alignment = NSLayoutAttributeLeading;
    [body setCustomSpacing:18 afterView:self.shortcutMessage];
    [body setCustomSpacing:15 afterView:self.settingsProgress];
    for (NSView *fullWidth in @[self.settingsModelStatus, self.settingsProgress, self.loginMessage]) {
        [fullWidth.widthAnchor constraintEqualToConstant:454].active = YES;
    }

    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 498, 410)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"VoiceKey Settings";
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.delegate = self;
    NSView *content = self.settingsWindow.contentView;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [body.topAnchor constraintEqualToAnchor:content.topAnchor constant:21]
    ]];
    [self.settingsWindow center];
}

- (void)captureShortcut:(id)sender {
    if (self.shortcutButton.capture) return;
    __weak VoiceKey *app = self;
    self.shortcutButton.capture = ^(NSEvent *event) { [app handleShortcutCapture:event]; };
    if ([self.settingsWindow makeFirstResponder:self.shortcutButton]) {
        self.shortcutButton.title = @"Press shortcut…";
        self.shortcutMessage.stringValue = @"Use ⌘, ⌥, or ⌃ with another key. Esc cancels.";
    } else {
        [self endShortcutCapture:@"Click the shortcut again to start recording keys."];
    }
}

- (void)endShortcutCapture:(NSString *)message {
    self.shortcutButton.capture = nil;
    self.shortcutButton.capturedKeyDown = nil;
    self.shortcutButton.title = self.shortcutTitle;
    self.shortcutMessage.stringValue = message;
}

- (void)handleShortcutCapture:(NSEvent *)event {
    if (!event || event.keyCode == kVK_Escape) {
        [self endShortcutCapture:@"Shortcut unchanged."];
        return;
    }
    NSEventModifierFlags flags = event.modifierFlags;
    UInt32 modifiers = 0;
    NSMutableString *title = [NSMutableString string];
    if (flags & NSEventModifierFlagControl) { modifiers |= controlKey; [title appendString:@"⌃"]; }
    if (flags & NSEventModifierFlagOption) { modifiers |= optionKey; [title appendString:@"⌥"]; }
    if (flags & NSEventModifierFlagShift) { modifiers |= shiftKey; [title appendString:@"⇧"]; }
    if (flags & NSEventModifierFlagCommand) { modifiers |= cmdKey; [title appendString:@"⌘"]; }
    NSString *key = event.charactersIgnoringModifiers;
    unichar character = key.length ? [key characterAtIndex:0] : 0;
    if (character >= NSF1FunctionKey && character <= NSF20FunctionKey) {
        key = [NSString stringWithFormat:@"F%d", character - NSF1FunctionKey + 1];
    } else {
        switch (event.keyCode) {
            case kVK_Space: key = @"Space"; break;
            case kVK_Return: case kVK_ANSI_KeypadEnter: key = @"Return"; break;
            case kVK_Delete: key = @"Delete"; break;
            case kVK_Tab: key = @"Tab"; break;
            case kVK_LeftArrow: key = @"←"; break;
            case kVK_UpArrow: key = @"↑"; break;
            case kVK_DownArrow: key = @"↓"; break;
            case kVK_RightArrow: key = @"→"; break;
        }
    }
    unichar displayCharacter = key.length ? [key characterAtIndex:0] : 0;
    if (!(modifiers & (controlKey | optionKey | cmdKey)) || key.length == 0 ||
        [NSCharacterSet.controlCharacterSet characterIsMember:displayCharacter] ||
        (displayCharacter >= 0xF700 && displayCharacter <= 0xF8FF)) {
        self.shortcutMessage.stringValue = @"Use ⌘, ⌥, or ⌃ with a printable key or a function key.";
        return;
    }
    [title appendString:key.uppercaseString.length == 1 ? key.uppercaseString : key];
    [self setShortcutKey:event.keyCode modifiers:modifiers title:title];
}

- (void)resetShortcut:(id)sender {
    [self setShortcutKey:kVK_Space modifiers:optionKey | shiftKey title:defaultShortcut];
}

- (void)setShortcutKey:(UInt32)key modifiers:(UInt32)mods title:(NSString *)title {
    if (self.hotKey && key == self.shortcutKey && mods == self.shortcutModifiers) {
        [self endShortcutCapture:@"This shortcut is already active."];
        return;
    }
    const EventHotKeyID identifier = {0x564b4559, self.shortcutID + 1};
    EventHotKeyRef replacement = NULL;
    if (!self.hotKeyHandler || RegisterEventHotKey(key, mods, identifier, GetApplicationEventTarget(),
        kEventHotKeyExclusive, &replacement) != noErr) {
        [self endShortcutCapture:@"Shortcut unavailable. Try a different combination."];
        return;
    }
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    self.hotKey = replacement;
    self.shortcutID = identifier.id;
    self.shortcutStatus = noErr;
    self.shortcutKey = key;
    self.shortcutModifiers = mods;
    self.shortcutTitle = title;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:key forKey:@"shortcutKey"];
    [defaults setInteger:mods forKey:@"shortcutModifiers"];
    [defaults setObject:title forKey:@"shortcutTitle"];
    [self endShortcutCapture:@"Shortcut updated."];
    [self refresh];
}

- (void)updateLoginControls {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginButton.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginMessage.stringValue = status == SMAppServiceStatusRequiresApproval
        ? @"Allow VoiceKey in Login Items to finish enabling this option." : @"";
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL ok = sender.state == NSControlStateValueOn ? [service registerAndReturnError:&error]
                                                    : [service unregisterAndReturnError:&error];
    [self updateLoginControls];
    if (!ok && service.status != SMAppServiceStatusRequiresApproval) {
        self.loginMessage.stringValue = error.localizedDescription ?: @"Could not change the login item.";
    }
}

- (void)openLoginSettings:(id)sender { [SMAppService openSystemSettingsLoginItems]; }

- (void)toggleAutoCopy:(NSButton *)sender {
    self.autoCopy = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:self.autoCopy forKey:@"autoCopy"];
}

- (void)buildPopover {
    NSColor *primary = NSColor.labelColor;
    NSColor *secondary = NSColor.secondaryLabelColor;
    NSImageView *brand = [NSImageView imageViewWithImage:Symbol(@"waveform", @"VoiceKey", 17)];
    brand.contentTintColor = NSColor.controlAccentColor;
    self.keyLabel = Label(self.shortcutTitle, 12, NSFontWeightMedium, secondary);
    self.keyLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSView *spacer = [NSView new];
    NSStackView *header = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[brand, Label(@"VoiceKey", 18, NSFontWeightSemibold, primary), spacer, self.keyLabel], 8);

    self.stateImage = [NSImageView new];
    self.headline = Label(@"", 15, NSFontWeightSemibold, primary);
    NSStackView *state = Stack(NSUserInterfaceLayoutOrientationHorizontal,
                               @[self.stateImage, self.headline], 7);
    self.detail = [NSTextField wrappingLabelWithString:@""];
    self.detail.font = [NSFont systemFontOfSize:12];
    self.detail.textColor = secondary;
    self.detail.maximumNumberOfLines = 4;

    self.recordButton = [self button:@"Record" action:@selector(toggleRecording:)];
    self.transcriptCopyButton = [self button:@"Copy" action:@selector(copyTranscript:)];
    NSStackView *actions = Stack(NSUserInterfaceLayoutOrientationHorizontal,
                                 @[self.recordButton, self.transcriptCopyButton], 8);

    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    self.transcriptView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 340, 104)];
    self.transcriptView.editable = NO;
    self.transcriptView.selectable = YES;
    self.transcriptView.verticallyResizable = YES;
    self.transcriptView.horizontallyResizable = NO;
    self.transcriptView.autoresizingMask = NSViewWidthSizable;
    self.transcriptView.textContainer.widthTracksTextView = YES;
    self.transcriptView.textContainerInset = NSMakeSize(8, 7);
    [self.transcriptView setAccessibilityLabel:@"Transcript"];
    scroll.documentView = self.transcriptView;
    [scroll.heightAnchor constraintEqualToConstant:104].active = YES;
    [scroll.widthAnchor constraintEqualToConstant:344].active = YES;
    self.transcriptSection = Stack(NSUserInterfaceLayoutOrientationVertical,
        @[Label(@"Transcript", 12, NSFontWeightSemibold, primary), scroll], 6);
    self.transcriptSection.alignment = NSLayoutAttributeLeading;

    self.modelPicker = [self newModelPicker];
    self.downloadButton = [self button:@"Download" action:@selector(downloadModel:)];
    NSStackView *modelControls = Stack(NSUserInterfaceLayoutOrientationHorizontal,
                                       @[self.modelPicker, self.downloadButton], 8);
    self.modelLabel = Label(@"", 12, NSFontWeightRegular, secondary);
    self.progress = [NSProgressIndicator new];
    self.progress.indeterminate = NO;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.maxValue = 1;
    [self.progress setAccessibilityLabel:@"Model download progress"];

    NSButton *quit = [self button:@"Quit VoiceKey" action:@selector(quit:)];
    quit.bordered = NO;
    quit.font = [NSFont systemFontOfSize:12];
    NSButton *settings = [self button:@"Settings…" action:@selector(showSettings:)];
    NSStackView *footer = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[settings, quit], 10);
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;

    self.page = Stack(NSUserInterfaceLayoutOrientationVertical,
        @[header, state, self.detail, actions, self.transcriptSection, line,
          Label(@"Local model", 12, NSFontWeightSemibold, primary), modelControls,
          self.modelLabel, self.progress, footer], 9);
    self.page.alignment = NSLayoutAttributeLeading;
    self.page.detachesHiddenViews = YES;
    [self.page setCustomSpacing:15 afterView:header];
    [self.page setCustomSpacing:4 afterView:state];
    [self.page setCustomSpacing:12 afterView:actions];
    [self.page setCustomSpacing:13 afterView:self.transcriptSection];
    [self.page setCustomSpacing:12 afterView:line];
    [self.page setCustomSpacing:4 afterView:modelControls];
    for (NSView *fullWidth in @[header, self.detail, line, self.progress]) {
        [fullWidth.widthAnchor constraintEqualToConstant:344].active = YES;
    }

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 280)];
    self.page.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.page];
    [NSLayoutConstraint activateConstraints:@[
        [self.page.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [self.page.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18]
    ]];
    NSViewController *controller = [NSViewController new];
    controller.view = content;
    self.popover = [NSPopover new];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = controller;
}

- (void)showPopover {
    if (!self.popover.shown && self.statusItem.button.window) {
        [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button
                          preferredEdge:NSRectEdgeMinY];
    }
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) [self.popover performClose:sender];
    else [self showPopover];
}

- (void)quit:(id)sender { [NSApp terminate:sender]; }

- (NSURL *)modelsFolder {
    return [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                 inDomains:NSUserDomainMask].firstObject
            URLByAppendingPathComponent:@"VoiceKey/Models" isDirectory:YES];
}

- (NSURL *)modelURL {
    if (self.selectedModel == noModel) return nil;
    return [[self modelsFolder] URLByAppendingPathComponent:@(models[self.selectedModel].filename)];
}

- (BOOL)modelExists {
    if (self.selectedModel == noModel) return NO;
    NSNumber *size = nil;
    [[self modelURL] getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    return size.unsignedLongLongValue == models[self.selectedModel].bytes;
}

- (void)refresh {
    BOOL hasSelection = self.selectedModel != noModel;
    BOOL installed = [self modelExists];
    BOOL downloading = self.phase == Downloading || self.phase == CancelingDownload || self.phase == Verifying;
    BOOL denied = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied;
    NSString *title = installed ? @"Ready to record" : @"Download a model first";
    NSString *subtitle = installed ? @"Press the shortcut to start and again to stop." :
                                    @"Once downloaded, transcription runs on this Mac.";
    NSString *stateSymbol = installed ? @"circle.inset.filled" : @"arrow.down.circle";
    if (!hasSelection) {
        title = @"No active model";
        subtitle = @"Select a model to record.";
        stateSymbol = @"waveform";
    }
    NSString *menuSymbol = @"waveform";
    NSColor *tint = NSColor.controlAccentColor;

    switch (self.phase) {
        case Idle:
            if (self.failed) {
                title = @"Needs attention";
                stateSymbol = @"exclamationmark.circle";
                tint = NSColor.systemOrangeColor;
            }
            if (self.notice) subtitle = self.notice;
            else if (installed && self.shortcutStatus != noErr) subtitle = @"The shortcut is unavailable. Use Record below.";
            break;
        case Downloading:
        case CancelingDownload:
            title = self.phase == Downloading ? @"Downloading model…" : @"Canceling download…";
            subtitle = self.notice ?: @"You can close this popover while the download runs.";
            break;
        case Verifying:
            title = @"Verifying model…";
            subtitle = @"Checking the downloaded model file.";
            break;
        case RequestingMicrophone:
            title = @"Waiting for microphone access";
            subtitle = @"Allow microphone access in the macOS prompt to start recording.";
            stateSymbol = @"mic";
            break;
        case Recording: {
            NSInteger seconds = (NSInteger)self.recorder.currentTime;
            title = [NSString stringWithFormat:@"Recording  %ld:%02ld", seconds / 60, seconds % 60];
            subtitle = self.shortcutStatus == noErr ? @"Click Stop to transcribe." :
                                                       @"Press the shortcut again to transcribe.";
            stateSymbol = @"record.circle.fill";
            menuSymbol = @"record.circle.fill";
            tint = NSColor.systemRedColor;
            break;
        }
        case Transcribing:
            title = @"Transcribing…";
            subtitle = @"Whisper is processing the recording on this Mac.";
            stateSymbol = @"ellipsis.circle";
            menuSymbol = stateSymbol;
            break;
    }

    NSString *menuDescription = self.phase == Recording ? @"VoiceKey, recording" :
                                self.phase == Transcribing ? @"VoiceKey, transcribing" : @"VoiceKey";
    self.statusItem.button.image = Symbol(menuSymbol, menuDescription, 14);
    self.statusItem.button.toolTip = menuDescription;
    [self.statusItem.button setAccessibilityLabel:menuDescription];
    self.statusItem.button.contentTintColor = self.phase == Recording ? tint : nil;
    self.stateImage.image = Symbol(stateSymbol, @"", 13);
    self.stateImage.contentTintColor = tint;
    self.headline.stringValue = title;
    self.detail.stringValue = subtitle;
    self.keyLabel.stringValue = self.shortcutStatus == noErr ? self.shortcutTitle : @"";
    [self.keyLabel setAccessibilityLabel:[@"Global shortcut " stringByAppendingString:self.shortcutTitle]];
    self.keyLabel.hidden = self.shortcutStatus != noErr;

    self.recordButton.title = self.phase == Recording ? @"Stop & Transcribe" :
                              denied ? @"Microphone Settings" : @"Record";
    self.recordButton.enabled = (installed && self.phase == Idle) || self.phase == Recording;
    self.recordButton.bezelColor = self.recordButton.enabled ? NSColor.controlAccentColor : nil;
    self.transcriptCopyButton.hidden = self.transcript.length == 0;
    self.transcriptSection.hidden = self.transcript.length == 0;
    self.modelPicker.enabled = self.settingsPicker.enabled = self.phase == Idle;
    NSInteger pickerIndex = hasSelection ? self.selectedModel : modelCount;
    [self.modelPicker selectItemAtIndex:pickerIndex];
    [self.settingsPicker selectItemAtIndex:pickerIndex];
    self.downloadButton.hidden = !hasSelection || (installed && !downloading);
    BOOL resumable = hasSelection && !installed && [self partialSize] > 0;
    self.downloadButton.title = self.phase == Downloading ? @"Pause" : resumable ? @"Resume" : @"Download";
    self.uninstallButton.enabled = self.phase == Idle;
    self.downloadButton.enabled = self.phase == Idle || self.phase == Downloading;
    self.modelLabel.stringValue = hasSelection
        ? [NSString stringWithFormat:@"%@ · %s", downloading ? [NSString stringWithFormat:@"%.0f%%", 100 * self.downloadedFraction]
            : installed ? @"On this Mac" : @"Multilingual", models[self.selectedModel].size]
        : @"Downloaded models stay on this Mac when unloaded.";
    self.progress.hidden = !downloading;
    self.progress.doubleValue = self.downloadedFraction;
    self.popover.contentSize = NSMakeSize(380, ceil(self.page.fittingSize.height) + 32);
    self.settingsDownload.enabled = !self.downloadButton.hidden && self.downloadButton.enabled;
    self.settingsDownload.title = self.downloadButton.title;
    self.unloadButton.enabled = hasSelection && self.phase == Idle;
    self.removeButton.enabled = installed && self.phase == Idle;
    self.settingsModelStatus.stringValue = self.notice && (self.failed || !installed)
        ? self.notice : self.modelLabel.stringValue;
    self.settingsProgress.hidden = !downloading;
    self.settingsProgress.doubleValue = self.downloadedFraction;
}

- (void)selectModel:(NSPopUpButton *)sender {
    if (self.phase != Idle) return;
    NSInteger index = sender.indexOfSelectedItem;
    if (index < 0 || index > modelCount) return;
    [self activateModel:index == modelCount ? noModel : index];
}

- (void)activateModel:(NSInteger)index {
    self.selectedModel = index;
    [NSUserDefaults.standardUserDefaults setInteger:self.selectedModel forKey:@"selectedModel"];
    self.notice = nil;
    self.failed = NO;
    [self refresh];
}

- (void)unloadModel:(id)sender {
    if (self.phase == Idle) [self activateModel:noModel];
}

- (void)removeModel:(id)sender {
    if (self.phase != Idle || ![self modelExists]) return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:[self modelURL] resultingItemURL:NULL error:&error]) {
        [self displayError:error.localizedDescription ?: @"Could not move the model to Trash."];
        return;
    }
    self.notice = @"Model moved to Trash. Download it again to use it.";
    self.failed = NO;
    [self refresh];
}

- (void)displayError:(NSString *)message {
    self.phase = Idle;
    self.failed = YES;
    self.notice = message;
    [self refresh];
    if (!self.settingsWindow.keyWindow) [self showPopover];
}

- (NSURL *)partialURL { return [[self modelURL] URLByAppendingPathExtension:@"download"]; }

- (uint64_t)partialSize {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:self.partialURL.path error:NULL] fileSize];
}

- (void)downloadModel:(id)sender {
    if (self.phase == Downloading) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
        [self.downloadTask cancel];
        [self completeDownload:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
        return;
    }
    if (self.phase != Idle || self.selectedModel == noModel || [self modelExists]) return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.modelsFolder
        withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self displayError:error.localizedDescription];
        return;
    }
    self.phase = Downloading;
    self.failed = NO;
    self.retryCount = 0;
    [self requestRemainingBytes];
}

- (void)requestRemainingBytes {
    self.retryTimer = nil;
    self.notice = nil;
    Model model = models[self.selectedModel];
    self.receivedBytes = [self partialSize];
    if (self.receivedBytes >= model.bytes) {
        [self verifyDownload];
        return;
    }
    NSString *address = [NSString stringWithFormat:@"%@/%s?download=true", modelOrigin, model.filename];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.timeoutInterval = 45;
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (self.receivedBytes) {
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-", self.receivedBytes]
            forHTTPHeaderField:@"Range"];
    }
    self.downloadTask = [self.session dataTaskWithRequest:request];
    self.downloadedFraction = (double)self.receivedBytes / model.bytes;
    [self.downloadTask resume];
    [self refresh];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completion {
    if (task != self.downloadTask || ![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        completion(nil);
        return;
    }
    NSMutableURLRequest *redirect = [request mutableCopy];
    [redirect setValue:[task.originalRequest valueForHTTPHeaderField:@"Range"] forHTTPHeaderField:@"Range"];
    [redirect setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    completion(redirect);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if (task != self.downloadTask) { completion(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = http.statusCode;
    uint64_t size = models[self.selectedModel].bytes;
    if (status != 200 && status != 206) {
        completion(NSURLSessionResponseCancel);
        NSString *message = [NSString stringWithFormat:@"The model server returned HTTP %ld.", status];
        if (status == 408 || status == 429 || status >= 500) [self retryDownload:message];
        else [self completeDownload:VKError(message)];
        return;
    }
    if (status == 206) {
        NSString *expected = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", self.receivedBytes, size-1, size];
        if (![[http valueForHTTPHeaderField:@"Content-Range"] isEqualToString:expected]) {
            completion(NSURLSessionResponseCancel);
            [self completeDownload:VKError(@"The server returned an unexpected byte range. Your progress is saved.")];
            return;
        }
    }
    // A full response cannot be appended to an existing prefix.
    if (status == 200) self.receivedBytes = 0;
    NSURL *part = self.partialURL;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:part.path]) [files createFileAtPath:part.path contents:nil attributes:nil];
    NSError *error = nil;
    self.partialFile = [NSFileHandle fileHandleForWritingToURL:part error:&error];
    if (!self.partialFile || ![self.partialFile truncateAtOffset:self.receivedBytes error:&error] ||
        ![self.partialFile seekToOffset:self.receivedBytes error:&error]) {
        completion(NSURLSessionResponseCancel);
        [self completeDownload:error ?: VKError(@"Could not open the partial model file.")];
        return;
    }
    completion(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (task != self.downloadTask) return;
    uint64_t size = models[self.selectedModel].bytes;
    NSError *error = nil;
    if (data.length > size - self.receivedBytes || ![self.partialFile writeData:data error:&error]) {
        [task cancel];
        [self completeDownload:error ?: VKError(@"The server sent more model data than expected.")];
        return;
    }
    self.receivedBytes += data.length;
    double fraction = (double)self.receivedBytes / size;
    if (fraction - self.downloadedFraction >= 0.005) {
        self.downloadedFraction = fraction;
        [self refresh];
    }
}

- (void)retryDownload:(NSString *)reason {
    self.downloadTask = nil;
    [self.partialFile closeFile];
    self.partialFile = nil;
    if (self.retryCount >= 8) {
        [self completeDownload:VKError([reason stringByAppendingString:@" Your progress is saved. Click Resume to retry."])];
        return;
    }
    NSInteger delay = MIN(60, 1 << self.retryCount);
    self.retryCount++;
    self.notice = [NSString stringWithFormat:@"%@ Retrying in %ld seconds.", reason, delay];
    [self refresh];
    self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [self requestRemainingBytes];
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != self.downloadTask) return;
    if (error || self.receivedBytes != models[self.selectedModel].bytes) {
        [self retryDownload:error.localizedDescription ?: @"The connection ended early."];
        return;
    }
    [self verifyDownload];
}

- (void)verifyDownload {
    self.downloadTask = nil;
    [self.partialFile closeFile];
    self.partialFile = nil;
    self.phase = Verifying;
    self.downloadedFraction = 1;
    [self refresh];
    Model model = models[self.selectedModel];
    NSURL *stage = self.partialURL;
    NSURL *destination = self.modelURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSFileManager *files = NSFileManager.defaultManager;
        if (VKVerifyModel(stage, model.bytes, @(model.sha256), &error)) {
            if (rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation) != 0)
                error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        } else if ([error.domain isEqualToString:@"VoiceKey"]) {
            [files removeItemAtURL:stage error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self completeDownload:error]; });
    });
}

- (void)completeDownload:(NSError *)error {
    self.downloadTask = nil;
    [self.partialFile closeFile];
    self.partialFile = nil;
    self.phase = Idle;
    if (error && !([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)) {
        [self displayError:error.localizedDescription];
        return;
    }
    self.notice = error ? @"Download paused. Your progress is saved." : @"Model downloaded. You can record offline.";
    [self refresh];
}

- (void)uninstall:(id)sender {
    if (self.phase != Idle) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Uninstall VoiceKey and delete its data?";
    alert.informativeText = @"This permanently deletes VoiceKey’s models, partial downloads and preferences, removes its login item, and moves this copy of VoiceKey to Trash.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Uninstall"];
    if ([alert runModal] != NSAlertSecondButtonReturn || self.phase != Idle) return;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    NSError *error = nil;
    SMAppService *login = SMAppService.mainAppService;
    if ((login.status == SMAppServiceStatusEnabled || login.status == SMAppServiceStatusRequiresApproval) &&
        ![login unregisterAndReturnError:&error]) { [self displayError:error.localizedDescription]; return; }
    NSURL *library = [files URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSMutableArray<NSURL *> *paths = [NSMutableArray arrayWithObject:self.modelsFolder.URLByDeletingLastPathComponent];
    for (NSString *parent in @[@"Caches", @"HTTPStorages", @"Saved Application State"]) {
        NSString *name = [parent hasPrefix:@"Saved"] ? [bundleID stringByAppendingString:@".savedState"] : bundleID;
        [paths addObject:[[library URLByAppendingPathComponent:parent] URLByAppendingPathComponent:name]];
    }
    for (NSURL *entry in [files contentsOfDirectoryAtURL:files.temporaryDirectory includingPropertiesForKeys:nil options:0 error:NULL]) {
        NSString *name = entry.lastPathComponent;
        if ([name hasPrefix:@"VoiceKey-"] && [[NSUUID alloc] initWithUUIDString:[name substringFromIndex:[@"VoiceKey-" length]]]) [paths addObject:entry];
    }
    for (NSURL *path in paths) {
        if ([files fileExistsAtPath:path.path] && ![files removeItemAtURL:path error:&error]) {
            [self displayError:error.localizedDescription]; return;
        }
    }
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:bundleID];
    [NSUserDefaults.standardUserDefaults synchronize];
    if (![files trashItemAtURL:NSBundle.mainBundle.bundleURL resultingItemURL:NULL error:&error]) {
        [self displayError:[NSString stringWithFormat:@"Data removed. Move VoiceKey to Trash in Finder. %@", error.localizedDescription]];
        return;
    }
    [NSApp terminate:nil];
}

- (void)toggleRecording:(id)sender {
    if (self.phase == Recording) {
        [self finishRecording];
        return;
    }
    if (self.phase != Idle || ![self modelExists]) {
        [self showPopover];
        return;
    }

    AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    switch (permission) {
        case AVAuthorizationStatusAuthorized:
            [self startRecording];
            break;
        case AVAuthorizationStatusNotDetermined: {
            self.phase = RequestingMicrophone;
            [self refresh];
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [self startRecording];
                    else [self displayError:@"Allow VoiceKey in System Settings → Privacy & Security → Microphone."];
                });
            }];
            break;
        }
        case AVAuthorizationStatusDenied:
            if (sender == self.recordButton) {
                [NSWorkspace.sharedWorkspace openURL:
                    [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
            }
            [self displayError:@"Allow VoiceKey in System Settings → Privacy & Security → Microphone."];
            break;
        case AVAuthorizationStatusRestricted:
            [self displayError:@"Microphone access is restricted on this Mac."];
            break;
    }
}

- (void)startRecording {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [files.temporaryDirectory
        URLByAppendingPathComponent:[@"VoiceKey-" stringByAppendingString:NSUUID.UUID.UUIDString]
                        isDirectory:YES];
    NSError *error = nil;
    if (![files createDirectoryAtURL:folder withIntermediateDirectories:NO
                         attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        [self displayError:error.localizedDescription];
        return;
    }
    self.recordingFolder = folder;
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000,
        AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO};
    AVAudioRecorder *recorder = [[AVAudioRecorder alloc] initWithURL:
        [folder URLByAppendingPathComponent:@"recording.wav"] settings:settings error:&error];
    recorder.delegate = self;
    if (![recorder record]) {
        [self cleanRecording];
        [self displayError:error.localizedDescription ?: @"The microphone could not start recording."];
        return;
    }
    self.recorder = recorder;
    self.phase = Recording;
    self.failed = NO;
    self.notice = nil;
    __weak VoiceKey *app = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [app refresh];
    }];
    [self refresh];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)success {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.recorder != recorder || self.phase != Recording) return;
        if (success) [self finishRecording];
        else [self recordingFailed];
    });
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.recorder != recorder || self.phase != Recording) return;
        [self recordingFailed];
    });
}

- (void)recordingFailed {
    AVAudioRecorder *recorder = self.recorder;
    self.recorder = nil;
    [recorder stop];
    [self cleanRecording];
    [self displayError:@"The recording was interrupted. Check the microphone and start again."];
}

- (void)cleanRecording {
    [self.timer invalidate];
    self.timer = nil;
    if (self.recordingFolder) [NSFileManager.defaultManager removeItemAtURL:self.recordingFolder error:NULL];
    self.recordingFolder = nil;
}

- (void)finishRecording {
    AVAudioRecorder *recorder = self.recorder;
    self.recorder = nil;
    [recorder stop];
    [self.timer invalidate];
    self.timer = nil;
    self.phase = Transcribing;
    [self refresh];

    NSURL *audio = recorder.url;
    NSURL *model = [self modelURL];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *text = VKTranscribe(audio, model, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanRecording];
            self.phase = Idle;
            if (!text) {
                [self displayError:error.localizedDescription ?: @"The recording could not be read."];
                return;
            }
            if (text.length == 0) {
                self.notice = @"No speech was detected. Try another recording.";
                [self refresh];
                [self showPopover];
                return;
            }
            self.transcript = text;
            self.transcriptView.string = text;
            self.transcriptView.font = [NSFont systemFontOfSize:13];
            self.transcriptView.textColor = NSColor.textColor;
            [self.transcriptView scrollRangeToVisible:NSMakeRange(0, 0)];
            if (self.autoCopy) {
                [self copyTranscript:nil];
            } else {
                self.notice = @"Transcript ready. Use Copy to put it on the clipboard.";
                [self refresh];
            }
        });
    });
}

- (void)copyTranscript:(id)sender {
    if (self.transcript.length == 0) return;
    NSPasteboard *clipboard = NSPasteboard.generalPasteboard;
    [clipboard clearContents];
    BOOL copied = [clipboard setString:self.transcript forType:NSPasteboardTypeString];
    if (self.phase == Idle) {
        self.notice = copied ? @"Transcript copied. Press ⌘V to paste." : @"Select the transcript below to copy it.";
        self.failed = NO;
        [self refresh];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "--transcribe-test") == 0) {
            NSURL *model = [NSURL fileURLWithPath:@(argv[2])];
            NSURL *audio = [NSURL fileURLWithPath:@(argv[3])];
            NSError *error = nil;
            NSString *result = VKTranscribe(audio, model, &error);
            if (result.length == 0) {
                fprintf(stderr, "%s\n", (error.localizedDescription ?: @"No speech detected.").UTF8String);
                return 1;
            }
            puts(result.UTF8String);
            return 0;
        }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        VoiceKey *delegate = [VoiceKey new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
