#import "PhraseCapture.h"
#import "WhisperEngine.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

enum { sampleRate = 16000, framesPerBuffer = 800 };
@interface PhraseCapture () {
    AudioQueueRef _queue;
    NSMutableData *_samples;
    NSUInteger _quietFrames;
    BOOL _hasSpeech;
    NSTimer *_watchdog;
    NSTimeInterval _lastInput;
}
- (void)consume:(const float *)samples frames:(NSUInteger)frames;
- (void)readQueue:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer;
@end

static void AudioInput(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
                       const AudioTimeStamp *time, UInt32 packets, const AudioStreamPacketDescription *descriptions) {
    [(__bridge PhraseCapture *)context readQueue:queue buffer:buffer];
}

@implementation PhraseCapture
- (instancetype)init {
    if ((self = [super init])) _samples = [NSMutableData data];
    return self;
}

- (BOOL)start:(NSError **)error {
    AudioStreamBasicDescription format = {
        .mSampleRate = sampleRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1, .mBytesPerFrame = sizeof(float), .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32
    };
    OSStatus status = AudioQueueNewInput(&format, AudioInput, (__bridge void *)self,
        CFRunLoopGetMain(), kCFRunLoopCommonModes, 0, &_queue);
    for (int i = 0; i < 3 && status == noErr; i++) {
        AudioQueueBufferRef buffer;
        status = AudioQueueAllocateBuffer(_queue, framesPerBuffer * sizeof(float), &buffer);
        if (status == noErr) status = AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
    }
    if (status == noErr) status = AudioQueueStart(_queue, NULL);
    if (status == noErr) {
        _lastInput = NSProcessInfo.processInfo.systemUptime;
        __weak PhraseCapture *weakSelf = self;
        _watchdog = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            PhraseCapture *capture = weakSelf;
            if (capture && NSProcessInfo.processInfo.systemUptime - capture->_lastInput > 4 && capture.interrupted)
                capture.interrupted();
        }];
        return YES;
    }
    [self stop];
    if (error) *error = VKError(@"The microphone could not start. Check the selected input in Sound settings.");
    return NO;
}

- (void)readQueue:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer {
    if (queue != _queue) return;
    _lastInput = NSProcessInfo.processInfo.systemUptime;
    [self consume:buffer->mAudioData frames:buffer->mAudioDataByteSize / sizeof(float)];
    if (AudioQueueEnqueueBuffer(queue, buffer, 0, NULL) != noErr && self.interrupted)
        dispatch_async(dispatch_get_main_queue(), self.interrupted);
}

- (void)emitPhrase {
    if (_hasSpeech && self.phrase) self.phrase([_samples copy]);
    _samples.length = 0;
    _hasSpeech = NO;
    _quietFrames = 0;
}

- (void)consume:(const float *)samples frames:(NSUInteger)frames {
    if (!frames) return;
    float energy = 0;
    for (NSUInteger i = 0; i < frames; i++) energy += samples[i] * samples[i];
    BOOL voiced = energy / frames > 0.0025f * 0.0025f;
    [_samples appendBytes:samples length:frames * sizeof(float)];
    _hasSpeech |= voiced;
    _quietFrames = voiced ? 0 : _quietFrames + frames;
    NSUInteger count = _samples.length / sizeof(float);
    if (!_hasSpeech) {
        // Keep the lead-in so quiet initial consonants survive the speech threshold.
        if (count > sampleRate / 5)
            [_samples replaceBytesInRange:NSMakeRange(0, (count - sampleRate / 5) * sizeof(float)) withBytes:NULL length:0];
    } else if (_quietFrames >= sampleRate * 0.4 ||
               (count >= sampleRate * 3 && _quietFrames >= sampleRate * 0.1) || count >= sampleRate * 7) {
        [self emitPhrase];
    }
}

- (void)stop {
    [_watchdog invalidate];
    _watchdog = nil;
    AudioQueueRef queue = _queue;
    _queue = NULL;
    if (queue) {
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
    }
    [self emitPhrase];
}
@end
