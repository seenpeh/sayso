#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import "WhisperEngine.h"
#import "PhraseCapture.h"
#import "ReleaseUpdater.h"
#import <ApplicationServices/ApplicationServices.h>

typedef struct {
    const char *title;
    const char *size;
    const char *filename;
    uint64_t bytes;
    const char *sha256;
    const char *origin;
} Model;

static const Model models[] = {
    {"Whisper Large v3 Turbo", "574 MB", "ggml-large-v3-turbo-q5_0.bin", 574041195,
     "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", NULL},
    {"Whisper Base", "60 MB", "ggml-base-q5_1.bin", 59707625,
     "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", NULL},
    {"Whisper Small", "190 MB", "ggml-small-q5_1.bin", 190085487,
     "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", NULL},
    {"Whisper Medium", "539 MB", "ggml-medium-q5_0.bin", 539212467,
     "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", NULL},
    {"Persian Base · فارسی", "82 MB", "ggml-base-persian-q8_0.bin", 81768602,
     "a8bcb0746be5c9741ba8d1c87c89cccb6fa1452e7878275071f5165a7c43f4a7",
     "https://huggingface.co/armantee/whisper-base-persian-ggml/resolve/ea634cb5f241db4234de61cec5353c356868c88e"},
    {"Nava · فارسی", "574 MB", "ggml-nava-q5_0.bin", 574041195,
     "e788c333480c50fbde2e4c7c145a46f90fed6e055892c9d81582a6d11af84b0f",
     "https://huggingface.co/Nimruz/Nava-ggml/resolve/b4cc11c89fe8ec82619c8b4f97d1ea60c40ae6aa"},
    {"Whisper Tiny · Compact", "32 MB", "ggml-tiny-q5_1.bin", 32152673,
     "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7", NULL},
    {"Whisper Tiny", "78 MB", "ggml-tiny.bin", 77691713,
     "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", NULL}
};
static const NSInteger modelCount = sizeof(models) / sizeof(models[0]);
static const NSInteger persianBase = 4;
static BOOL PersianOnly(NSInteger index) { return index == persianBase || index == 5; }
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

@interface VoiceKey : NSObject <NSApplicationDelegate, NSWindowDelegate, NSURLSessionDataDelegate>
@property Phase phase;
@property NSInteger mode;
@property BOOL holding;
@property double shiftDown;
@property double lastTap;
@property (strong) id shiftMonitor;
@property (strong) NSTimer *shiftTimer;
@property (strong) NSPopUpButton *modePicker;
@property (strong) NSButton *checkButton;
- (void)shortcutEdge:(BOOL)pressed;
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
@property (strong) NSPopUpButton *languagePicker;
@property (strong) ReleaseUpdater *updater;
@property (strong) NSButton *updateButton;
@property (strong) NSButton *settingsUpdate;
@property (strong) NSTextField *updateStatus;
@property (strong) NSDate *lastCheck;
@property (strong) NSTimer *updateTimer;
@property (copy) NSString *offeredVersion;
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
@property (strong) NSButton *downloadButton;
@property (strong) NSURLSession *session;
@property (strong) NSURLSessionDataTask *downloadTask;
@property (strong) PhraseCapture *capture;
@property (strong) VKRecognizer *recognizer;
@property (strong) dispatch_queue_t recognitionQueue;
@property (strong) NSMutableArray<NSData *> *pending;
@property BOOL decoding;
@property BOOL typedPhrase;
@property NSUInteger generation;
@property (strong) NSDate *started;
@property (strong) NSRunningApplication *destination;
@property (strong) NSRunningApplication *popoverDestination;
@property (strong) id focusedElement;
@property (strong) NSTimer *timer;
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
    if (!app.shortcutButton.capture) [app shortcutEdge:GetEventKind(event) == kEventHotKeyPressed];
    return noErr;
}

