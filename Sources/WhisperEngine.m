#import "WhisperEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <whisper/whisper.h>
#include <math.h>
#import <Metal/Metal.h>

NSError *VKError(NSString *description) {
    return [NSError errorWithDomain:@"VoiceKey" code:1
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL VerifyFile(NSURL *url, uint64_t expectedBytes, NSString *sha256, BOOL requireModel, NSError **error) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (!file) return NO;

    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    uint64_t bytes = 0;
    BOOL readFailed = NO;
    BOOL invalidModel = NO;
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [file readDataUpToLength:1024 * 1024 error:NULL];
            if (chunk.length == 0) {
                readFailed = chunk == nil;
                break;
            }
            if (requireModel && bytes == 0 && (chunk.length < 4 || memcmp(chunk.bytes, "lmgg", 4) != 0)) {
                invalidModel = YES;
                break;
            }
            bytes += chunk.length;
            CC_SHA256_Update(&hash, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [file closeFile];
    if (invalidModel) {
        if (error) *error = VKError(@"Choose a whisper.cpp GGML speech recognition model (.bin).");
        return NO;
    }
    if (readFailed) {
        if (error) *error = VKError(@"VoiceKey could not read the downloaded model file.");
        return NO;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    if (bytes == expectedBytes && [hex isEqualToString:sha256]) return YES;

    if (error) *error = VKError(@"The downloaded file did not match the model. Try downloading it again.");
    return NO;
}

BOOL VKVerifyModel(NSURL *url, uint64_t expectedBytes, NSString *sha256, NSError **error) {
    return VerifyFile(url, expectedBytes, sha256, YES, error);
}

BOOL VKVerifyArchive(NSURL *url, uint64_t expectedBytes, NSString *sha256) {
    return VerifyFile(url, expectedBytes, sha256, NO, NULL);
}

static AVAudioPCMBuffer *ReadAudio(NSURL *url, NSError **error) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
    if (!file) return nil;
    AVAudioFramePosition frames = file.length;
    if (frames < 1 || frames > INT_MAX) {
        if (error) *error = VKError(@"The recording has no readable audio or is too long.");
        return nil;
    }

    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                          frameCapacity:(AVAudioFrameCount)frames];
    if (!input) {
        if (error) *error = VKError(@"There is not enough memory to read this recording.");
        return nil;
    }
    if (![file readIntoBuffer:input error:error]) return nil;
    if (file.processingFormat.sampleRate == WHISPER_SAMPLE_RATE &&
        file.processingFormat.channelCount == 1) return input;

    AVAudioFormat *mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:WHISPER_SAMPLE_RATE
                                                                         channels:1];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:input.format toFormat:mono];
    double outputFrames = ceil(input.frameLength * mono.sampleRate / input.format.sampleRate) + 256;
    if (!converter || outputFrames > INT_MAX) {
        if (error) *error = VKError(@"The recording could not be converted to mono audio.");
        return nil;
    }

    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:mono
                                                           frameCapacity:(AVAudioFrameCount)outputFrames];
    if (!output) {
        if (error) *error = VKError(@"There is not enough memory to convert this recording.");
        return nil;
    }
    __block AVAudioFrameCount offset = 0;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:error
        withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
            AVAudioFrameCount count = MIN(requested, input.frameLength - offset);
            if (count == 0) {
                *inputStatus = AVAudioConverterInputStatus_EndOfStream;
                return nil;
            }
            AVAudioPCMBuffer *slice = [[AVAudioPCMBuffer alloc] initWithPCMFormat:input.format frameCapacity:count];
            if (!slice) {
                *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            slice.frameLength = count;
            for (AVAudioChannelCount channel = 0; channel < input.format.channelCount; channel++) {
                memcpy(slice.floatChannelData[channel], input.floatChannelData[channel] + offset,
                       count * sizeof(float));
            }
            offset += count;
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            return slice;
        }];
    return status == AVAudioConverterOutputStatus_Error ? nil : output;
}

@implementation VKRecognizer {
    NSURL *_model;
    NSString *_language;
    struct whisper_context *_context;
}
- (instancetype)initWithModel:(NSURL *)model language:(NSString *)language {
    if ((self = [super init])) {
        _model = model;
        _language = [language copy];
    }
    return self;
}
- (void)dealloc {
    if (_context) whisper_free(_context);
}
- (NSString *)recognize:(const float *)samples count:(NSUInteger)count error:(NSError **)error {
    if (!count || count > INT_MAX) return @"";
    float peak = 0;
    for (NSUInteger i = 0; i < count && peak < 0.0001f; i++) peak = fmaxf(peak, fabsf(samples[i]));
    if (peak < 0.0001f) return @"";
    if (!_context) {
        struct whisper_context_params options = whisper_context_default_params();
        options.use_gpu = MTLCreateSystemDefaultDevice() != nil;
        _context = whisper_init_from_file_with_params(_model.fileSystemRepresentation, options);
        if (!_context && options.use_gpu) {
            options.use_gpu = false;
            _context = whisper_init_from_file_with_params(_model.fileSystemRepresentation, options);
        }
        if (!_context) {
            if (error) *error = VKError(@"Whisper could not load this model. Try another model.");
            return nil;
        }
    }
    struct whisper_full_params parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.language = _language.UTF8String;
    parameters.no_context = true;
    parameters.suppress_nst = true;
    parameters.n_threads = (int)MIN(8, NSProcessInfo.processInfo.activeProcessorCount);
    parameters.no_timestamps = true;
    parameters.print_progress = false;
    parameters.print_realtime = false;
    parameters.print_timestamps = false;
    parameters.print_special = false;
    parameters.suppress_blank = true;

    NSMutableString *transcript = nil;
    if (whisper_full(_context, parameters, samples, (int)count) == 0) {
        transcript = [NSMutableString string];
        int count = whisper_full_n_segments(_context);
        for (int segment = 0; segment < count; segment++) {
            const char *bytes = whisper_full_get_segment_text(_context, segment);
            if (bytes) {
                NSString *text = [NSString stringWithUTF8String:bytes];
                if (text) [transcript appendString:text];
            }
        }
    }
    if (!transcript && error) *error = VKError(@"Whisper could not transcribe this phrase.");
    return [transcript stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@end

NSString *VKTranscribe(NSURL *audioURL, NSURL *modelURL, NSError **error) {
    AVAudioPCMBuffer *audio = ReadAudio(audioURL, error);
    if (!audio) return nil;
    if (audio.frameLength == 0 || !audio.floatChannelData) {
        if (error) *error = VKError(@"There was no audio to transcribe.");
        return nil;
    }

    VKRecognizer *recognizer = [[VKRecognizer alloc] initWithModel:modelURL language:@"auto"];
    return [recognizer recognize:audio.floatChannelData[0] count:audio.frameLength error:error];
}
