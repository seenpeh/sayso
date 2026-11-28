#import <Foundation/Foundation.h>

// Convert the multilingual Whisper Small architecture using the repository's vocabulary.
// The caller verifies the weights' digest and supplies a temporary output file.
BOOL VKConvertWhisperSmall(NSURL *weights, NSData *vocabulary, NSURL *prefix, NSURL *output, NSError **error);