@implementation VoiceKey

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"shortcutKey": @(kVK_Space), @"shortcutModifiers": @(optionKey | shiftKey),
                                 @"shortcutTitle": defaultShortcut, @"language": @"auto", @"recordingSounds": @YES}];
    NSInteger saved = [defaults integerForKey:@"selectedModel"];
    if ([defaults objectForKey:@"selectedModel"] && ![defaults boolForKey:@"removedTinyModels"]) {
        if (saved == 2 || saved == 6) saved = persianBase;
        else if (saved >= 3 && saved <= 5) saved--;
        [defaults setInteger:saved forKey:@"selectedModel"];
    }
    [defaults setBool:YES forKey:@"removedTinyModels"];
    self.selectedModel = [defaults objectForKey:@"selectedModel"] && saved >= noModel && saved < modelCount
        ? saved : [defaults boolForKey:@"hasLaunched"] ? 0 : persianBase;
    self.recognitionQueue = dispatch_queue_create("sayso.recognition", DISPATCH_QUEUE_SERIAL);
    self.pending = [NSMutableArray array];
    self.updater = [ReleaseUpdater new];
    self.shortcutKey = (UInt32)[defaults integerForKey:@"shortcutKey"];
    self.shortcutModifiers = (UInt32)[defaults integerForKey:@"shortcutModifiers"];
    self.shortcutTitle = [defaults stringForKey:@"shortcutTitle"];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    [self buildPopover];

    self.mode = [defaults integerForKey:@"recordingMode"];
    [self configureShift];
    const EventTypeSpec events[] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
    self.shortcutStatus = InstallEventHandler(GetApplicationEventTarget(), ShortcutReleased,
        2, events, (__bridge void *)self, &_hotKeyHandler);
    if (self.shortcutStatus == noErr && self.mode < 2) {
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
    __weak VoiceKey *app = self;
    self.updater.changed = ^{ [app updateChanged]; };
    [self checkUpdates:nil];
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:86400 repeats:YES block:^(NSTimer *timer) {
        [app checkUpdates:nil];
    }];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
        name:NSWorkspaceDidWakeNotification object:nil];
    [self refresh];
    if (![defaults boolForKey:@"hasLaunched"]) {
        [defaults setBool:YES forKey:@"hasLaunched"];
        if (![self modelExists]) dispatch_async(dispatch_get_main_queue(), ^{ [self showPopover]; });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.shiftMonitor) [NSEvent removeMonitor:self.shiftMonitor];
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    if (self.hotKeyHandler) RemoveEventHandler(self.hotKeyHandler);
    [self.retryTimer invalidate];
    [self.partialFile closeFile];
    [self.session invalidateAndCancel];
    [self.updateTimer invalidate];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self cancelCapture];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (self.settingsWindow.visible) [self updateLoginControls];
}

- (void)didWake:(NSNotification *)notification {
    if (-self.lastCheck.timeIntervalSinceNow >= 86400) [self checkUpdates:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [self checkUpdates:nil];
    [self showPopover];
    return YES;
}

- (void)checkUpdates:(id)sender {
    self.lastCheck = [NSDate date];
    [self.updater check];
}

- (void)updateAction:(id)sender {
    if (self.updater.availableVersion && self.phase == Idle) [self.updater install];
    else [self checkUpdates:sender];
}

- (void)updateChanged {
    [self refresh];
    if (self.phase == Idle && self.updater.availableVersion &&
        ![self.offeredVersion isEqual:self.updater.availableVersion]) {
        self.offeredVersion = self.updater.availableVersion;
        if (!self.settingsWindow.visible) [self showPopover];
    }
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

// 0 toggles the configured chord, 1 holds it, 2 holds Shift, 3 double-taps Shift.
- (void)shortcutEdge:(BOOL)pressed {
    if (self.mode >= 2) return;
    if (self.mode == 0) {
        if (!pressed) [self toggleRecording:nil];
    } else [self holdEdge:pressed];
}

- (void)holdEdge:(BOOL)pressed {
    if (pressed && self.phase == Idle && !self.holding) {
        self.holding = YES;
        [self toggleRecording:nil];
    } else if (!pressed && self.holding) {
        self.holding = NO;
        if (self.phase == Recording) [self finishRecording];
        else if (self.phase == RequestingMicrophone) {
            self.generation++;
            self.phase = Idle;
            [self refresh];
        }
    }
}

- (void)configureShift {
    if (self.shiftMonitor) [NSEvent removeMonitor:self.shiftMonitor];
    self.shiftMonitor = nil;
    [self.shiftTimer invalidate];
    self.shiftDown = self.lastTap = 0;
    if (self.mode < 2) return;
    __weak VoiceKey *weakSelf = self;
    self.shiftMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged | NSEventMaskKeyDown
        handler:^(NSEvent *event) { [weakSelf shiftEvent:event]; }];
}

- (void)shiftEvent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    if (self.holding && !CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, kVK_Shift))
        [self holdEdge:NO];
    if (event.type != NSEventTypeFlagsChanged || event.keyCode != kVK_Shift ||
        (flags & (NSEventModifierFlagControl | NSEventModifierFlagCommand | NSEventModifierFlagOption))) {
        [self.shiftTimer invalidate];
        self.shiftDown = self.lastTap = 0;
        return;
    }
    if (CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, kVK_Shift)) {
        self.shiftDown = event.timestamp;
        if (self.mode == 2) {
            [self.shiftTimer invalidate];
            self.shiftTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
                [self holdEdge:YES];
            }];
        }
    } else {
        [self.shiftTimer invalidate];
        if (self.mode == 2) [self holdEdge:NO];
        else if (self.shiftDown && event.timestamp - self.shiftDown < 0.3) {
            if (self.lastTap && event.timestamp - self.lastTap <= NSEvent.doubleClickInterval) {
                self.lastTap = 0;
                [self toggleRecording:nil];
            } else self.lastTap = event.timestamp;
        } else self.lastTap = 0;
        self.shiftDown = 0;
    }
}

