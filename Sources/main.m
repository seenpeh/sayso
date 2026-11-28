#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import "WhisperEngine.h"
#import "WhisperSmallImport.h"
#import "PhraseCapture.h"
#import "RecordingIndicator.h"
#import "SaysoStyle.h"
#import "ShortcutGesture.h"
#import "ReleaseUpdater.h"
#import <ApplicationServices/ApplicationServices.h>

enum { noModel = -1, whisperTurbo, nava, builtInCount };
static NSMutableArray<NSDictionary *> *models;
static NSString *const customModelsKey = @"customWhisperModels";

static NSDictionary *Model(NSString *title, NSString *filename, NSNumber *bytes, NSString *sha, NSString *url) {
    return @{@"title": title, @"filename": filename, @"bytes": bytes, @"sha": sha, @"url": url};
}

static void LoadModels(NSUserDefaults *defaults) {
    models = [NSMutableArray arrayWithArray:@[
        Model(@"Whisper Large v3 Turbo", @"ggml-large-v3-turbo-q5_0.bin", @574041195,
              @"394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
              @"https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"),
        Model(@"Nava · فارسی", @"ggml-nava-q5_0.bin", @574041195,
              @"e788c333480c50fbde2e4c7c145a46f90fed6e055892c9d81582a6d11af84b0f",
              @"https://huggingface.co/Nimruz/Nava-ggml/resolve/b4cc11c89fe8ec82619c8b4f97d1ea60c40ae6aa/ggml-nava-q5_0.bin")]];
    [models addObjectsFromArray:[defaults arrayForKey:customModelsKey] ?: @[]];
}
static NSString *const persianSmallRepo = @"C1Tech/whisper_small_persian";
static BOOL PersianOnly(NSInteger index) {
    return index == nava || (index >= builtInCount && [models[index][@"convertPersianSmall"] boolValue]);
}
static NSString *const selectedModelKey = @"selectedModelFilename";
static const int64_t dictationEventTag = 0x564b4559;
static NSString *const defaultShortcut = @"Right Shift";
static NSInteger LoadSelectedModel(NSUserDefaults *defaults) {
    NSString *filename = [defaults stringForKey:selectedModelKey];
    if (filename) {
        if (filename.length == 0) return noModel;
        for (NSInteger i = 0; i < (NSInteger)models.count; i++) {
            if ([filename isEqualToString:models[i][@"filename"]]) return i;
        }
        return whisperTurbo;
    }

    NSInteger model = [defaults boolForKey:@"hasLaunched"] ? whisperTurbo : nava;
    if ([defaults objectForKey:@"selectedModel"]) {
        NSInteger previous = [defaults integerForKey:@"selectedModel"];
        BOOL usesRecentOrder = [defaults boolForKey:@"removedTinyModels"];
        // Persian Base and Nava moved one slot when the original Tiny entry was removed.
        NSInteger previousPersianBase = usesRecentOrder ? 4 : 5;
        if (previous == noModel) model = noModel;
        else model = (previous == previousPersianBase || previous == previousPersianBase + 1) ? nava : whisperTurbo;
    }
    [defaults setObject:model == noModel ? @"" : models[model][@"filename"] forKey:selectedModelKey];
    return model;
}

typedef NS_ENUM(NSUInteger, Phase) {
    Idle, LookingUpModel, Downloading, CancelingDownload, Verifying, RequestingMicrophone, Recording, Transcribing
};

static NSStackView *Stack(NSUserInterfaceLayoutOrientation orientation, NSArray<NSView *> *views,
                          CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation;
    stack.spacing = spacing;
    return stack;
}

static NSStackView *Column(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *column = Stack(NSUserInterfaceLayoutOrientationVertical, views, spacing);
    column.alignment = NSLayoutAttributeLeading;
    for (NSView *view in views) {
        [view.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
    }
    return column;
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

static UInt32 ShortcutModifiers(NSEventModifierFlags flags) {
    return ((flags & NSEventModifierFlagCommand) ? cmdKey : 0) |
           ((flags & NSEventModifierFlagOption) ? optionKey : 0) |
           ((flags & NSEventModifierFlagControl) ? controlKey : 0) |
           ((flags & NSEventModifierFlagShift) ? shiftKey : 0);
}

static UInt32 ModifierForKey(UInt32 key) {
    switch (key) {
        case kVK_Command: case kVK_RightCommand: return cmdKey;
        case kVK_Shift: case kVK_RightShift: return shiftKey;
        case kVK_Option: case kVK_RightOption: return optionKey;
        case kVK_Control: case kVK_RightControl: return controlKey;
        default: return 0;
    }
}

static NSString *ShortcutProblem(UInt32 key, UInt32 mods, NSString *title, GestureKind gesture) {
    if (!mods) return @"Include Command, Option, Control, or Shift.";
    if (gesture != TapGesture) return nil;
    if (ModifierForKey(key) && !(mods & (mods - 1)))
        return @"Tap needs a combination. Use Hold or Double tap for a single modifier.";
    if (mods == shiftKey && [title hasPrefix:@"⇧"]) {
        NSString *name = [title substringFromIndex:1];
        if (name.length && NSEqualRanges([name rangeOfComposedCharacterSequenceAtIndex:0], NSMakeRange(0, name.length)) &&
            [name rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound)
            return @"Shift with a letter is reserved for typing capitals. Add another modifier.";
    }
    return nil;
}

@interface ModelLinkField : NSTextField
- (void)pasteLink:(id)sender;
@end

@implementation ModelLinkField
- (void)pasteLink:(id)sender {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSString *link = [board stringForType:NSPasteboardTypeURL];
    if (!link.length) link = [board stringForType:NSPasteboardTypeString];
    link = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!link.length) { NSBeep(); return; }
    self.stringValue = link;
    [self.window makeFirstResponder:self];
    [self.currentEditor setSelectedRange:NSMakeRange(link.length, 0)];
}
@end

@interface ShortcutButton : NSButton
@property (copy) void (^capture)(NSEvent *event);
@property (strong) NSEvent *capturedKeyDown;
@property (strong) NSEvent *capturedModifiers;
@property BOOL usedRegularKey;
@end

@implementation ShortcutButton
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (self.capture) {
        self.usedRegularKey = YES;
        self.capturedModifiers = nil;
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
- (void)flagsChanged:(NSEvent *)event {
    if (!self.capture) { [super flagsChanged:event]; return; }
    UInt32 flags = ShortcutModifiers(event.modifierFlags);
    if (!flags) {
        NSEvent *candidate = self.capturedModifiers;
        self.capturedModifiers = nil;
        self.usedRegularKey = NO;
        if (candidate) self.capture(candidate);
    } else if (!self.usedRegularKey && (flags & ModifierForKey(event.keyCode))) {
        self.capturedModifiers = event;
    }
}
- (BOOL)resignFirstResponder {
    self.capturedKeyDown = nil;
    void (^capture)(NSEvent *) = self.capture;
    if (capture) capture(nil);
    return [super resignFirstResponder];
}
@end

@interface VoiceKey : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSURLSessionDataDelegate>
@property Phase phase;
@property (strong) ShortcutGesture *gesture;
@property BOOL holding;
@property BOOL modifierBlocked;
@property (strong) NSMutableIndexSet *pressedKeys;
@property (strong) id globalMonitor;
@property (strong) id localMonitor;
@property (strong) NSSegmentedControl *modePicker;
@property (strong) NSSegmentedControl *gesturePicker;
@property (strong) NSButton *resetButton;
@property (strong) RecordingIndicator *indicator;
@property BOOL shortcutSession;
@property Phase indicatorPhase;
@property (strong) NSButton *checkButton;

@property NSInteger selectedModel;
@property OSStatus shortcutStatus;
@property EventHotKeyRef hotKey;
@property EventHandlerRef hotKeyHandler;
@property UInt32 shortcutID;
@property UInt32 shortcutKey;
@property UInt32 shortcutModifiers;
@property (copy) NSString *shortcutTitle;
@property (strong) NSWindow *settingsWindow;
@property (strong) NSTableView *settingsNav;
@property (strong) NSTabView *settingsTabs;
@property (strong) NSTextField *modeHint;
@property (strong) ShortcutButton *shortcutButton;
@property (strong) NSTextField *shortcutMessage;
@property (strong) NSSwitch *loginButton;
@property (strong) NSTextField *loginMessage;
@property (strong) NSButton *loginSettingsButton;
@property (strong) NSPopUpButton *settingsPicker;
@property (strong) NSButton *settingsDownload;
@property (strong) NSButton *unloadButton;
@property (strong) NSButton *removeButton;
@property (strong) NSButton *addModelButton;
@property (strong) NSTextField *languageHint;
@property (strong) NSStackView *modelActions;
@property (strong) NSTextField *settingsModelStatus;
@property (strong) NSProgressIndicator *settingsProgress;
@property (strong) NSPopUpButton *languagePicker;
@property (strong) ReleaseUpdater *updater;
@property (strong) NSButton *updateButton;
@property (strong) NSButton *settingsUpdate;
@property (strong) NSTextField *updateStatus;
@property (strong) NSTextField *popoverUpdateError;
@property (strong) NSDate *lastCheck;
@property (strong) NSTimer *updateTimer;
@property (copy) NSString *offeredVersion;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@property (strong) NSStackView *page;
@property (strong) NSTextField *headline;
@property (strong) NSTextField *detail;
@property (strong) NSTextField *modelLabel;
@property (strong) NSImageView *stateImage;
@property (strong) NSProgressIndicator *progress;
@property (strong) NSPopUpButton *modelPicker;
@property (strong) NSButton *recordButton;
@property (strong) NSButton *downloadButton;
@property (strong) NSURLSession *session;
@property (strong) NSURLSessionDataTask *downloadTask;
@property (copy) NSString *modelAccessToken;
@property (strong) NSData *modelVocabulary;
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
    if (!app.shortcutButton.capture && app.hotKey)
        [app.gesture edge:GetEventKind(event) == kEventHotKeyPressed at:GetEventTime(event)];
    return noErr;
}

@implementation VoiceKey

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"language": @"auto", @"recordingSounds": @YES}];
    LoadModels(defaults);
    self.selectedModel = LoadSelectedModel(defaults);
    self.recognitionQueue = dispatch_queue_create("sayso.recognition", DISPATCH_QUEUE_SERIAL);
    self.pending = [NSMutableArray array];
    self.updater = [ReleaseUpdater new];
    self.gesture = [ShortcutGesture new];
    [self loadShortcutSettings:defaults];
    [self saveShortcutSettings];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    [self buildPopover];

    self.indicator = [RecordingIndicator new];
    __weak VoiceKey *owner = self;
    self.gesture.activate = ^{
        VoiceKey *app = owner;
        if (app.gesture.mode == HoldRecording) [app holdEdge:YES];
        else [app toggleRecording:nil];
    };
    self.gesture.releaseHold = ^{ [owner holdEdge:NO]; };
    const EventTypeSpec events[] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
    InstallEventHandler(GetApplicationEventTarget(), ShortcutReleased, 2, events, (__bridge void *)self, &_hotKeyHandler);
    self.shortcutStatus = [self registerKey:self.shortcutKey modifiers:self.shortcutModifiers];
    self.pressedKeys = [NSMutableIndexSet indexSet];
    NSEventMask mask = NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp;
    self.globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [owner observeShortcut:event];
    }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        [owner observeShortcut:event];
        return event;
    }];

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
    [self.gesture cancel];
    if (self.globalMonitor) [NSEvent removeMonitor:self.globalMonitor];
    if (self.localMonitor) [NSEvent removeMonitor:self.localMonitor];
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

