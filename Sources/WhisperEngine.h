#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL VKVerifyModel(NSURL *url, uint64_t expectedBytes, NSString *sha256, NSError **error);
NSString * _Nullable VKTranscribe(NSURL *audioURL, NSURL *modelURL, NSError **error);
NSError *VKError(NSString *description);

NS_ASSUME_NONNULL_END