- (void)changeMode:(NSPopUpButton *)sender {
    self.mode = sender.indexOfSelectedItem;
    [NSUserDefaults.standardUserDefaults setInteger:self.mode forKey:@"recordingMode"];
    if (self.mode >= 2 && self.hotKey) {
        UnregisterEventHotKey(self.hotKey);
        self.hotKey = NULL;
    } else if (self.mode < 2 && !self.hotKey) {
        EventHotKeyID identifier = {0x564b4559, ++_shortcutID};
        self.shortcutStatus = RegisterEventHotKey(self.shortcutKey, self.shortcutModifiers, identifier,
            GetApplicationEventTarget(), kEventHotKeyExclusive, &_hotKey);
    }
    [self configureShift];
    [self refresh];
}

- (void)soundSetting:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:@"recordingSounds"];
}

- (void)cue:(NSString *)name {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"recordingSounds"]) return;
    NSSound *sound = [NSSound soundNamed:name];
    sound.volume = 0.13;
    [sound play];
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

    self.loginButton = [NSButton checkboxWithTitle:@"Start Sayso at login" target:self action:@selector(toggleLogin:)];
    self.loginSettingsButton = [self button:@"Open Login Items" action:@selector(openLoginSettings:)];
    NSStackView *loginRow = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.loginButton, self.loginSettingsButton], 8);
    self.loginMessage = [NSTextField wrappingLabelWithString:@""];
    self.loginMessage.font = [NSFont systemFontOfSize:12];
    self.loginMessage.textColor = secondary;
    self.languagePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.languagePicker addItemsWithTitles:@[@"Detect language", @"Persian · فارسی"]];
    [self.languagePicker setAccessibilityLabel:@"Spoken language"];
    self.languagePicker.target = self;
    self.languagePicker.action = @selector(changeLanguage:);
    self.settingsUpdate = [self button:@"Check for Updates…" action:@selector(updateAction:)];
    self.updateStatus = [NSTextField wrappingLabelWithString:@""];
    self.updateStatus.textColor = secondary;
    self.updateStatus.font = [NSFont systemFontOfSize:12];
    NSStackView *languageRow = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[Label(@"Spoken language", 12, NSFontWeightRegular, primary), self.languagePicker], 10);

    NSTextField *shortcutHeading = Label(@"Global shortcut", 14, NSFontWeightSemibold, primary);
    NSTextField *modelsHeading = Label(@"Local models", 14, NSFontWeightSemibold, primary);
    NSTextField *generalHeading = Label(@"General", 14, NSFontWeightSemibold, primary);
    self.uninstallButton = [self button:@"Uninstall Sayso…" action:@selector(uninstall:)];
    self.modePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.modePicker addItemsWithTitles:@[@"Toggle with shortcut", @"Hold shortcut to talk", @"Hold left Shift to talk", @"Double-tap left Shift to toggle"]];
    [self.modePicker selectItemAtIndex:self.mode];
    self.modePicker.target = self;
    self.modePicker.action = @selector(changeMode:);
    NSButton *sounds = [NSButton checkboxWithTitle:@"Play soft recording sounds" target:self action:@selector(soundSetting:)];
    sounds.state = [NSUserDefaults.standardUserDefaults boolForKey:@"recordingSounds"];
    self.checkButton = [self button:@"Check for Updates…" action:@selector(checkUpdates:)];
    NSStackView *updates = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[self.checkButton, self.settingsUpdate], 8);
    NSTabView *tabs = [NSTabView new];
    NSArray *groups = @[@[shortcutHeading, self.modePicker, shortcutRow, self.shortcutMessage, sounds],
                        @[modelsHeading, modelRow, languageRow, self.settingsModelStatus, self.settingsProgress],
                        @[generalHeading, loginRow, self.loginMessage, updates, self.updateStatus, self.uninstallButton]];
    NSArray *titles = @[@"Recording", @"Models", @"General"];
    for (NSUInteger i = 0; i < groups.count; i++) {
        NSTabViewItem *tab = [[NSTabViewItem alloc] initWithIdentifier:titles[i]];
        tab.label = titles[i];
        NSStackView *section = Stack(NSUserInterfaceLayoutOrientationVertical, groups[i], 12);
        section.alignment = NSLayoutAttributeLeading;
        section.translatesAutoresizingMaskIntoConstraints = NO;
        tab.view = [NSView new];
        [tab.view addSubview:section];
        [section.leadingAnchor constraintEqualToAnchor:tab.view.leadingAnchor constant:18].active = YES;
        [section.topAnchor constraintEqualToAnchor:tab.view.topAnchor constant:16].active = YES;
        [tabs addTabViewItem:tab];
    }
    for (NSView *fullWidth in @[self.settingsModelStatus, self.settingsProgress, self.loginMessage, self.updateStatus]) {
        [fullWidth.widthAnchor constraintEqualToConstant:510].active = YES;
    }

    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 340)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"Sayso Settings";
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.delegate = self;
    NSView *content = self.settingsWindow.contentView;
    tabs.frame = NSInsetRect(content.bounds, 12, 10);
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tabs];
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
        ? @"Allow Sayso in Login Items to finish enabling this option." : @"";
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