- (void)openReleases:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/seenpeh/sayso/releases"]];
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

- (void)populatePicker:(NSPopUpButton *)picker {
    [picker removeAllItems];
    for (NSDictionary *model in models) {
        [picker.menu addItemWithTitle:model[@"title"] action:nil keyEquivalent:@""];
    }
    [picker addItemWithTitle:@"No active model"];
    [picker addItemWithTitle:@"Add Hugging Face model…"];
}

- (void)saveCustomModels {
    NSArray *custom = [models subarrayWithRange:NSMakeRange(builtInCount, models.count - builtInCount)];
    [NSUserDefaults.standardUserDefaults setObject:custom forKey:customModelsKey];
    [self populatePicker:self.settingsPicker];
    [self populatePicker:self.modelPicker];
}

- (NSPopUpButton *)newModelPicker {
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self populatePicker:picker];
    [picker selectItemAtIndex:self.selectedModel == noModel ? (NSInteger)models.count : self.selectedModel];
    [picker setAccessibilityLabel:@"Speech recognition model"];
    picker.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    [picker setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
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
            self.shortcutSession = NO;
            [self refresh];
        }
    }
}

- (void)observeShortcut:(NSEvent *)event {
    if (self.shortcutButton.capture) {
        if (event.type == NSEventTypeKeyUp) [self.pressedKeys removeIndex:event.keyCode];
        return;
    }
    if (event.CGEvent && CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUnixProcessID) == getpid() &&
        CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData) == dictationEventTag) return;
    UInt32 mods = ShortcutModifiers(event.modifierFlags);
    if (!ModifierForKey(self.shortcutKey)) {
        // Carbon delivers the primary key. Releasing a required modifier also ends a hold.
        if (event.type == NSEventTypeFlagsChanged && self.gesture.pressed &&
            (mods & self.shortcutModifiers) != self.shortcutModifiers) {
            [self.gesture edge:NO at:event.timestamp];
        } else if (event.type == NSEventTypeKeyDown && event.keyCode != self.shortcutKey) {
            [self.gesture cancel];
        }
        return;
    }
    if (event.type == NSEventTypeKeyUp) {
        [self.pressedKeys removeIndex:event.keyCode];
        return;
    }
    if (event.type == NSEventTypeKeyDown) [self.pressedKeys addIndex:event.keyCode];
    if (self.pressedKeys.count || (mods & ~self.shortcutModifiers) ||
        (event.type == NSEventTypeFlagsChanged && !ModifierForKey(event.keyCode))) {
        self.modifierBlocked = mods != 0;
        [self.gesture cancel];
        return;
    }
    BOOL matches = mods == self.shortcutModifiers;
    BOOL single = !(mods & (mods - 1));
    if (matches && single && event.keyCode != self.shortcutKey) matches = NO;
    if (!self.modifierBlocked) [self.gesture edge:matches at:event.timestamp];
    if (!mods) self.modifierBlocked = NO;
}

- (OSStatus)registerKey:(UInt32)key modifiers:(UInt32)mods {
    if (self.hotKey && key == self.shortcutKey && mods == self.shortcutModifiers) return noErr;
    EventHotKeyRef replacement = NULL;
    EventHotKeyID identifier = {0x564b4559, self.shortcutID + 1};
    if (!ModifierForKey(key)) {
        if (!self.hotKeyHandler) return eventNotHandledErr;
        OSStatus status = RegisterEventHotKey(key, mods, identifier, GetApplicationEventTarget(),
                                              kEventHotKeyExclusive, &replacement);
        if (status != noErr) return status;
    }
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    self.hotKey = replacement;
    self.shortcutID = identifier.id;
    return noErr;
}

