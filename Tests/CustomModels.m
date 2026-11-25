#define main SaysoApplicationMain
#import "../Sources/main.m"
#undef main

@interface CatalogCheck : VoiceKey
@property BOOL requestedDownload;
@property (strong) NSURL *folder;
@end
@implementation CatalogCheck
- (void)refresh {}
- (void)downloadModel:(id)sender { self.requestedDownload = YES; }
- (NSURL *)modelsFolder { return self.folder; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:customModelsKey];
        LoadModels(defaults);
        CatalogCheck *app = [CatalogCheck new];
        app.gesture = [ShortcutGesture new];
        NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
        [app loadShortcutSettings:fresh];
        assert(app.shortcutKey == kVK_RightShift && app.shortcutModifiers == shiftKey);
        assert(app.gesture.kind == DoubleTapGesture && app.gesture.mode == HoldRecording);
        app.folder = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        app.settingsPicker = [app newModelPicker];
        app.modelPicker = [app newModelPicker];
        NSString *digest = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        NSDictionary *info = @{@"sha": @"revision", @"siblings": @[@{@"rfilename": @"nested/model.bin",
                                   @"lfs": @{@"sha256": digest, @"size": @123}}]};
        [app chooseModelFromRepository:@"owner/model" info:info path:@"nested/model.bin"];
        assert(app.requestedDownload && app.selectedModel == builtInCount);
        assert(app.modelPicker.numberOfItems == builtInCount + 3);
        assert(app.settingsPicker.numberOfItems == app.modelPicker.numberOfItems);
        LoadModels(defaults);
        assert(LoadSelectedModel(defaults) == builtInCount);
        [app chooseModelFromRepository:@"owner/model" info:info path:@"nested/model.bin"];
        assert(models.count == builtInCount + 1);
        [app removeModel:nil];
        LoadModels(defaults);
        assert(models.count == builtInCount && LoadSelectedModel(defaults) == noModel);
        assert(app.settingsPicker.numberOfItems == builtInCount + 2);
        puts("Custom model catalog checks passed.");
    }
}