- (void)changeLanguage:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.indexOfSelectedItem ? @"fa" : @"auto" forKey:@"language"];
    self.recognizer = nil;
    [self refresh];
}

- (void)buildPopover {
    NSColor *primary = NSColor.labelColor;
    NSColor *secondary = NSColor.secondaryLabelColor;
    NSImageView *brand = [NSImageView imageViewWithImage:Symbol(@"waveform", @"Sayso", 17)];
    brand.contentTintColor = NSColor.controlAccentColor;
    self.keyLabel = Label(self.shortcutTitle, 12, NSFontWeightMedium, secondary);
    self.keyLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSView *spacer = [NSView new];
    NSStackView *header = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[brand, Label(@"Sayso", 18, NSFontWeightSemibold, primary), spacer, self.keyLabel], 8);

    self.stateImage = [NSImageView new];
    self.headline = Label(@"", 18, NSFontWeightSemibold, primary);
    NSStackView *state = Stack(NSUserInterfaceLayoutOrientationHorizontal,
                               @[self.stateImage, self.headline], 7);
    self.detail = [NSTextField wrappingLabelWithString:@""];
    self.detail.font = [NSFont systemFontOfSize:12];
    self.detail.textColor = secondary;
    self.detail.maximumNumberOfLines = 4;

    NSStackView *statusText = Stack(NSUserInterfaceLayoutOrientationVertical, @[state, self.detail], 5);
    statusText.alignment = NSLayoutAttributeLeading;
    [self.detail.widthAnchor constraintEqualToConstant:312].active = YES;
    NSBox *statusCard = [NSBox new];
    statusCard.boxType = NSBoxCustom;
    statusCard.titlePosition = NSNoTitle;
    statusCard.cornerRadius = 10;
    statusCard.borderWidth = 0;
    statusCard.fillColor = NSColor.controlBackgroundColor;
    NSView *cardContent = statusCard.contentView;
    [cardContent addSubview:statusText];
    statusText.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [statusText.leadingAnchor constraintEqualToAnchor:cardContent.leadingAnchor constant:14],
        [statusText.topAnchor constraintEqualToAnchor:cardContent.topAnchor constant:12],
        [statusText.bottomAnchor constraintEqualToAnchor:cardContent.bottomAnchor constant:-12]
    ]];

    self.recordButton = [self button:@"Record" action:@selector(toggleRecording:)];
    self.recordButton.controlSize = NSControlSizeLarge;
    self.recordButton.imagePosition = NSImageLeading;
    self.recordButton.image = Symbol(@"mic.fill", @"", 14);
    self.updateButton = [self button:@"Install Update…" action:@selector(updateAction:)];
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

    NSButton *quit = [self button:@"Quit Sayso" action:@selector(quit:)];
    quit.bordered = NO;
    quit.font = [NSFont systemFontOfSize:12];
    NSButton *settings = [self button:@"Settings…" action:@selector(showSettings:)];
    NSStackView *footer = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[settings, quit], 10);
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;

    self.page = Stack(NSUserInterfaceLayoutOrientationVertical,
        @[header, statusCard, self.recordButton, line,
          Label(@"Local model", 12, NSFontWeightSemibold, primary), modelControls,
          self.modelLabel, self.progress, self.updateButton, footer], 9);
    self.page.alignment = NSLayoutAttributeLeading;
    self.page.detachesHiddenViews = YES;
    [self.page setCustomSpacing:15 afterView:header];
    [self.page setCustomSpacing:12 afterView:self.recordButton];
    [self.page setCustomSpacing:12 afterView:line];
    [self.page setCustomSpacing:4 afterView:modelControls];
    for (NSView *fullWidth in @[header, statusCard, self.recordButton, line, self.progress]) {
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
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (front.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
            self.popoverDestination = front;
        [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button
                          preferredEdge:NSRectEdgeMinY];
    }
}