- (void)loadShortcutSettings:(NSUserDefaults *)defaults {
    if (![defaults objectForKey:@"shortcutKey"] && ![defaults objectForKey:@"recordingMode"]) {
        self.shortcutKey = kVK_RightShift;
        self.shortcutModifiers = shiftKey;
        self.shortcutTitle = defaultShortcut;
        self.gesture.kind = DoubleTapGesture;
        self.gesture.mode = HoldRecording;
        return;
    }
    self.shortcutKey = (UInt32)[defaults integerForKey:@"shortcutKey"];
    self.shortcutModifiers = (UInt32)[defaults integerForKey:@"shortcutModifiers"];
    self.shortcutTitle = [defaults stringForKey:@"shortcutTitle"];
    NSInteger legacyMode = [defaults integerForKey:@"recordingMode"];
    self.gesture.mode = legacyMode == 1 || legacyMode == 2 ? HoldRecording : ToggleRecording;
    NSInteger savedGesture = [defaults integerForKey:@"shortcutGesture"];
    self.gesture.kind = savedGesture >= TapGesture && savedGesture <= DoubleTapGesture ? savedGesture : TapGesture;
    if (![defaults objectForKey:@"shortcutGesture"] && (legacyMode == 2 || legacyMode == 3)) {
        self.gesture.kind = legacyMode == 2 ? HoldGesture : DoubleTapGesture;
        self.shortcutKey = kVK_Shift;
        self.shortcutModifiers = shiftKey;
        self.shortcutTitle = @"Left Shift";
    }
    if (ShortcutProblem(self.shortcutKey, self.shortcutModifiers, self.shortcutTitle, self.gesture.kind)) {
        self.shortcutKey = kVK_Space;
        self.shortcutModifiers = optionKey | shiftKey;
        self.shortcutTitle = @"⌥⇧Space";
    }
}

- (void)saveShortcutSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.gesture.mode forKey:@"recordingMode"];
    [defaults setInteger:self.gesture.kind forKey:@"shortcutGesture"];
    [defaults setInteger:self.shortcutKey forKey:@"shortcutKey"];
    [defaults setInteger:self.shortcutModifiers forKey:@"shortcutModifiers"];
    [defaults setObject:self.shortcutTitle forKey:@"shortcutTitle"];
}

- (void)changeMode:(NSSegmentedControl *)sender {
    [self.gesture cancel];
    if (sender == self.modePicker) self.gesture.mode = sender.selectedSegment;
    else {
        GestureKind kind = sender.selectedSegment;
        NSString *problem = ShortcutProblem(self.shortcutKey, self.shortcutModifiers, self.shortcutTitle, kind);
        if (problem) {
            sender.selectedSegment = self.gesture.kind;
            [self endShortcutCapture:@"Choose a Tap-compatible shortcut first, such as Option–Space."];
            return;
        }
        self.gesture.kind = kind;
    }
    [self endShortcutCapture:@"Click the shortcut to change it."];
    [self saveShortcutSettings];
    [self refresh];
}

- (void)soundSetting:(NSSwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:@"recordingSounds"];
}

- (void)cue:(NSString *)name {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"recordingSounds"]) return;
    NSSound *sound = [NSSound soundNamed:name];
    sound.volume = 0.13;
    [sound play];
}

static NSTextField *Caption(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

static NSView *FlexibleSpace(void) {
    NSView *space = [NSView new];
    [space setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return space;
}

static NSStackView *PreferenceRow(NSString *title, NSView *control) {
    NSTextField *name = Label(title, 13, NSFontWeightMedium, NSColor.labelColor);
    return Stack(NSUserInterfaceLayoutOrientationHorizontal, @[name, FlexibleSpace(), control], 10);
}

static NSBox *Rule(void) {
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    return line;
}

static NSBox *PreferenceGroup(NSArray<NSView *> *views) {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.contentViewMargins = NSZeroSize;
    box.cornerRadius = 12;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    box.fillColor = NSColor.controlBackgroundColor;
    NSStackView *stack = Column(views, 10);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-14]
    ]];
    return box;
}

