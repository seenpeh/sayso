#import "WhisperSmallImport.h"
#import "WhisperEngine.h"

static BOOL Invalid(NSError **error, NSString *reason) {
    *error = VKError(reason);
    return NO;
}

static BOOL WriteVocabulary(NSFileHandle *file, NSData *json, NSError **error) {
    NSDictionary *vocab = [NSJSONSerialization JSONObjectWithData:json options:0 error:error];
    if (![vocab isKindOfClass:NSDictionary.class]) return Invalid(error, @"Invalid Whisper vocabulary.");
    // Whisper uses GPT-2 byte-level BPE. whisper.cpp supplies the special tokens itself.
    uint16_t reverse[512];
    memset(reverse, 0xff, sizeof(reverse));
    unsigned next = 256;
    for (unsigned byte = 0; byte < 256; byte++) {
        BOOL literal = (byte >= 33 && byte <= 126) || (byte >= 161 && byte <= 172) || byte >= 174;
        reverse[literal ? byte : next++] = byte;
    }
    const uint32_t count = 50257;
    NSMutableArray *tokens = [NSMutableArray arrayWithCapacity:count];
    for (unsigned i = 0; i < count; i++) [tokens addObject:NSNull.null];
    for (NSString *word in vocab) {
        NSNumber *value = vocab[word];
        if (![value isKindOfClass:NSNumber.class]) return Invalid(error, @"Invalid token ID.");
        NSUInteger index = value.unsignedIntegerValue;
        if (index >= count) continue;
        NSMutableData *token = [NSMutableData dataWithLength:word.length];
        for (NSUInteger i = 0; i < word.length; i++) {
            unichar c = [word characterAtIndex:i];
            if (c >= 512 || reverse[c] > 255) return Invalid(error, @"Unsupported Whisper token.");
            ((uint8_t *)token.mutableBytes)[i] = reverse[c];
        }
        tokens[index] = token;
    }
    NSMutableData *encoded = [NSMutableData dataWithBytes:&count length:4];
    for (NSData *token in tokens) {
        if (![token isKindOfClass:NSData.class]) return Invalid(error, @"Incomplete Whisper vocabulary.");
        uint32_t length = (uint32_t)token.length;
        [encoded appendBytes:&length length:4];
        [encoded appendData:token];
    }
    return [file writeData:encoded error:error];
}

static BOOL WriteTensor(NSData *source, NSUInteger start, NSDictionary *tensors, NSFileHandle *file,
                        NSString *key, NSString *name, NSArray *shape, BOOL half, NSError **error) {
    NSDictionary *entry = tensors[[@"model." stringByAppendingString:key]];
    if (!entry && [key isEqualToString:@"decoder.embed_tokens.weight"]) entry = tensors[@"proj_out.weight"];
    if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"shape"] isEqual:shape] ||
        ![entry[@"dtype"] isEqual:@"F32"]) return Invalid(error, [@"Unsupported Whisper tensor: " stringByAppendingString:key]);
    NSArray *range = entry[@"data_offsets"];
    NSUInteger count = 1;
    for (NSNumber *d in shape) count *= d.unsignedIntegerValue;
    if (![range isKindOfClass:NSArray.class] || range.count != 2 ||
        ![range[0] isKindOfClass:NSNumber.class] || ![range[1] isKindOfClass:NSNumber.class])
        return Invalid(error, @"Invalid tensor offsets.");
    uint64_t lo = [range[0] unsignedLongLongValue], hi = [range[1] unsignedLongLongValue];
    if (hi > source.length-start || hi < lo || hi-lo != count*4 || (start+lo)%4)
        return Invalid(error, @"Invalid tensor byte range.");
    if ([name hasPrefix:@"encoder.conv"] && [name hasSuffix:@".bias"]) shape = @[shape[0], @1];
    NSData *label = [name dataUsingEncoding:NSUTF8StringEncoding];
    int32_t fields[] = {(int32_t)shape.count, (int32_t)label.length, half, 0, 0, 0};
    for (NSUInteger i = 0; i < shape.count; i++) fields[3+i] = [shape[shape.count-1-i] intValue];
    if (![file writeData:[NSData dataWithBytes:fields length:4*(3+shape.count)] error:error] ||
        ![file writeData:label error:error]) return NO;
    const float *input = (const float *)((const uint8_t *)source.bytes + start + lo);
    if (!half) return [file writeData:[NSData dataWithBytesNoCopy:(void *)input length:count*4 freeWhenDone:NO] error:error];
    NSMutableData *buffer = [NSMutableData dataWithLength:MIN(count, 65536UL)*2];
    for (NSUInteger i = 0; i < count;) {
        NSUInteger n = MIN(count-i, 65536UL);
        buffer.length = n*2;
        __fp16 *out = buffer.mutableBytes;
        for (NSUInteger j = 0; j < n; j++) out[j] = input[i+j];
        if (![file writeData:buffer error:error]) return NO;
        i += n;
    }
    return YES;
}