- (void)togglePopover:(id)sender {
    if (self.phase == Recording) { [self finishRecording]; return; }
    if (self.phase == Transcribing) return;
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
    NSString *title = installed ? @"Ready to dictate" : @"Download a model first";
    NSString *subtitle = installed ? @"Place the cursor in a text field, then press the shortcut. Pause briefly to type each phrase." :
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
            else if (installed && self.shortcutStatus != noErr) subtitle = @"The shortcut is unavailable. Click Start dictation below.";
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
            NSInteger seconds = (NSInteger)(-self.started.timeIntervalSinceNow);
            title = [NSString stringWithFormat:@"Listening  %ld:%02ld", seconds / 60, seconds % 60];
            subtitle = [NSString stringWithFormat:@"Typing into %@ as you pause.", self.destination.localizedName ?: @"your app"];
            stateSymbol = @"record.circle.fill";
            menuSymbol = @"record.circle.fill";
            tint = NSColor.systemRedColor;
            break;
        }
        case Transcribing:
            title = @"Finishing dictation…";
            subtitle = self.notice ?: @"Typing the last phrase into your text field.";
            stateSymbol = @"ellipsis.circle";
            menuSymbol = stateSymbol;
            break;
    }

    NSString *menuDescription = self.phase == Recording ? @"Sayso, listening. Click to stop dictation." :
                                self.phase == Transcribing ? @"Sayso, transcribing" : @"Sayso";
    NSStatusBarButton *indicator = self.statusItem.button;
    if (self.phase == Recording && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        CGFloat opacity = ((NSInteger)(-self.started.timeIntervalSinceNow * 2) % 2) ? 0.55 : 1;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.42;
            indicator.animator.alphaValue = opacity;
        } completionHandler:nil];
    } else indicator.animator.alphaValue = 1;
    self.statusItem.button.image = Symbol(menuSymbol, menuDescription, 14);
    self.statusItem.button.toolTip = menuDescription;
    [self.statusItem.button setAccessibilityLabel:menuDescription];
    self.statusItem.button.contentTintColor = self.phase == Recording ? tint : nil;
    self.stateImage.image = Symbol(stateSymbol, @"", 13);
    self.stateImage.contentTintColor = tint;
    self.headline.stringValue = title;
    self.detail.stringValue = subtitle;
    self.keyLabel.stringValue = self.mode == 2 ? @"Hold left Shift" : self.mode == 3 ? @"Double-tap left Shift" : self.shortcutStatus == noErr ? self.shortcutTitle : @"";
    [self.keyLabel setAccessibilityLabel:[@"Global shortcut " stringByAppendingString:self.shortcutTitle]];
    self.keyLabel.hidden = self.mode < 2 && self.shortcutStatus != noErr;

    self.recordButton.title = self.phase == Recording ? @"Stop dictation" :
                              denied ? @"Microphone Settings" : !AXIsProcessTrusted() ? @"Enable keyboard access…" : @"Start dictation";
    self.recordButton.enabled = (installed && self.phase == Idle && !self.updater.installing) || self.phase == Recording;
    self.recordButton.bezelColor = self.recordButton.enabled ? NSColor.controlAccentColor : nil;
    BOOL available = self.phase == Idle && !self.updater.installing;
    self.modelPicker.enabled = self.settingsPicker.enabled = available;
    self.languagePicker.enabled = available && !PersianOnly(self.selectedModel);
    [self.languagePicker selectItemAtIndex:PersianOnly(self.selectedModel) ||
        [[NSUserDefaults.standardUserDefaults stringForKey:@"language"] isEqual:@"fa"] ? 1 : 0];
    NSString *updateTitle = self.updater.availableVersion ?
        [NSString stringWithFormat:@"Install %@ and restart", self.updater.availableVersion] : @"Check for Updates…";
    self.updateButton.hidden = !self.updater.availableVersion;
    self.updateButton.title = self.updater.installing ? @"Installing update…" : updateTitle;
    self.settingsUpdate.title = self.updateButton.title;
    self.settingsUpdate.hidden = !self.updater.availableVersion;
    self.checkButton.enabled = available && !self.updater.checking;
    self.checkButton.title = self.updater.checking ? @"Checking…" : @"Check for Updates…";
    self.modePicker.enabled = available;
    self.shortcutButton.superview.hidden = self.mode >= 2;
    self.shortcutMessage.hidden = self.mode >= 2;
    self.updateButton.enabled = self.settingsUpdate.enabled = available && !self.updater.checking;
    self.updateStatus.stringValue = self.updater.status;
    self.updateButton.toolTip = self.updater.status;
    if (self.updater.availableVersion && self.phase == Idle) {
        self.detail.stringValue = self.updater.status;
        if (self.updater.installing) self.headline.stringValue = @"Updating Sayso…";
    }
    NSInteger pickerIndex = hasSelection ? self.selectedModel : modelCount;
    [self.modelPicker selectItemAtIndex:pickerIndex];
    [self.settingsPicker selectItemAtIndex:pickerIndex];
    self.downloadButton.hidden = !hasSelection || (installed && !downloading);
    BOOL resumable = hasSelection && !installed && [self partialSize] > 0;
    self.downloadButton.title = self.phase == Downloading ? @"Pause" : resumable ? @"Resume" : @"Download";
    self.uninstallButton.enabled = available;
    self.downloadButton.enabled = available || self.phase == Downloading;
    if (downloading) self.modelLabel.stringValue = [NSString stringWithFormat:@"%.0f%% · %s",
        100 * self.downloadedFraction, models[self.selectedModel].size];
    else if (hasSelection) {
        NSString *description = PersianOnly(self.selectedModel) ? @"Persian dictation" :
            @"Multilingual";
        self.modelLabel.stringValue = [NSString stringWithFormat:@"%@ · %s%@", description,
            models[self.selectedModel].size, installed ? @" · Installed" : @""];
    } else self.modelLabel.stringValue = @"Choose a model to start dictating.";
    self.progress.hidden = !downloading;
    self.progress.doubleValue = self.downloadedFraction;
    self.popover.contentSize = NSMakeSize(380, ceil(self.page.fittingSize.height) + 32);
    self.settingsDownload.hidden = self.downloadButton.hidden;
    self.settingsDownload.enabled = !self.downloadButton.hidden && self.downloadButton.enabled;
    self.settingsDownload.title = self.downloadButton.title;
    self.unloadButton.enabled = hasSelection && available;
    self.removeButton.enabled = installed && available;
    self.settingsModelStatus.stringValue = self.notice && (self.failed || !installed)
        ? self.notice : self.modelLabel.stringValue;
    self.settingsProgress.hidden = !downloading;
    self.settingsProgress.doubleValue = self.downloadedFraction;
}