- (void)buildSettings {
    self.shortcutButton = [[ShortcutButton alloc] initWithFrame:NSZeroRect];
    self.shortcutButton.title = self.shortcutTitle;
    self.shortcutButton.bezelStyle = NSBezelStyleRounded;
    self.shortcutButton.target = self;
    self.shortcutButton.action = @selector(captureShortcut:);
    [self.shortcutButton setAccessibilityLabel:@"Change global recording shortcut"];
    self.resetButton = [self button:@"Reset" action:@selector(resetShortcut:)];
    NSStackView *shortcut = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[self.shortcutButton, self.resetButton], 5);
    self.shortcutMessage = Caption(@"Click the shortcut, then press a new key combination.");

    self.modePicker = [NSSegmentedControl segmentedControlWithLabels:@[@"Toggle", @"Hold"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];
    self.gesturePicker = [NSSegmentedControl segmentedControlWithLabels:@[@"Tap", @"Hold", @"Double tap"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];
    self.modePicker.selectedSegment = self.gesture.mode;
    self.gesturePicker.selectedSegment = self.gesture.kind;
    [self.modePicker setAccessibilityLabel:@"Recording mode"];
    [self.gesturePicker setAccessibilityLabel:@"Shortcut gesture"];
    NSSwitch *sounds = [NSSwitch new];
    sounds.target = self;
    sounds.action = @selector(soundSetting:);
    sounds.state = [NSUserDefaults.standardUserDefaults boolForKey:@"recordingSounds"];
    [sounds setAccessibilityLabel:@"Recording sounds"];
    self.modeHint = Caption(@"");

    self.settingsPicker = [self newModelPicker];
    self.settingsDownload = [self button:@"Download" action:@selector(downloadModel:)];
    self.unloadButton = [self button:@"Unload" action:@selector(unloadModel:)];
    self.removeButton = [self button:@"Move to Trash" action:@selector(removeModel:)];
    self.addModelButton = [self button:@"Add model…" action:@selector(addCustomModel)];
    self.modelActions = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.settingsDownload, self.unloadButton, self.removeButton, FlexibleSpace()], 6);
    self.settingsModelStatus = Caption(@"");
    self.settingsProgress = [NSProgressIndicator new];
    self.settingsProgress.indeterminate = NO;
    self.settingsProgress.maxValue = 1;
    self.settingsProgress.controlSize = NSControlSizeSmall;
    [self.settingsProgress setAccessibilityLabel:@"Model download progress"];
    self.languagePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.languagePicker addItemsWithTitles:@[@"Detect language", @"Persian · فارسی"]];
    [self.languagePicker setAccessibilityLabel:@"Spoken language"];
    self.languageHint = Caption(@"");
    self.languagePicker.target = self;
    self.languagePicker.action = @selector(changeLanguage:);

    self.loginButton = [NSSwitch new];
    self.loginButton.target = self;
    self.loginButton.action = @selector(toggleLogin:);
    [self.loginButton setAccessibilityLabel:@"Start Sayso at login"];
    self.loginSettingsButton = [self button:@"Open Login Items…" action:@selector(openLoginSettings:)];
    self.loginMessage = Caption(@"");
    self.checkButton = [self button:@"Check for Updates…" action:@selector(checkUpdates:)];
    self.settingsUpdate = [self button:@"Install update" action:@selector(updateAction:)];
    self.updateStatus = Caption(@"");
    self.uninstallButton = [self button:@"Uninstall Sayso…" action:@selector(uninstall:)];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSButton *releases = [self button:@"GitHub Releases…" action:@selector(openReleases:)];
    NSStackView *updates = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.checkButton, self.settingsUpdate, FlexibleSpace()], 6);

    NSArray *groups = @[
        @[PreferenceGroup(@[PreferenceRow(@"Start Sayso at login", self.loginButton), self.loginMessage,
                            Stack(NSUserInterfaceLayoutOrientationHorizontal, @[self.loginSettingsButton, FlexibleSpace()], 4)]),
          PreferenceGroup(@[PreferenceRow([@"Sayso " stringByAppendingString:version], releases),
                            self.updateStatus, updates]),
          Stack(NSUserInterfaceLayoutOrientationHorizontal, @[FlexibleSpace(), self.uninstallButton], 0)],
        @[PreferenceGroup(@[PreferenceRow(@"Global shortcut", shortcut), self.shortcutMessage, Rule(),
                            PreferenceRow(@"Shortcut gesture", self.gesturePicker), Rule(),
                            PreferenceRow(@"Recording mode", self.modePicker), self.modeHint]),
          PreferenceGroup(@[PreferenceRow(@"Recording sounds", sounds)])],
        @[PreferenceGroup(@[PreferenceRow(@"Dictation model", self.settingsPicker), self.settingsModelStatus,
                            self.settingsProgress, self.modelActions]),
          PreferenceGroup(@[PreferenceRow(@"Spoken language", self.languagePicker), self.languageHint]),
          PreferenceGroup(@[PreferenceRow(@"Custom models", self.addModelButton),
                            Caption(@"Add a whisper.cpp model from a Hugging Face link.")])]
    ];

    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 730, 468)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"Sayso Settings";
    self.settingsWindow.backgroundColor = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            isEqual:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithSRGBRed:.12 green:.14 blue:.14 alpha:1] :
                      [NSColor colorWithSRGBRed:.97 green:.965 blue:.945 alpha:1];
    }];
    self.settingsWindow.titleVisibility = NSWindowTitleHidden;
    self.settingsWindow.titlebarAppearsTransparent = YES;
    self.settingsWindow.movableByWindowBackground = YES;
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.delegate = self;
    NSView *content = self.settingsWindow.contentView;
    content.wantsLayer = YES;

    NSVisualEffectView *sidebar = [NSVisualEffectView new];
    sidebar.material = NSVisualEffectMaterialSidebar;
    sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:sidebar];
    NSStackView *brand = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[SaysoMark(38), Label(@"Sayso", 21, NSFontWeightSemibold, NSColor.labelColor)], 9);
    [sidebar addSubview:brand];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *titles = @[@"General", @"Shortcut", @"Models"];
    self.settingsNav = [NSTableView new];
    self.settingsNav.style = NSTableViewStyleSourceList;
    self.settingsNav.backgroundColor = NSColor.clearColor;
    self.settingsNav.headerView = nil;
    self.settingsNav.rowHeight = 33;
    self.settingsNav.intercellSpacing = NSMakeSize(0, 3);
    self.settingsNav.allowsEmptySelection = NO;
    self.settingsNav.dataSource = self;
    self.settingsNav.delegate = self;
    [self.settingsNav setAccessibilityLabel:@"Settings sections"];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"section"];
    column.width = 152;
    [self.settingsNav addTableColumn:column];
    NSScrollView *navScroll = [NSScrollView new];
    navScroll.drawsBackground = NO;
    navScroll.documentView = self.settingsNav;
    navScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:navScroll];

    self.settingsTabs = [NSTabView new];
    self.settingsTabs.tabViewType = NSNoTabsNoBorder;
    self.settingsTabs.drawsBackground = NO;
    self.settingsTabs.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < groups.count; i++) {
        NSString *title = titles[i];
        NSTextField *heading = Label(title, 27, NSFontWeightBold, NSColor.labelColor);
        heading.font = SaysoHeadingFont(29);
        NSStackView *section = Column([@[heading] arrayByAddingObjectsFromArray:groups[i]], 12);
        [section setCustomSpacing:20 afterView:heading];
        section.translatesAutoresizingMaskIntoConstraints = NO;
        NSTabViewItem *tab = [[NSTabViewItem alloc] initWithIdentifier:title];
        tab.label = title;
        tab.view = [NSView new];
        [tab.view addSubview:section];
        [NSLayoutConstraint activateConstraints:@[
            [section.leadingAnchor constraintEqualToAnchor:tab.view.leadingAnchor constant:28],
            [section.trailingAnchor constraintEqualToAnchor:tab.view.trailingAnchor constant:-28],
            [section.topAnchor constraintEqualToAnchor:tab.view.topAnchor constant:46]
        ]];
        [self.settingsTabs addTabViewItem:tab];
    }
    [content addSubview:self.settingsTabs];
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:content.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:180],
        [brand.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:20],
        [brand.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:46],
        [navScroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:4],
        [navScroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-4],
        [navScroll.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:18],
        [navScroll.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor],
        [self.settingsTabs.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [self.settingsTabs.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.settingsTabs.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.settingsTabs.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [self.settingsNav reloadData];
    [self.settingsNav selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self.settingsWindow center];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return 3; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSArray *icons = @[@"gearshape", @"keyboard", @"square.3.layers.3d"];
    NSString *title = [self.settingsTabs tabViewItemAtIndex:row].label;
    NSTableCellView *cell = [NSTableCellView new];
    NSImageView *icon = [NSImageView imageViewWithImage:Symbol(icons[row], nil, 15)];
    [icon.widthAnchor constraintEqualToConstant:19].active = YES;
    NSTextField *name = Label(title, 13, NSFontWeightMedium, NSColor.labelColor);
    cell.textField = name;
    cell.imageView = icon;
    NSStackView *rowView = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[icon, name], 8);
    rowView.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:rowView];
    [rowView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:5].active = YES;
    [rowView.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor].active = YES;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.settingsNav.selectedRow;
    if (row < 0 || row >= self.settingsTabs.numberOfTabViewItems) return;
    NSInteger previous = [self.settingsTabs indexOfTabViewItem:self.settingsTabs.selectedTabViewItem];
    if (previous == row) return;
    if (self.shortcutButton.capture) [self endShortcutCapture:@"Click the shortcut to change it."];
    [self.settingsTabs selectTabViewItemAtIndex:row];
    SaysoReveal(self.settingsTabs.selectedTabViewItem.view, row > previous ? 7 : -7);
}

- (void)captureShortcut:(id)sender {
    if (self.shortcutButton.capture) return;
    [self.gesture cancel];
    if (self.hotKey) {
        UnregisterEventHotKey(self.hotKey);
        self.hotKey = NULL;
    }
    __weak VoiceKey *app = self;
    self.shortcutButton.capture = ^(NSEvent *event) { [app handleShortcutCapture:event]; };
    if ([self.settingsWindow makeFirstResponder:self.shortcutButton]) {
        self.shortcutButton.title = @"Press shortcut…";
        self.shortcutMessage.stringValue = self.gesture.kind == TapGesture ?
            @"Press a combination with a modifier. Esc cancels." : @"Press a modifier or a modified shortcut. Esc cancels.";
    } else {
        [self endShortcutCapture:@"Click the shortcut again to start recording keys."];
    }
}

- (void)endShortcutCapture:(NSString *)message {
    if (self.shortcutButton.capture && !self.hotKey && !ModifierForKey(self.shortcutKey)) {
        self.shortcutStatus = [self registerKey:self.shortcutKey modifiers:self.shortcutModifiers];
        if (self.shortcutStatus != noErr) message = @"Shortcut unavailable. Try a different combination.";
    }
    self.shortcutButton.capture = nil;
    self.shortcutButton.capturedKeyDown = nil;
    self.shortcutButton.capturedModifiers = nil;
    self.shortcutButton.usedRegularKey = NO;
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
    if (event.type == NSEventTypeFlagsChanged) {
        if (!(modifiers & (modifiers - 1))) {
            NSDictionary *names = @{@(kVK_Shift): @"Left Shift", @(kVK_RightShift): @"Right Shift",
                @(kVK_Option): @"Left Option", @(kVK_RightOption): @"Right Option",
                @(kVK_Control): @"Left Control", @(kVK_RightControl): @"Right Control",
                @(kVK_Command): @"Left Command", @(kVK_RightCommand): @"Right Command"};
            if (!names[@(event.keyCode)]) return;
            [title setString:names[@(event.keyCode)]];
        }
        [self setShortcutKey:event.keyCode modifiers:modifiers title:title];
        return;
    }
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
    if (key.length == 0 ||
        [NSCharacterSet.controlCharacterSet characterIsMember:displayCharacter] ||
        (displayCharacter >= 0xF700 && displayCharacter <= 0xF8FF)) {
        self.shortcutMessage.stringValue = @"Choose a printable key, navigation key, or function key with a modifier.";
        return;
    }
    [title appendString:key.uppercaseString.length == 1 ? key.uppercaseString : key];
    [self setShortcutKey:event.keyCode modifiers:modifiers title:title];
}

- (void)resetShortcut:(id)sender {
    self.gesture.kind = DoubleTapGesture;
    self.gesture.mode = HoldRecording;
    self.modePicker.selectedSegment = HoldRecording;
    self.gesturePicker.selectedSegment = DoubleTapGesture;
    [self setShortcutKey:kVK_RightShift modifiers:shiftKey title:defaultShortcut];
}

