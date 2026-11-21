#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL VKVerifyModel(NSURL *url, uint64_t expectedBytes, NSString *sha256, NSError **error);
NSString * _Nullable VKTranscribe(NSURL *audioURL, NSURL *modelURL, NSError **error);
NSError *VKError(NSString *description);

// Use one serial queue per recognizer. The model is loaded on first use.
@interface VKRecognizer : NSObject
- (instancetype)initWithModel:(NSURL *)model language:(NSString *)language;
- (nullable NSString *)recognize:(const float *)samples count:(NSUInteger)count error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