- (void)selectModel:(NSPopUpButton *)sender {
    if (self.phase != Idle || self.updater.installing) return;
    NSInteger index = sender.indexOfSelectedItem;
    if (index < 0 || index > modelCount) return;
    [self activateModel:index == modelCount ? noModel : index];
}

- (void)activateModel:(NSInteger)index {
    self.recognizer = nil;
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
    NSString *address = [NSString stringWithFormat:@"%@/%s?download=true", model.origin ? @(model.origin) : modelOrigin, model.filename];
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
    if (self.phase != Idle || self.updater.installing) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Uninstall Sayso and delete its data?";
    alert.informativeText = @"This permanently deletes Sayso’s models, partial downloads and preferences, removes its login item, and moves this copy of Sayso to Trash.";
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
        [self displayError:[NSString stringWithFormat:@"Data removed. Move Sayso to Trash in Finder. %@", error.localizedDescription]];
        return;
    }
    [NSApp terminate:nil];
}

- (void)toggleRecording:(id)sender {
    if (self.phase == Recording) { [self finishRecording]; return; }
    if (self.phase != Idle || self.updater.installing) return;
    if (![self modelExists]) { [self showPopover]; return; }

    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.destination = front.processIdentifier == NSRunningApplication.currentApplication.processIdentifier &&
        self.popover.shown ? self.popoverDestination : front;
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES})) {
        [self displayError:@"Allow Sayso under Privacy & Security → Accessibility, then try the shortcut again."];
        return;
    }
    if (!self.destination || self.destination.terminated ||
        self.destination.processIdentifier == NSRunningApplication.currentApplication.processIdentifier) {
        [self displayError:@"Click a text field in another app and press your dictation shortcut."];
        return;
    }
    [self.popover performClose:nil];
    self.phase = RequestingMicrophone;
    [self refresh];
    AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    NSUInteger request = ++self.generation;
    if (permission == AVAuthorizationStatusAuthorized) {
        [self prepareDestination];
    } else if (permission == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.generation != request || self.phase != RequestingMicrophone) return;
                if (granted) [self prepareDestination];
                else [self displayError:@"Allow Sayso under Privacy & Security → Microphone."];
            });
        }];
    } else {
        if (sender == self.recordButton && permission == AVAuthorizationStatusDenied)
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
        [self displayError:@"Microphone access is unavailable. Check Privacy & Security → Microphone."];
    }
}

