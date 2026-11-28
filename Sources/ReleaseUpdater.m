#import "ReleaseUpdater.h"
#import "WhisperEngine.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <stdio.h>
#include <fcntl.h>

static NSString *const releasesAPI = @"https://api.github.com/repos/seenpeh/sayso/releases/latest";
static NSString *const assetPrefix = @"/seenpeh/sayso/releases/download/";

static NSString *NumericVersion(NSString *tag) {
    if (![tag isKindOfClass:NSString.class]) return nil;
    NSString *version = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
    if (![version length] || [version rangeOfString:@"^[0-9]+([.][0-9]+){0,3}$"
        options:NSRegularExpressionSearch].location == NSNotFound) return nil;
    return version;
}

static NSComparisonResult CompareVersions(NSString *a, NSString *b) {
    NSArray *left = [a componentsSeparatedByString:@"."], *right = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(left.count, right.count); i++) {
        NSString *x = i < left.count ? left[i] : @"0";
        NSString *y = i < right.count ? right[i] : @"0";
        NSComparisonResult order = [x compare:y options:NSNumericSearch];
        if (order != NSOrderedSame) return order;
    }
    return NSOrderedSame;
}

static BOOL RunTool(NSString *path, NSArray *arguments, NSError **error) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:error]) return NO;
    [task waitUntilExit];
    if (task.terminationStatus == 0) return YES;
    if (error) *error = VKError([NSString stringWithFormat:@"%@ could not validate or unpack the update.", path.lastPathComponent]);
    return NO;
}

static NSDictionary *CompatibleAsset(NSArray *assets) {
#if defined(__arm64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"x86_64";
#endif
    if (![assets isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *asset in assets) {
        if (![asset isKindOfClass:NSDictionary.class]) continue;
        if (![asset isKindOfClass:NSDictionary.class]) continue;
        NSString *name = asset[@"name"], *address = asset[@"browser_download_url"], *digest = asset[@"digest"];
        if (![name isKindOfClass:NSString.class] || ![address isKindOfClass:NSString.class] ||
            ![digest isKindOfClass:NSString.class] || [digest rangeOfString:@"^sha256:[0-9a-f]{64}$"
            options:NSRegularExpressionSearch].location == NSNotFound || ![asset[@"size"] isKindOfClass:NSNumber.class] ||
            [asset[@"size"] longLongValue] <= 0) continue;
        NSString *lower = name.lowercaseString;
        if (![lower hasPrefix:@"sayso-"] && ![lower hasPrefix:@"voicekey-"]) continue;
        if (![@[@"dmg", @"zip"] containsObject:lower.pathExtension]) continue;
        NSString *stem = lower.stringByDeletingPathExtension;
        if (![stem hasSuffix:[@"-" stringByAppendingString:arch]] && ![stem hasSuffix:@"-universal"]) continue;
        NSURL *url = [NSURL URLWithString:address];
        if ([url.scheme isEqual:@"https"] && [url.host.lowercaseString isEqual:@"github.com"] &&
            [url.path hasPrefix:assetPrefix] && [url.lastPathComponent isEqual:name]) return asset;
    }
    return nil;
}

static NSNumber *SigningFlags(SecStaticCodeRef code) {
    CFDictionaryRef signingInfo = NULL;
    OSStatus status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &signingInfo);
    NSDictionary *info = CFBridgingRelease(signingInfo);
    return status == errSecSuccess ? info[(__bridge NSString *)kSecCodeInfoFlags] : nil;
}

