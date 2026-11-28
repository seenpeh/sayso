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
        NSDictionary *weights = @{@"rfilename": @"model.safetensors", @"lfs": @{@"sha256": digest, @"size": @966995080}};
        NSDictionary *gated = @{@"sha": @"revision", @"gated": @"manual", @"siblings": @[weights]};
        app.requestedDownload = NO;
        [app chooseModelFromRepository:@"C1Tech/whisper_small_persian" info:gated path:nil];
        assert(app.requestedDownload && PersianOnly(app.selectedModel));
        NSDictionary *import = models[app.selectedModel];
        assert([import[@"convertPersianSmall"] boolValue] && [import[@"gated"] boolValue]);
        assert([import[@"url"] hasSuffix:@"/resolve/revision/model.safetensors"]);
        assert(![app modelExists]);
        app.modelAccessToken = @"example";
        NSURLRequest *request = [app modelRequest:[NSURL URLWithString:import[@"url"]]];
        assert([[request valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer example"]);
        NSURLRequest *cdn = [app modelRequest:[NSURL URLWithString:@"https://cdn.example/model"]];
        assert([cdn valueForHTTPHeaderField:@"Authorization"] == nil);
        [app removeModel:nil];
        puts("Custom model catalog checks passed.");
    }
}