- (void)prepareDestination {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front.processIdentifier == NSRunningApplication.currentApplication.processIdentifier)
        [self.destination activateWithOptions:0];
    NSUInteger request = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.phase != RequestingMicrophone || request != self.generation) return;
        self.focusedElement = [self currentField];
        if (![self destinationIsReady]) {
            [self displayError:@"Click a regular text field in the destination app and start dictation again."];
            return;
        }
        [self startRecording];
    });
}

- (id)currentField {
    AXUIElementRef app = AXUIElementCreateApplication(self.destination.processIdentifier);
    CFTypeRef field = NULL;
    AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &field);
    CFRelease(app);
    return CFBridgingRelease(field);
}

- (BOOL)destinationIsReady {
    if (!AXIsProcessTrusted() || IsSecureEventInputEnabled() || self.destination.terminated ||
        self.destination.processIdentifier != NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) return NO;
    id field = [self currentField];
    if (self.focusedElement && ![self.focusedElement isEqual:field]) return NO;
    if (field) {
        CFTypeRef subrole = NULL;
        AXUIElementCopyAttributeValue((__bridge AXUIElementRef)field, kAXSubroleAttribute, &subrole);
        if ([CFBridgingRelease(subrole) isEqual:(__bridge NSString *)kAXSecureTextFieldSubrole]) return NO;
    }
    return YES;
}