static BOOL UpdatePreservesSigningIdentity(NSURL *current, NSURL *candidate) {
    SecStaticCodeRef update = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)candidate, kSecCSDefaultFlags, &update) != errSecSuccess)
        return NO;
    NSNumber *updateFlags = SigningFlags(update);
    SecStaticCodeRef installed = NULL;
    BOOL matches = NO;
    if (updateFlags && !(updateFlags.unsignedIntValue & kSecCodeSignatureAdhoc) &&
        SecStaticCodeCreateWithPath((__bridge CFURLRef)current, kSecCSDefaultFlags, &installed) == errSecSuccess) {
        NSNumber *installedFlags = SigningFlags(installed);
        // Allow existing ad hoc builds to migrate to a certificate once.
        matches = installedFlags && (installedFlags.unsignedIntValue & kSecCodeSignatureAdhoc);
        SecRequirementRef requirement = NULL;
        if (installedFlags && !matches &&
            SecCodeCopyDesignatedRequirement(installed, kSecCSDefaultFlags, &requirement) == errSecSuccess)
            matches = SecStaticCodeCheckValidity(update, kSecCSCheckAllArchitectures, requirement) == errSecSuccess;
        if (requirement) CFRelease(requirement);
        CFRelease(installed);
    }
    CFRelease(update);
    return matches;
}