- (void)setShortcutKey:(UInt32)key modifiers:(UInt32)mods title:(NSString *)title {
    NSString *problem = ShortcutProblem(key, mods, title, self.gesture.kind);
    if (problem) {
        self.shortcutMessage.stringValue = problem;
        return;
    }
    if ([self registerKey:key modifiers:mods] != noErr) {
        [self endShortcutCapture:@"Shortcut unavailable. Try a different combination."];
        return;
    }
    [self.gesture cancel];
    self.modifierBlocked = NO;
    [self.pressedKeys removeAllIndexes];
    self.shortcutStatus = noErr;
    self.shortcutKey = key;
    self.shortcutModifiers = mods;
    self.shortcutTitle = title;
    [self saveShortcutSettings];
    [self endShortcutCapture:@"Shortcut updated."];
    [self refresh];
}

- (void)updateLoginControls {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginButton.state = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginMessage.hidden = status != SMAppServiceStatusRequiresApproval;
    self.loginMessage.stringValue = status == SMAppServiceStatusRequiresApproval
        ? @"Allow Sayso in Login Items to finish enabling this option." : @"";
}

- (void)toggleLogin:(NSSwitch *)sender {
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL ok = sender.state == NSControlStateValueOn ? [service registerAndReturnError:&error]
                                                    : [service unregisterAndReturnError:&error];
    [self updateLoginControls];
    if (!ok && service.status != SMAppServiceStatusRequiresApproval) {
        self.loginMessage.hidden = NO;
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
    const CGFloat width = 340;
    NSButton *settings = [self button:@"Settings…" action:@selector(showSettings:)];
    settings.image = Symbol(@"gearshape", nil, 12);
    settings.imagePosition = NSImageLeading;
    settings.controlSize = NSControlSizeSmall;
    NSButton *quit = [self button:@"Quit" action:@selector(quit:)];
    quit.bordered = NO;
    quit.font = [NSFont systemFontOfSize:12];
    [quit setAccessibilityLabel:@"Quit Sayso"];
    NSStackView *header = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[SaysoMark(38), Label(@"Sayso", 21, NSFontWeightSemibold, NSColor.labelColor),
          FlexibleSpace(), settings, quit], 6);

    self.headline = [NSTextField wrappingLabelWithString:@""];
    self.headline.font = SaysoHeadingFont(24);
    self.headline.textColor = [NSColor colorWithSRGBRed:1 green:.98 blue:.92 alpha:1];
    self.stateImage = [NSImageView new];
    [self.stateImage.widthAnchor constraintEqualToConstant:20].active = YES;
    [self.stateImage.heightAnchor constraintEqualToConstant:21].active = YES;
    [self.stateImage setAccessibilityElement:NO];
    NSStackView *status = Stack(NSUserInterfaceLayoutOrientationHorizontal,
        @[self.stateImage, self.headline], 8);
    [self.headline setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.detail = [NSTextField wrappingLabelWithString:@""];
    self.detail.font = [NSFont systemFontOfSize:13];
    self.detail.textColor = [NSColor colorWithSRGBRed:.85 green:.90 blue:.86 alpha:1];

    self.recordButton = [DictationActionButton buttonWithTitle:@"Start dictation" target:self action:@selector(toggleRecording:)];
    self.downloadButton = [DictationActionButton buttonWithTitle:@"Download model" target:self action:@selector(downloadModel:)];
    for (NSButton *button in @[self.recordButton, self.downloadButton]) {
        button.controlSize = NSControlSizeLarge;
        button.imagePosition = NSImageLeading;
        button.bordered = NO;
        button.focusRingType = NSFocusRingTypeExterior;
    }
    NSStackView *cardContent = Column(@[status, self.detail, self.downloadButton, self.recordButton], 6);
    [cardContent setCustomSpacing:14 afterView:self.detail];
    VoiceCard *card = [VoiceCard new];
    cardContent.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardContent];
    [NSLayoutConstraint activateConstraints:@[
        [cardContent.topAnchor constraintEqualToAnchor:card.topAnchor constant:30],
        [cardContent.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [cardContent.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [cardContent.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];

    self.modelPicker = [self newModelPicker];
    NSStackView *modelRow = PreferenceRow(@"Speech model", self.modelPicker);
    self.modelLabel = Caption(@"");
    self.progress = [NSProgressIndicator new];
    self.progress.indeterminate = NO;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.maxValue = 1;
    [self.progress setAccessibilityLabel:@"Model download progress"];
    self.updateButton = [self button:@"Install update…" action:@selector(updateAction:)];
    self.popoverUpdateError = Caption(@"");
    self.page = Column(@[header, card, modelRow, self.modelLabel, self.progress, self.updateButton, self.popoverUpdateError], 8);
    [self.page setCustomSpacing:15 afterView:card];
    [self.page setCustomSpacing:4 afterView:modelRow];
    self.page.translatesAutoresizingMaskIntoConstraints = NO;
    NSViewController *controller = [NSViewController new];
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width + 32, 320)];
    controller.view = content;
    [content addSubview:self.page];
    [NSLayoutConstraint activateConstraints:@[
        [self.page.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [self.page.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.page.widthAnchor constraintEqualToConstant:width]
    ]];
    self.popover = [NSPopover new];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = controller;
}

- (void)showPopover {
    if (self.phase == Recording || self.phase == RequestingMicrophone || self.phase == Transcribing) return;
    if (!self.popover.shown && self.statusItem.button.window) {
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (front.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
            self.popoverDestination = front;
        [self refresh];
        self.popover.animates = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
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
    return [[self modelsFolder] URLByAppendingPathComponent:models[self.selectedModel][@"filename"]];
}

- (BOOL)modelExists {
    if (self.selectedModel == noModel) return NO;
    NSNumber *size = nil;
    [[self modelURL] getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSDictionary *model = models[self.selectedModel];
    NSNumber *expected = model[@"convertPersianSmall"] ? model[@"installedBytes"] : model[@"bytes"];
    return expected && size && [size isEqualToNumber:expected];
}

- (NSString *)shortcutInstructions {
    NSString *key = self.shortcutTitle;
    if (self.gesture.mode == HoldRecording) {
        if (self.gesture.kind == DoubleTapGesture)
            return [NSString stringWithFormat:@"Double-tap %@ and hold the second press. Release to finish.", key];
        if (self.gesture.kind == HoldGesture)
            return [NSString stringWithFormat:@"Hold %@ until recording starts. Release to finish.", key];
        return [NSString stringWithFormat:@"Hold %@ while you speak. Release to finish.", key];
    }
    NSString *verb = self.gesture.kind == DoubleTapGesture ? @"Double-tap" :
                     self.gesture.kind == HoldGesture ? @"Hold" : @"Press";
    return [NSString stringWithFormat:@"%@ %@ to start. Repeat to finish.", verb, key];
}

- (void)refresh {
    if (self.indicatorPhase != self.phase) {
        if (self.phase == Recording) [self.indicator showListening];
        else if (self.phase == Transcribing) [self.indicator showProcessing];
        else [self.indicator hide];
        self.indicatorPhase = self.phase;
    }
    BOOL hasSelection = self.selectedModel != noModel;
    BOOL installed = [self modelExists];
    BOOL downloading = self.phase == Downloading || self.phase == CancelingDownload || self.phase == Verifying;
    AVAuthorizationStatus mic = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    BOOL keyboardAccess = AXIsProcessTrusted();
    NSString *instructions = [self shortcutInstructions];
    NSString *title = installed ? @"Ready to dictate" : @"Set up dictation";
    NSString *subtitle = installed ? instructions :
                                    @"Download the selected speech model to dictate on this Mac.";
    NSString *stateSymbol = installed ? @"waveform" : @"arrow.down.circle";
    if (!hasSelection) {
        title = @"No active model";
        subtitle = @"Choose a speech model below to start dictating.";
        stateSymbol = @"waveform";
    }
    NSString *menuSymbol = nil;
    NSColor *tint = NSColor.controlAccentColor;

    switch (self.phase) {
        case Idle:
            if (self.failed) {
                title = @"Needs attention";
                stateSymbol = @"exclamationmark.circle";
                subtitle = self.notice ?: @"Try again.";
            } else if (installed && mic == AVAuthorizationStatusRestricted) {
                title = @"Microphone restricted";
                subtitle = @"This Mac restricts microphone access. Contact your administrator.";
                stateSymbol = @"mic.slash";
            } else if (installed && !keyboardAccess) {
                title = @"Allow keyboard access";
                subtitle = @"Enable Sayso in Accessibility so it can type into your text field.";
                stateSymbol = @"keyboard";
            } else if (installed && mic == AVAuthorizationStatusDenied) {
                title = @"Allow microphone access";
                subtitle = @"Enable Sayso in Microphone settings to record your voice.";
                stateSymbol = @"mic.slash";
            } else if (installed && self.shortcutStatus != noErr) {
                subtitle = @"Click Start dictation, or choose a different shortcut in Settings.";
            } else if (self.notice) subtitle = self.notice;
            break;
        case Downloading:
        case CancelingDownload:
            title = self.phase == Downloading ? @"Downloading model…" : @"Pausing download…";
            subtitle = self.notice ?: @"You can close this popover while the download runs.";
            break;
        case LookingUpModel:
            title = @"Looking up model files…";
            subtitle = @"Reading the Hugging Face repository.";
            break;
        case Verifying:
            title = @"Verifying model…";
            subtitle = [models[self.selectedModel][@"convertPersianSmall"] boolValue] ? @"Verifying and converting Whisper Small on this Mac." : @"Checking the downloaded model file.";
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
    self.statusItem.button.image = menuSymbol ? Symbol(menuSymbol, menuDescription, 14) : [NSImage imageNamed:@"TypewriterTemplate"];
    self.statusItem.button.toolTip = menuDescription;
    [self.statusItem.button setAccessibilityLabel:menuDescription];
    self.statusItem.button.contentTintColor = self.phase == Recording ? tint : nil;
    self.stateImage.image = Symbol(stateSymbol, nil, 19);
    self.stateImage.contentTintColor = [NSColor colorWithSRGBRed:1 green:.84 blue:.39 alpha:1];
    self.headline.stringValue = title;
    self.detail.stringValue = subtitle;
    self.recordButton.title = self.phase == Recording ? @"Stop dictation" :
        mic == AVAuthorizationStatusRestricted ? @"Microphone restricted" :
        !keyboardAccess ? @"Enable keyboard access…" :
        mic == AVAuthorizationStatusDenied ? @"Open Microphone settings…" : @"Start dictation";
    NSString *recordIcon = self.phase == Recording ? @"stop.fill" :
        !keyboardAccess ? @"keyboard" : mic == AVAuthorizationStatusDenied ? @"gearshape" : @"mic.fill";
    self.recordButton.image = Symbol(recordIcon, nil, 13);
    self.recordButton.enabled = (installed && self.phase == Idle && !self.updater.installing &&
                                 mic != AVAuthorizationStatusRestricted) || self.phase == Recording;
    self.recordButton.hidden = !installed || downloading;
    BOOL available = self.phase == Idle && !self.updater.installing;
    self.modelPicker.enabled = self.settingsPicker.enabled = available;
    self.addModelButton.enabled = available;
    self.languagePicker.enabled = hasSelection && available && !PersianOnly(self.selectedModel);
    self.languageHint.stringValue = !hasSelection ? @"Choose a model to set its spoken language." :
        PersianOnly(self.selectedModel) ? @"This model is trained for Persian and always uses this language." :
        @"Choose Persian to skip automatic language detection.";
    [self.languagePicker selectItemAtIndex:PersianOnly(self.selectedModel) ||
        [[NSUserDefaults.standardUserDefaults stringForKey:@"language"] isEqual:@"fa"] ? 1 : 0];
    NSString *updateTitle = self.updater.availableVersion ?
        [NSString stringWithFormat:@"Install %@ and restart", self.updater.availableVersion] : @"Check for Updates…";
    self.updateButton.hidden = !self.updater.availableVersion;
    self.updateButton.title = self.updater.installing ? @"Installing update…" : updateTitle;
    self.settingsUpdate.title = self.updateButton.title;
    self.settingsUpdate.hidden = !self.updater.availableVersion;
    self.checkButton.enabled = !self.updater.installing && !self.updater.checking;
    self.checkButton.title = self.updater.checking ? @"Checking…" : @"Check for Updates…";
    self.modeHint.stringValue = instructions;
    self.modePicker.enabled = self.gesturePicker.enabled = available;
    self.shortcutButton.enabled = self.resetButton.enabled = available;
    self.updateButton.enabled = self.settingsUpdate.enabled = available && !self.updater.checking;
    self.updateStatus.stringValue = self.updater.status;
    self.updateButton.toolTip = self.updater.status;
    self.popoverUpdateError.stringValue = self.updater.installError ?: @"";
    self.popoverUpdateError.hidden = self.updater.installError == nil;
    if (self.updater.installing) {
        self.detail.stringValue = self.updater.status;
        self.headline.stringValue = @"Updating Sayso…";
    }
    NSInteger pickerIndex = hasSelection ? self.selectedModel : (NSInteger)models.count;
    [self.modelPicker selectItemAtIndex:pickerIndex];
    [self.settingsPicker selectItemAtIndex:pickerIndex];
    self.modelPicker.toolTip = self.settingsPicker.toolTip = self.modelPicker.titleOfSelectedItem;
    self.downloadButton.hidden = !hasSelection || (installed && !downloading);
    BOOL resumable = hasSelection && !installed && [self partialSize] > 0;
    self.downloadButton.title = self.phase == Verifying ? @"Verifying model…" : self.phase == CancelingDownload ?
        @"Pausing download…" : self.phase == Downloading ? @"Pause download" : resumable ? @"Resume download" : @"Download model";
    self.settingsDownload.title = self.downloadButton.title;
    self.downloadButton.image = Symbol(self.phase == Downloading ? @"pause.fill" : @"arrow.down.circle", nil, 13);
    self.uninstallButton.enabled = available;
    self.downloadButton.enabled = available || self.phase == Downloading;
    if (downloading) self.modelLabel.stringValue = [NSString stringWithFormat:@"%.0f%% · %@",
        100 * self.downloadedFraction, [NSByteCountFormatter stringFromByteCount:[models[self.selectedModel][@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    else if (hasSelection) {
        NSString *description = PersianOnly(self.selectedModel) ? @"Persian dictation" :
            self.selectedModel >= builtInCount ? @"Custom model" : @"Multilingual";
        self.modelLabel.stringValue = [NSString stringWithFormat:@"%@ · %@%@", description,
            [NSByteCountFormatter stringFromByteCount:[models[self.selectedModel][@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], installed ? @" · Installed" : @""];
    } else self.modelLabel.stringValue = @"";
    self.modelLabel.hidden = !hasSelection;
    self.progress.hidden = !downloading;
    self.progress.doubleValue = self.downloadedFraction;
    [self.page layoutSubtreeIfNeeded];
    self.popover.contentSize = NSMakeSize(NSWidth(self.page.frame) + 32, ceil(self.page.fittingSize.height) + 30);
    self.settingsDownload.hidden = self.downloadButton.hidden;
    self.settingsDownload.enabled = !self.downloadButton.hidden && self.downloadButton.enabled;
    self.unloadButton.hidden = !installed || downloading;
    self.unloadButton.enabled = available;
    self.unloadButton.toolTip = @"Stop using this model and keep its downloaded file.";
    BOOL custom = self.selectedModel >= builtInCount;
    self.removeButton.title = custom ? @"Remove model" : @"Move to Trash";
    self.removeButton.hidden = !(installed || custom) || downloading;
    self.removeButton.enabled = available;
    self.modelActions.hidden = !hasSelection;
    NSString *modelStatus = hasSelection ? self.modelLabel.stringValue : @"Choose a model to start dictating.";
    if (hasSelection && !installed && !downloading) {
        modelStatus = [modelStatus stringByAppendingString:resumable ? @" · Partially downloaded" : @" · Download required"];
    }
    if (self.notice && (self.failed || !installed || self.phase == LookingUpModel)) {
        modelStatus = [NSString stringWithFormat:@"%@\n%@", modelStatus, self.notice];
    }
    self.settingsModelStatus.stringValue = modelStatus;
    self.settingsProgress.hidden = !downloading;
    self.settingsProgress.doubleValue = self.downloadedFraction;
}

- (void)addCustomModel {
    if (self.phase != Idle || self.updater.installing) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Add a Hugging Face model";
    alert.informativeText = @"Paste a Hugging Face link to a whisper.cpp GGML model (.bin) or C1Tech/whisper_small_persian.";
    ModelLinkField *field = [[ModelLinkField alloc] initWithFrame:NSZeroRect];
    field.placeholderString = @"https://huggingface.co/owner/model";
    NSButton *paste = [NSButton buttonWithTitle:@"Paste Link" target:field action:@selector(pasteLink:)];
    paste.keyEquivalent = @"v";
    paste.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSStackView *row = Stack(NSUserInterfaceLayoutOrientationHorizontal, @[field, paste], 8);
    row.frame = NSMakeRect(0, 0, 400, 30);
    [field setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    alert.accessoryView = row;
    [NSApp activate];
    alert.window.initialFirstResponder = field;
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *link = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *url = [NSURL URLWithString:link];
    NSArray<NSString *> *parts = url.path.pathComponents;
    BOOL repository = parts.count == 3;
    BOOL file = parts.count >= 6 && [@[@"blob", @"resolve"] containsObject:parts[3]];
    BOOL tree = parts.count == 5 && [parts[3] isEqualToString:@"tree"];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || ![url.host.lowercaseString isEqualToString:@"huggingface.co"] ||
        !(repository || file || tree)) {
        [self displayError:@"Paste a Hugging Face repository link or a link to a .bin model file."];
        return;
    }
    NSString *repo = [NSString stringWithFormat:@"%@/%@", parts[1], parts[2]];
    NSString *revision = repository ? @"main" : parts[4];
    NSString *path = file ? [[parts subarrayWithRange:NSMakeRange(5, parts.count - 5)] componentsJoinedByString:@"/"] : nil;
    NSURLComponents *api = [NSURLComponents componentsWithString:@"https://huggingface.co"];
    api.path = [NSString stringWithFormat:@"/api/models/%@/revision/%@", repo, revision];
    api.query = @"blobs=true";
    self.phase = LookingUpModel;
    self.notice = @"Looking up model files…";
    [self refresh];
    [[NSURLSession.sharedSession dataTaskWithURL:api.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.phase = Idle;
            self.notice = nil;
            if (error || ((NSHTTPURLResponse *)response).statusCode != 200 || ![info isKindOfClass:NSDictionary.class]) {
                [self displayError:error.localizedDescription ?: @"Could not read this public Hugging Face repository."];
                return;
            }
            [self chooseModelFromRepository:repo info:info path:path];
        });
    }] resume];
}

- (void)chooseModelFromRepository:(NSString *)repo info:(NSDictionary *)info path:(NSString *)path {
    NSMutableArray *choices = [NSMutableArray array];
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26) pullsDown:NO];
    for (NSDictionary *entry in info[@"siblings"]) {
        NSString *name = entry[@"rfilename"];
        NSDictionary *lfs = entry[@"lfs"];
        BOOL persianWeights = [repo caseInsensitiveCompare:persianSmallRepo] == NSOrderedSame && [name isEqual:@"model.safetensors"];
        if ((!persianWeights && ![name.pathExtension.lowercaseString isEqualToString:@"bin"]) || (path && ![name isEqualToString:path]) ||
            [lfs[@"size"] longLongValue] <= 0 || [lfs[@"sha256"] length] != 64) continue;
        [choices addObject:entry];
        [picker addItemWithTitle:name];
    }
    if (!choices.count || ![info[@"sha"] length]) {
        [self displayError:@"No downloadable GGML .bin model was found at this link."];
        return;
    }
    if (choices.count > 1) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Choose a whisper.cpp model file";
        alert.informativeText = repo;
        alert.accessoryView = picker;
        [alert addButtonWithTitle:@"Download"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) { [self refresh]; return; }
    }
    NSDictionary *entry = choices[picker.indexOfSelectedItem];
    NSString *name = entry[@"rfilename"];
    NSURLComponents *source = [NSURLComponents componentsWithString:@"https://huggingface.co"];
    source.path = [NSString stringWithFormat:@"/%@/resolve/%@/%@", repo, info[@"sha"], name];
    NSDictionary *lfs = entry[@"lfs"];
    NSUInteger index = [models indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        return [item[@"sha"] isEqual:lfs[@"sha256"]];
    }];
    if (index == NSNotFound) {
        NSString *title = [NSString stringWithFormat:@"%@ · %@", name.lastPathComponent, repo];
        NSString *filename = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"bin"];
        BOOL convert = [name isEqual:@"model.safetensors"];
        NSMutableDictionary *model = [Model(convert ? repo : title, filename, lfs[@"size"], lfs[@"sha256"], source.URL.absoluteString) mutableCopy];
        if (convert) model[@"convertPersianSmall"] = @YES;
        if ([info[@"gated"] isEqual:@"auto"] || [info[@"gated"] isEqual:@"manual"] || [info[@"gated"] isEqual:@YES])
            model[@"gated"] = @YES;
        [models addObject:model];
        [self saveCustomModels];
        index = models.count - 1;
    }
    [self activateModel:index];
    [self downloadModel:nil];
}

- (void)selectModel:(NSPopUpButton *)sender {
    if (self.phase != Idle || self.updater.installing) return;
    NSInteger index = sender.indexOfSelectedItem;
    if (index == (NSInteger)models.count + 1) {
        [self refresh];
        [self addCustomModel];
        return;
    }
    if (index < 0 || index > (NSInteger)models.count) return;
    [self activateModel:index == (NSInteger)models.count ? noModel : index];
}

- (void)activateModel:(NSInteger)index {
    self.recognizer = nil;
    self.selectedModel = index;
    [NSUserDefaults.standardUserDefaults setObject:index == noModel ? @"" : models[index][@"filename"]
                                            forKey:selectedModelKey];
    self.notice = nil;
    self.failed = NO;
    [self refresh];
}

- (void)unloadModel:(id)sender {
    if (self.phase == Idle) [self activateModel:noModel];
}

- (void)removeModel:(id)sender {
    if (self.phase != Idle || self.selectedModel == noModel) return;
    if (self.selectedModel >= builtInCount) {
        NSFileManager *files = NSFileManager.defaultManager;
        for (NSURL *url in @[self.partialURL, self.modelURL]) {
            NSError *error = nil;
            if ([files fileExistsAtPath:url.path] && ![files trashItemAtURL:url resultingItemURL:NULL error:&error]) {
                [self displayError:error.localizedDescription];
                return;
            }
        }
        [models removeObjectAtIndex:self.selectedModel];
        [self saveCustomModels];
        [self activateModel:noModel];
        return;
    }
    if (![self modelExists]) return;
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
    if (self.shortcutSession) [self.indicator showNotice:message];
    else if (!self.settingsWindow.keyWindow) [self showPopover];
    self.shortcutSession = self.holding = NO;
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
    NSDictionary *model = models[self.selectedModel];
    if ([model[@"gated"] boolValue]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Access this Hugging Face model";
        alert.informativeText = @"Request access on the model page. After approval, enter a Hugging Face read token with permission to download this model.";
        NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
        field.placeholderString = @"Hugging Face read token";
        alert.accessoryView = field;
        alert.window.initialFirstResponder = field;
        [alert addButtonWithTitle:@"Download"];
        [alert addButtonWithTitle:@"Open model page"];
        [alert addButtonWithTitle:@"Cancel"];
        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            NSURL *page = [NSURL URLWithString:model[@"url"]];
            NSArray *parts = page.path.pathComponents;
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://huggingface.co/%@/%@", parts[1], parts[2]]]];
        }
        if (response != NSAlertFirstButtonReturn) return;
        self.modelAccessToken = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!self.modelAccessToken.length) { [self displayError:@"Enter your Hugging Face read token to download this model."]; return; }
    }
    if ([model[@"convertPersianSmall"] boolValue]) {
        self.phase = LookingUpModel;
        [self refresh];
        NSURL *weights = [NSURL URLWithString:model[@"url"]];
        NSURL *url = [[weights URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"vocab.json"];
        NSMutableURLRequest *request = [self modelRequest:url];
        // A completion-handler task uses the same ephemeral session and redirect policy as the weights.
        [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            if (status != 200 || !data.length || error) {
                [self completeDownload:error ?: VKError(status == 401 || status == 403 ?
                    @"Hugging Face denied access. Check model approval and read-token permissions." : @"Could not download the model vocabulary.")];
                return;
            }
            self.modelVocabulary = data;
            [self startWeightDownload];
        }] resume];
        return;
    }
    [self startWeightDownload];
}

- (NSMutableURLRequest *)modelRequest:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (self.modelAccessToken.length && [url.scheme isEqual:@"https"] && [url.host isEqual:@"huggingface.co"])
        [request setValue:[@"Bearer " stringByAppendingString:self.modelAccessToken] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (void)startWeightDownload {
    self.phase = Downloading;
    self.failed = NO;
    self.retryCount = 0;
    [self requestRemainingBytes];
}

- (void)requestRemainingBytes {
    self.retryTimer = nil;
    self.notice = nil;
    NSDictionary *model = models[self.selectedModel];
    uint64_t bytes = [model[@"bytes"] unsignedLongLongValue];
    self.receivedBytes = [self partialSize];
    if (self.receivedBytes >= bytes) {
        [self verifyDownload];
        return;
    }
    NSString *address = model[@"url"];
    NSMutableURLRequest *request = [self modelRequest:[NSURL URLWithString:address]];
    request.timeoutInterval = 45;
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (self.receivedBytes) {
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-", self.receivedBytes]
            forHTTPHeaderField:@"Range"];
    }
    self.downloadTask = [self.session dataTaskWithRequest:request];
    self.downloadedFraction = (double)self.receivedBytes / bytes;
    [self.downloadTask resume];
    [self refresh];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completion {
    if (![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        completion(nil);
        return;
    }
    NSMutableURLRequest *redirect = [request mutableCopy];
    [redirect setValue:[request.URL.host isEqual:@"huggingface.co"] ?
        [task.originalRequest valueForHTTPHeaderField:@"Authorization"] : nil forHTTPHeaderField:@"Authorization"];
    [redirect setValue:[task.originalRequest valueForHTTPHeaderField:@"Range"] forHTTPHeaderField:@"Range"];
    [redirect setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    completion(redirect);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if (task != self.downloadTask) { completion(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = http.statusCode;
    uint64_t size = [models[self.selectedModel][@"bytes"] unsignedLongLongValue];
    if (status != 200 && status != 206) {
        completion(NSURLSessionResponseCancel);
        NSString *message = [NSString stringWithFormat:@"The model server returned HTTP %ld.", status];
        if (status == 401 || status == 403) message = @"Hugging Face denied access. Check model approval and read-token permissions.";
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
    uint64_t size = [models[self.selectedModel][@"bytes"] unsignedLongLongValue];
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
    if (error || self.receivedBytes != [models[self.selectedModel][@"bytes"] unsignedLongLongValue]) {
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
    NSDictionary *model = models[self.selectedModel];
    uint64_t bytes = [model[@"bytes"] unsignedLongLongValue];
    NSURL *stage = self.partialURL;
    NSURL *destination = self.modelURL;
    NSData *vocabulary = self.modelVocabulary;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSFileManager *files = NSFileManager.defaultManager;
        NSNumber *installedBytes = nil;
        if ([model[@"convertPersianSmall"] boolValue]) {
            NSURL *converted = [destination URLByAppendingPathExtension:@"converting"];
            NSURL *prefix = [NSBundle.mainBundle URLForResource:@"whisper-small-multilingual" withExtension:@"header"];
            if (!VKVerifyArchive(stage, bytes, model[@"sha"])) {
                error = VKError(@"Model checksum mismatch. Download the model again.");
                [files removeItemAtURL:stage error:NULL];
            } else if (VKConvertWhisperSmall(stage, vocabulary, prefix, converted, &error) &&
                       [converted getResourceValue:&installedBytes forKey:NSURLFileSizeKey error:&error]) {
                if (rename(converted.fileSystemRepresentation, destination.fileSystemRepresentation) != 0)
                    error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                else [files removeItemAtURL:stage error:NULL];
            }
            [files removeItemAtURL:converted error:NULL];
        } else if (VKVerifyModel(stage, bytes, model[@"sha"], &error)) {
            if (rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation) != 0)
                error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        } else if ([error.domain isEqualToString:@"VoiceKey"]) {
            [files removeItemAtURL:stage error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && installedBytes) {
                NSMutableDictionary *updated = [model mutableCopy];
                updated[@"installedBytes"] = installedBytes;
                models[self.selectedModel] = updated;
                [self saveCustomModels];
            }
            [self completeDownload:error];
        });
    });
}

- (void)completeDownload:(NSError *)error {
    self.modelAccessToken = nil;
    self.modelVocabulary = nil;
    self.downloadTask = nil;
    [self.partialFile closeFile];
    self.partialFile = nil;
    self.phase = Idle;
    if (error && !([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)) {
        [self displayError:error.localizedDescription];
        return;
    }
    self.notice = error ? @"Download paused. Your progress is saved." : nil;
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
    if (!sender && self.phase == RequestingMicrophone && self.gesture.mode == ToggleRecording) {
        self.generation++;
        self.phase = Idle;
        self.shortcutSession = NO;
        [self refresh];
        return;
    }
    if (self.phase != Idle || self.updater.installing) return;
    self.shortcutSession = sender == nil;
    if (![self modelExists]) {
        [self displayError:@"Choose and download a model from the Sayso menu to start dictating."];
        return;
    }

    if (sender == self.recordButton && AXIsProcessTrusted() &&
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
        return;
    }
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
        [self displayError:@"Microphone access is unavailable. Check Privacy & Security → Microphone."];
    }
}

- (void)prepareDestination {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    BOOL restoreFocus = front.processIdentifier == NSRunningApplication.currentApplication.processIdentifier;
    if (restoreFocus) [self.destination activateWithOptions:0];
    NSUInteger request = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, restoreFocus ? 150 * NSEC_PER_MSEC : 0), dispatch_get_main_queue(), ^{
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
    self.capture.level = ^(float rms) { [app.indicator addLevel:rms]; };
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
            CGEventSetIntegerValueField(down, kCGEventSourceUserData, dictationEventTag);
            CGEventSetIntegerValueField(up, kCGEventSourceUserData, dictationEventTag);
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
            self.notice = @"Dictation stopped to finish queued speech.";
            dispatch_async(dispatch_get_main_queue(), ^{ if (self.phase == Recording) [self finishRecording]; });
        }
        return;
    }
    NSData *samples = self.pending.firstObject;
    if (!samples) {
        if (self.phase == Transcribing) {
            self.phase = Idle;
            if (!self.notice && !self.typedPhrase) self.notice = @"No speech detected.";
            self.destination = nil;
            self.focusedElement = nil;
            if (self.shortcutSession) [self refresh]; else [self updateChanged];
            self.shortcutSession = NO;
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

// The menu-bar app has no storyboard to install AppKit's standard editing shortcuts.
static NSMenu *EditingMenuBar(void) {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [bar addItemWithTitle:@"Sayso" action:nil keyEquivalent:@""];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"Sayso"];
    NSMenuItem *editItem = [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    return bar;
}

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
        application.mainMenu = EditingMenuBar();
        __attribute__((objc_precise_lifetime)) VoiceKey *delegate = [VoiceKey new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