- (void)startRecording {
    if (!self.recognizer) {
        NSString *language = PersianOnly(self.selectedModel) ? @"fa" :
            [NSUserDefaults.standardUserDefaults stringForKey:@"language"];
        self.recognizer = [[VKRecognizer alloc] initWithModel:self.modelURL language:language];
    }
    self.started = [NSDate date];
    self.typedPhrase = NO;
    self.failed = NO;
    self.notice = nil;
    self.capture = [PhraseCapture new];
    __weak VoiceKey *app = self;
    self.capture.phrase = ^(NSData *samples) {
        [app.pending addObject:samples];
        [app processNextPhrase];
    };
    NSUInteger generation = ++self.generation;
    self.capture.interrupted = ^{
        if (app.generation == generation && app.phase == Recording) {
            app.notice = @"Microphone disconnected. Dictation stopped.";
            [app finishRecording];
        }
    };
    self.phase = Recording;
    NSError *error = nil;
    if (![self.capture start:&error]) {
        [self cancelCapture];
        [self displayError:error.localizedDescription];
        return;
    }
    [self cue:@"Pop"];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (app.destination.processIdentifier != NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) {
            [app cancelCapture];
            [app displayError:@"Dictation stopped because the active app changed."];
        } else [app refresh];
    }];
    [self refresh];
}

- (BOOL)typePhrase:(NSString *)text {
    if (![self destinationIsReady]) return NO;
    NSString *output = text;
    if (self.typedPhrase && ![[NSCharacterSet characterSetWithCharactersInString:@".,!?;:،؛؟…)]}"]
        characterIsMember:[text characterAtIndex:0]]) output = [@" " stringByAppendingString:text];
    pid_t pid = self.destination.processIdentifier;
    __block BOOL sent = YES;
    [output enumerateSubstringsInRange:NSMakeRange(0, output.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *character, NSRange range, NSRange enclosingRange, BOOL *stop) {
        NSMutableData *units = [NSMutableData dataWithLength:character.length * sizeof(UniChar)];
        [character getCharacters:units.mutableBytes range:NSMakeRange(0, character.length)];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
        if (down && up) {
            CGEventSetFlags(down, 0);
            CGEventSetFlags(up, 0);
            CGEventKeyboardSetUnicodeString(down, character.length, units.bytes);
            CGEventKeyboardSetUnicodeString(up, character.length, units.bytes);
            CGEventPostToPid(pid, down);
            CGEventPostToPid(pid, up);
        } else { sent = NO; *stop = YES; }
        if (down) CFRelease(down);
        if (up) CFRelease(up);
    }];
    self.typedPhrase = YES;
    return sent;
}

- (void)processNextPhrase {
    if (self.decoding) {
        NSUInteger bytes = 0;
        for (NSData *phrase in self.pending) bytes += phrase.length;
        if (self.phase == Recording && bytes > 30 * 16000 * sizeof(float)) {
            self.notice = @"Dictation stopped to finish queued speech. Choose a smaller model for lower latency.";
            dispatch_async(dispatch_get_main_queue(), ^{ if (self.phase == Recording) [self finishRecording]; });
        }
        return;
    }
    NSData *samples = self.pending.firstObject;
    if (!samples) {
        if (self.phase == Transcribing) {
            self.phase = Idle;
            if (!self.notice) self.notice = self.typedPhrase ? @"Dictation finished." : @"No speech detected.";
            self.destination = nil;
            self.focusedElement = nil;
            [self updateChanged];
        }
        return;
    }
    [self.pending removeObjectAtIndex:0];
    self.decoding = YES;
    VKRecognizer *recognizer = self.recognizer;
    NSUInteger generation = self.generation;
    dispatch_async(self.recognitionQueue, ^{
        NSError *error = nil;
        NSString *text = [recognizer recognize:samples.bytes count:samples.length / sizeof(float) error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.decoding = NO;
            if (!text || (text.length && ![self typePhrase:text])) {
                [self cancelCapture];
                [self displayError:error.localizedDescription ?: @"Typing stopped. Return to your text field and start dictation again."];
                return;
            }
            [self processNextPhrase];
        });
    });
}

- (void)cancelCapture {
    self.generation++;
    self.capture.phrase = nil;
    [self.capture stop];
    self.capture = nil;
    [self.timer invalidate];
    self.timer = nil;
    [self.pending removeAllObjects];
    self.decoding = NO;
    self.focusedElement = nil;
    self.destination = nil;
}

- (void)finishRecording {
    self.holding = NO;
    // Stop input first, including the partial phrase, then drain in capture order.
    self.phase = Transcribing;
    [self.timer invalidate];
    self.timer = nil;
    [self.capture stop];
    [self cue:@"Tink"];
    self.capture = nil;
    [self refresh];
    [self processNextPhrase];
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
        __attribute__((objc_precise_lifetime)) VoiceKey *delegate = [VoiceKey new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