BOOL VKConvertWhisperSmall(NSURL *weights, NSData *vocabulary, NSURL *prefix, NSURL *output, NSError **error) {
    NSData *source = [NSData dataWithContentsOfURL:weights options:NSDataReadingMappedAlways error:error];
    if (!source) return NO;
    uint64_t headerLength = 0;
    if (source.length >= 8) memcpy(&headerLength, source.bytes, 8);
    if (!headerLength || headerLength > 4*1024*1024 || headerLength > source.length-8)
        return Invalid(error, @"Invalid SafeTensors header.");
    NSDictionary *tensors = [NSJSONSerialization JSONObjectWithData:[source subdataWithRange:NSMakeRange(8, headerLength)]
                                                            options:0 error:error];
    if (![tensors isKindOfClass:NSDictionary.class]) return Invalid(error, @"Invalid SafeTensors tensor table.");
    NSData *header = prefix ? [NSData dataWithContentsOfURL:prefix options:0 error:error] : nil;
    if (header.length != 56 + 80*201*4) return Invalid(error, @"Whisper Small model header is missing.");
    if (![header writeToURL:output options:0 error:error]) return NO;
    NSFileHandle *file = [NSFileHandle fileHandleForWritingToURL:output error:error];
    if (!file || ![file seekToEndReturningOffset:NULL error:error] || !WriteVocabulary(file, vocabulary, error)) return NO;
    NSUInteger start = 8 + headerLength;
    for (NSString *side in @[@"encoder", @"decoder"]) {
        BOOL encoder = [side isEqual:@"encoder"];
        NSString *(^path)(NSString *) = ^(NSString *suffix) { return [side stringByAppendingFormat:@".%@", suffix]; };
        if (!WriteTensor(source, start, tensors, file, path(@"embed_positions.weight"), path(@"positional_embedding"), @[encoder ? @1500 : @448,@768], NO, error)) return NO;
        for (NSString *suffix in @[@"weight", @"bias"]) {
            NSString *ln = encoder ? @"ln_post" : @"ln";
            if (!WriteTensor(source, start, tensors, file, path([@"layer_norm." stringByAppendingString:suffix]), path([ln stringByAppendingFormat:@".%@",suffix]), @[@768], NO, error)) return NO;
        }
        NSDictionary *names = @{@"self_attn.k_proj":@"attn.key", @"self_attn.q_proj":@"attn.query",
            @"self_attn.v_proj":@"attn.value", @"self_attn.out_proj":@"attn.out", @"self_attn_layer_norm":@"attn_ln",
            @"encoder_attn.k_proj":@"cross_attn.key", @"encoder_attn.q_proj":@"cross_attn.query",
            @"encoder_attn.v_proj":@"cross_attn.value", @"encoder_attn.out_proj":@"cross_attn.out",
            @"encoder_attn_layer_norm":@"cross_attn_ln", @"fc1":@"mlp.0", @"fc2":@"mlp.2", @"final_layer_norm":@"mlp_ln"};
        for (unsigned i = 0; i < 12; i++) for (NSString *layer in names) {
            if (encoder && [layer hasPrefix:@"encoder_attn"]) continue;
            for (NSString *suffix in @[@"weight", @"bias"]) {
                BOOL bias = [suffix isEqual:@"bias"];
                if (bias && [layer hasSuffix:@"k_proj"]) continue;
                NSNumber *rows = [layer isEqual:@"fc1"] ? @3072 : @768;
                NSNumber *cols = [layer isEqual:@"fc2"] ? @3072 : @768;
                BOOL matrix = !bias && ![layer hasSuffix:@"layer_norm"];
                if (!WriteTensor(source, start, tensors, file, path([NSString stringWithFormat:@"layers.%u.%@.%@",i,layer,suffix]),
                            path([NSString stringWithFormat:@"blocks.%u.%@.%@",i,names[layer],suffix]),
                            matrix ? @[rows,cols] : @[rows], matrix, error)) return NO;
            }
        }
    }
    for (unsigned i = 1; i <= 2; i++) {
        NSString *conv = [NSString stringWithFormat:@"encoder.conv%u.",i];
        NSString *weight = [conv stringByAppendingString:@"weight"], *bias = [conv stringByAppendingString:@"bias"];
        if (!WriteTensor(source, start, tensors, file, weight,weight,@[@768,i == 1 ? @80 : @768,@3],YES,error) || !WriteTensor(source, start, tensors, file, bias,bias,@[@768],NO,error)) return NO;
    }
    return WriteTensor(source, start, tensors, file, @"decoder.embed_tokens.weight",@"decoder.token_embedding.weight",@[@51865,@768],YES,error) &&
           [file closeAndReturnError:error];
}