static BOOL InstallBundle(NSURL *archive, NSDictionary *asset, NSString *version, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *current = NSBundle.mainBundle.bundleURL;
    NSURL *stage = [files URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                         appropriateForURL:current create:YES error:error];
    if (!stage) return NO;
    NSURL *expanded = [stage URLByAppendingPathComponent:@"Contents"];
    NSURL *candidate = [stage URLByAppendingPathComponent:@"Update.app"];
    BOOL mounted = NO;
    @try {
        if (![files createDirectoryAtURL:expanded withIntermediateDirectories:NO attributes:nil error:error]) return NO;
        if ([[asset[@"name"] lowercaseString] hasSuffix:@".dmg"]) {
            mounted = RunTool(@"/usr/bin/hdiutil", @[@"attach", @"-readonly", @"-nobrowse", @"-noautoopen",
                               @"-mountpoint", expanded.path, archive.path], error);
            if (!mounted) return NO;
        } else if (!RunTool(@"/usr/bin/ditto", @[@"-x", @"-k", archive.path, expanded.path], error)) return NO;
        NSArray *items = [files contentsOfDirectoryAtURL:expanded includingPropertiesForKeys:nil options:0 error:error];
        if (!items) return NO;
        NSURL *source = nil;
        for (NSURL *item in items) {
            if ([item.pathExtension isEqual:@"app"] &&
                [[[NSBundle bundleWithURL:item] bundleIdentifier] isEqual:NSBundle.mainBundle.bundleIdentifier]) {
                source = item;
                break;
            }
        }
        if (!source) { *error = VKError(@"The release does not contain the Sayso application."); return NO; }
        if (![files copyItemAtURL:source toURL:candidate error:error]) return NO;
        NSBundle *bundle = [NSBundle bundleWithURL:candidate];
        NSString *packaged = NumericVersion([bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
        NSString *minimum = [bundle objectForInfoDictionaryKey:@"LSMinimumSystemVersion"];
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *system = [NSString stringWithFormat:@"%ld.%ld.%ld", os.majorVersion, os.minorVersion, os.patchVersion];
#if defined(__arm64__)
        NSNumber *architecture = @(NSBundleExecutableArchitectureARM64);
#else
        NSNumber *architecture = @(NSBundleExecutableArchitectureX86_64);
#endif
        if (!packaged || CompareVersions(packaged, version) != NSOrderedSame ||
            ![bundle.executableArchitectures containsObject:architecture] ||
            (minimum && CompareVersions(minimum, system) == NSOrderedDescending)) {
            *error = VKError(@"The release version or system requirements do not match this Mac."); return NO;
        }
        if (!RunTool(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", candidate.path], error)) return NO;
        if (!UpdatePreservesSigningIdentity(current, candidate)) {
            *error = VKError(@"This release needs a stable code signing certificate that matches Sayso’s installed certificate, if present. Your current copy is still installed.");
            return NO;
        }
        if (renameatx_np(AT_FDCWD, candidate.fileSystemRepresentation, AT_FDCWD, current.fileSystemRepresentation, RENAME_SWAP)) {
            *error = VKError(@"Sayso could not replace this copy. Move the app to a writable Applications folder, reopen it and retry.");
            return NO;
        }
        return YES;
    } @finally {
        if (!mounted || RunTool(@"/usr/bin/hdiutil", @[@"detach", expanded.path], NULL))
            [files removeItemAtURL:stage error:NULL];
    }
}

@implementation ReleaseUpdater {
    NSDictionary *_asset;
    NSURLSession *_session;
}
- (instancetype)init {
    if ((self = [super init])) {
        _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        _status = @"Checks when opened and daily while running.";
    }
    return self;
}
- (void)check {
    if (_checking || _installing) return;
    _checking = YES;
    _installError = nil;
    _status = @"Checking GitHub…";
    if (self.changed) self.changed();
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:releasesAPI]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSInteger code = http.statusCode;
        id payload = code == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *release = [payload isKindOfClass:NSDictionary.class] ? payload : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_checking = NO;
            if (error) {
                self->_status = [NSString stringWithFormat:@"Could not reach GitHub. %@", error.localizedDescription];
            } else if (code == 429 || (code == 403 && ([[http valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqual:@"0"] ||
                       [http valueForHTTPHeaderField:@"Retry-After"]))) {
                self->_status = @"GitHub is limiting update checks. Try again later or open GitHub Releases.";
            } else if (code != 200 && code != 404) {
                self->_status = [NSString stringWithFormat:@"GitHub returned HTTP %ld. Try again or open GitHub Releases.", (long)code];
            } else {
                NSString *version = NumericVersion(release[@"tag_name"]);
                NSString *current = NumericVersion([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
                self->_asset = nil;
                self->_availableVersion = nil;
                if (code == 404) self->_status = @"GitHub could not find a published release.";
                else if (!version || !current || [release[@"draft"] isEqual:@YES] || [release[@"prerelease"] isEqual:@YES])
                    self->_status = @"GitHub did not return a stable version.";
                else if (CompareVersions(version, current) != NSOrderedDescending)
                    self->_status = [NSString stringWithFormat:@"Sayso %@ is up to date. Checked at %@.", current,
                        [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
                else {
                    self->_asset = CompatibleAsset(release[@"assets"]);
                    if (self->_asset) self->_availableVersion = version;
                    self->_status = self->_asset ? [NSString stringWithFormat:@"Version %@ is ready to install.", version] :
                        [NSString stringWithFormat:@"Version %@ has no verified installer for this Mac. See GitHub Releases.", version];
                }
            }
            if (self.changed) self.changed();
        });
    }] resume];
}
- (void)install {
    if (!_asset || _checking || _installing) return;
    _installing = YES;
    _installError = nil;
    _status = @"Downloading and verifying the update…";
    if (self.changed) self.changed();
    NSDictionary *asset = _asset;
    NSString *version = _availableVersion;
    [[_session downloadTaskWithURL:[NSURL URLWithString:asset[@"browser_download_url"]]
        completionHandler:^(NSURL *file, NSURLResponse *response, NSError *networkError) {
        NSError *error = networkError;
        if (!error && (!file || [(NSHTTPURLResponse *)response statusCode] != 200))
            error = VKError(@"The update download failed.");
        if (!error && !VKVerifyArchive(file, [asset[@"size"] unsignedLongLongValue],
                                     [asset[@"digest"] substringFromIndex:7]))
            error = VKError(@"The update did not match the GitHub release checksum.");
        if (!error) InstallBundle(file, asset, version, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                NSTask *relaunch = [NSTask new];
                relaunch.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
                relaunch.arguments = @[@"-c", @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
                    @"relaunch", @(NSProcessInfo.processInfo.processIdentifier).stringValue, NSBundle.mainBundle.bundlePath];
                if ([relaunch launchAndReturnError:NULL]) { [NSApp terminate:nil]; return; }
            }
            self->_installing = NO;
            self->_installError = error.localizedDescription;
            self->_status = self->_installError ?: @"Update installed. Quit and reopen Sayso.";
            if (!error) { self->_asset = nil; self->_availableVersion = nil; }
            if (self.changed) self.changed();
        });
    }] resume];
}
@end
