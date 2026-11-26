// MPEG-2 transport streams (H.264 picture, AAC sound) and packed AAC audio, read into the
// compressed samples an MP4 is made of. AVFoundation plays these inside HLS but will not open
// them as files, so this small reader does it: nothing is decoded or re-encoded.
#import "VidGrab.h"
#import <AudioToolbox/AudioToolbox.h>

#define VG_NO_TIME INT64_MIN
static const int64_t kClock = 90000;                // transport stream time stamps tick 90,000 times a second

@class VGTSReader;

@interface VGTSReader ()
- (BOOL)pump;
@end

@interface VGQueueTrack : NSObject <VGTrack>
@property (nonatomic, weak) VGTSReader *owner;
@property (nonatomic) BOOL isVideo;
@property (nonatomic) BOOL timelineKnown;
@property (nonatomic, strong) NSMutableArray *queue;        // CMSampleBufferRef
- (void)setFormatRef:(CMFormatDescriptionRef)format;
@end

@implementation VGQueueTrack {
    CMFormatDescriptionRef _format;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableArray new];
        _timelineKnown = YES;
    }
    return self;
}

- (void)dealloc {
    if (_format) CFRelease(_format);
}

- (void)setFormatRef:(CMFormatDescriptionRef)format {
    if (format) CFRetain(format);
    if (_format) CFRelease(_format);
    _format = format;
}

- (CMFormatDescriptionRef)format { return _format; }
- (CGAffineTransform)transform { return CGAffineTransformIdentity; }
- (NSError *)failure { return nil; }

- (CMSampleBufferRef)copyNextSample {
    VGTSReader *owner = self.owner;
    while (self.queue.count == 0 && owner && [owner pump]) { }
    if (self.queue.count == 0) return NULL;
    CMSampleBufferRef buffer = (__bridge_retained CMSampleBufferRef)self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    return buffer;
}

@end

#pragma mark - helpers

static int64_t VGReadStamp(const uint8_t *p) {
    return ((int64_t)(p[0] & 0x0E) << 29) | ((int64_t)p[1] << 22) | ((int64_t)(p[2] & 0xFE) << 14) | ((int64_t)p[3] << 7) | ((int64_t)p[4] >> 1);
}

// Time stamps are 33 bits wide and wrap after 26 hours: the value nearest to the one before.
static int64_t VGUnwrap(int64_t stamp, int64_t reference) {
    if (reference == VG_NO_TIME) return stamp;
    const double period = 8589934592.0;
    return stamp + (int64_t)llround((double)(reference - stamp) / period) * (int64_t)period;
}

static BOOL VGParsePES(const uint8_t *b, NSUInteger n, int64_t *pts, int64_t *dts, NSUInteger *payload) {
    if (n < 9 || b[0] != 0 || b[1] != 0 || b[2] != 1) return NO;
    int flags = b[7];
    NSUInteger header = b[8];
    if (9 + header > n) return NO;
    *pts = *dts = VG_NO_TIME;
    if ((flags & 0x80) && header >= 5) {
        *pts = VGReadStamp(b + 9);
        *dts = *pts;
    }
    if ((flags & 0xC0) == 0xC0 && header >= 10) *dts = VGReadStamp(b + 14);
    *payload = 9 + header;
    return YES;
}

static void VGEachNAL(const uint8_t *b, NSUInteger n, void (^block)(const uint8_t *nal, NSUInteger length)) {
    NSUInteger i = 0, start = NSNotFound;
    while (i + 3 <= n) {
        if (b[i + 2] > 1) { i += 3; continue; }             // no start code can end here
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            if (start != NSNotFound) {
                NSUInteger end = i;
                while (end > start && b[end - 1] == 0) end--;
                if (end > start) block(b + start, end - start);
            }
            start = i + 3;
            i += 3;
        } else {
            i++;
        }
    }
    if (start != NSNotFound && start < n) {
        NSUInteger end = n;
        while (end > start && b[end - 1] == 0) end--;
        if (end > start) block(b + start, end - start);
    }
}

static CMBlockBufferRef VGCopyBlock(const void *bytes, size_t length) CF_RETURNS_RETAINED {
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL, 0, length,
                                           kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || !block) return NULL;
    if (CMBlockBufferReplaceDataBytes(bytes, block, 0, length) != noErr) {
        CFRelease(block);
        return NULL;
    }
    return block;
}

static const int kAACRates[16] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0};

VGFileKind VGSniffFile(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *head = [handle readDataOfLength:4096];
    [handle closeFile];
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n < 8) return VGFileUnknown;
    NSUInteger skip = 0;
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) skip = 3;                  // a byte-order mark
    while (skip < n && (b[skip] == ' ' || b[skip] == '\n' || b[skip] == '\r' || b[skip] == '\t')) skip++;
    if (n - skip >= 7 && memcmp(b + skip, "#EXTM3U", 7) == 0) return VGFilePlaylist;
    static const char *boxes[] = {"ftyp", "styp", "moov", "moof", "sidx", "free", "skip", "wide", "mdat", "emsg", "prft"};
    for (size_t i = 0; i < sizeof(boxes) / sizeof(boxes[0]); i++) {
        if (memcmp(b + 4, boxes[i], 4) == 0) return VGFileMP4;
    }
    if (b[0] == 0x47 && (n < 189 || b[188] == 0x47) && (n < 377 || b[376] == 0x47)) return VGFileTS;
    if (memcmp(b, "ID3", 3) == 0) return VGFileAAC;
    if (b[0] == 0xFF && (b[1] & 0xF6) == 0xF0) return VGFileAAC;
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) return VGFileWebM;
    if (skip < n && b[skip] == '<') return VGFileText;
    return VGFileUnknown;
}

#pragma mark - the reader

@implementation VGTSReader {
    NSString *_path;
    FILE *_file;
    BOOL _atEnd, _flushed, _packed;
    uint8_t *_chunk;
    long long _bytesRead;

    int _pmtPID, _videoPID, _audioPID;
    int _videoType, _audioType;
    NSMutableData *_videoPES, *_audioPES;
    BOOL _videoOpen, _audioOpen;

    // picture
    NSData *_sps, *_pps;
    BOOL _gotKeyFrame;
    NSMutableData *_heldData;                       // the access unit waiting for its duration
    int64_t _heldPTS, _heldDTS;
    BOOL _held, _heldSync;
    int64_t _videoRaw, _videoShift, _videoLastDuration;
    NSInteger _videoSamples;

    // sound
    NSMutableData *_aacCarry;
    int _rateIndex, _rate, _channels, _objectType;
    BOOL _audioBroken, _audioClockSet, _hintFresh, _stampSeen;
    int64_t _audioSamples;                          // the clock, in samples
    int64_t _audioRaw, _audioShift, _hint;
    NSInteger _audioPackets;

    VGQueueTrack *_video, *_audio;
    NSString *_note;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _pmtPID = _videoPID = _audioPID = -1;
        _videoPES = [NSMutableData new];
        _audioPES = [NSMutableData new];
        _aacCarry = [NSMutableData new];
        _videoRaw = _audioRaw = _hint = VG_NO_TIME;
        _videoLastDuration = 3000;
        _chunk = malloc(188 * 512);
    }
    return self;
}

- (void)dealloc {
    if (_file) fclose(_file);
    free(_chunk);
}

- (id<VGTrack>)video { return _video.format ? _video : nil; }
- (id<VGTrack>)audio { return _audio.format ? _audio : nil; }

- (NSString *)summary {
    return [NSString stringWithFormat:@"%@: %ld picture samples, %ld sound packets%@", _packed ? @"packed audio" : @"transport stream",
            (long)_videoSamples, (long)_audioPackets, _note ? [@"; " stringByAppendingString:_note] : @""];
}

- (BOOL)prepare:(NSError **)error {
    VGFileKind kind = VGSniffFile(_path);
    if (kind != VGFileTS && kind != VGFileAAC) {
        if (error) *error = VGError(VGErrorUnsupported, @"The stream is in a format VidGrab cannot read.");
        return NO;
    }
    _packed = kind == VGFileAAC;
    _file = fopen(_path.fileSystemRepresentation, "rb");
    if (!_file) {
        if (error) *error = VGError(VGErrorStorage, @"A downloaded part could not be opened.");
        return NO;
    }
    _video = [VGQueueTrack new];
    _video.owner = self;
    _video.isVideo = YES;
    _audio = [VGQueueTrack new];
    _audio.owner = self;
    if (_packed) {
        _audioPID = 0;
        _audioType = 0x0F;
    }
    // far enough to know what is inside: the formats come with the first picture and sound frames
    while (_bytesRead < 6 * 1024 * 1024) {
        BOOL listed = _packed || _videoPID >= 0 || _audioPID >= 0;         // the stream's table of contents was read
        BOOL videoKnown = _videoPID < 0 || _videoType != 0x1B || _video.format;
        BOOL audioKnown = _audioPID < 0 || _audioType != 0x0F || _audio.format || _audioBroken;
        if (listed && videoKnown && audioKnown) break;
        if (![self pump]) break;
    }
    if (_videoPID >= 0 && _videoType != 0x1B) {
        if (error) *error = VGError(VGErrorUnsupported, @"The stream's picture is in a format VidGrab cannot copy.");
        return NO;
    }
    if (_audioPID >= 0 && !_packed && _audioType != 0x0F) _note = [NSString stringWithFormat:@"sound of type 0x%02x left out", _audioType];
    if (!_video.format && !_audio.format) {
        if (error) *error = VGError(VGErrorMedia, @"No picture or sound was found in the stream.");
        return NO;
    }
    return YES;
}

/// Reads and takes apart another stretch of the file. NO once everything has been read.
- (BOOL)pump {
    if (_flushed) return NO;
    if (!_atEnd) {
        size_t wanted = _packed ? 64 * 1024 : 188 * 512;
        size_t got = fread(_chunk, 1, wanted, _file);
        _bytesRead += got;
        if (got < wanted) _atEnd = YES;
        if (_packed) {
            [self feedAAC:_chunk length:got stamp:VG_NO_TIME];
        } else {
            size_t i = 0;
            while (i + 188 <= got) {
                if (_chunk[i] != 0x47) {                    // out of step: find the next packet start
                    i++;
                    continue;
                }
                [self packet:_chunk + i];
                i += 188;
            }
            // whatever does not make a whole packet is read again with the next chunk
            if (!_atEnd && i < got) {
                fseeko(_file, -(off_t)(got - i), SEEK_CUR);
                _bytesRead -= (long long)(got - i);
            }
        }
        if (!_atEnd) return YES;
    }
    // the end: what is still being put together
    _flushed = YES;
    if (!_packed) {
        if (_videoOpen && _videoPES.length) [self videoPES];
        if (_audioOpen && _audioPES.length) [self audioPES];
        [self releaseHeld:VG_NO_TIME];
    }
    return NO;
}

- (void)packet:(const uint8_t *)p {
    BOOL start = (p[1] & 0x40) != 0;
    int pid = ((p[1] & 0x1F) << 8) | p[2];
    int adaptation = (p[3] >> 4) & 3;
    NSUInteger offset = 4;
    if (adaptation & 2) offset += 1 + p[4];
    if (!(adaptation & 1) || offset >= 188) return;
    const uint8_t *payload = p + offset;
    NSUInteger length = 188 - offset;

    if (pid == 0) {
        if (!start || _pmtPID >= 0) return;
        NSUInteger at = 1 + payload[0];
        if (at + 8 > length || payload[at] != 0) return;
        const uint8_t *s = payload + at;
        NSUInteger sectionLength = ((s[1] & 0x0F) << 8) | s[2];
        NSUInteger end = MIN(length - at, 3 + sectionLength) ;
        if (end < 4) return;
        end -= 4;                                           // the checksum
        for (NSUInteger e = 8; e + 4 <= end; e += 4) {
            int program = (s[e] << 8) | s[e + 1];
            if (program != 0) {
                _pmtPID = ((s[e + 2] & 0x1F) << 8) | s[e + 3];
                break;
            }
        }
        return;
    }
    if (pid == _pmtPID) {
        if (!start || _videoPID >= 0 || _audioPID >= 0) return;
        NSUInteger at = 1 + payload[0];
        if (at + 12 > length || payload[at] != 2) return;
        const uint8_t *s = payload + at;
        NSUInteger sectionLength = ((s[1] & 0x0F) << 8) | s[2];
        NSUInteger end = MIN(length - at, 3 + sectionLength);
        if (end < 4) return;
        end -= 4;
        NSUInteger pos = 12 + (((s[10] & 0x0F) << 8) | s[11]);
        while (pos + 5 <= end) {
            int type = s[pos];
            int stream = ((s[pos + 1] & 0x1F) << 8) | s[pos + 2];
            NSUInteger info = ((s[pos + 3] & 0x0F) << 8) | s[pos + 4];
            pos += 5 + info;
            BOOL picture = type == 0x1B || type == 0x24 || type == 0x02 || type == 0x10;
            BOOL sound = type == 0x0F || type == 0x03 || type == 0x04 || type == 0x11 || type == 0x81 || type == 0x87;
            if (picture && _videoPID < 0) { _videoPID = stream; _videoType = type; }
            if (sound && _audioPID < 0) { _audioPID = stream; _audioType = type; }
        }
        return;
    }
    if (pid == _videoPID && _videoType == 0x1B) {
        if (start) {
            if (_videoOpen && _videoPES.length) [self videoPES];
            _videoPES.length = 0;
            _videoOpen = YES;
        }
        if (_videoOpen) [_videoPES appendBytes:payload length:length];
    } else if (pid == _audioPID && _audioType == 0x0F) {
        if (start) {
            if (_audioOpen && _audioPES.length) [self audioPES];
            _audioPES.length = 0;
            _audioOpen = YES;
        }
        if (_audioOpen) [_audioPES appendBytes:payload length:length];
    }
}

#pragma mark picture

- (void)videoPES {
    int64_t pts, dts;
    NSUInteger offset;
    const uint8_t *b = _videoPES.bytes;
    if (!VGParsePES(b, _videoPES.length, &pts, &dts, &offset) || pts == VG_NO_TIME) return;

    NSMutableData *unit = [NSMutableData dataWithCapacity:_videoPES.length - offset + 64];
    __block BOOL hasPicture = NO, keyFrame = NO;
    VGEachNAL(b + offset, _videoPES.length - offset, ^(const uint8_t *nal, NSUInteger length) {
        int type = nal[0] & 0x1F;
        if (type == 7) { if (!self->_sps) self->_sps = [NSData dataWithBytes:nal length:length]; return; }
        if (type == 8) { if (!self->_pps) self->_pps = [NSData dataWithBytes:nal length:length]; return; }
        if (type == 9 || type == 12 || type == 10 || type == 11) return;       // delimiters and filler
        if (type >= 1 && type <= 5) hasPicture = YES;
        if (type == 5) keyFrame = YES;
        uint8_t size[4] = {(uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
        [unit appendBytes:size length:4];
        [unit appendBytes:nal length:length];
    });
    if (!hasPicture) return;

    if (!_video.format && _sps && _pps) {
        const uint8_t *sets[2] = {_sps.bytes, _pps.bytes};
        const size_t sizes[2] = {_sps.length, _pps.length};
        CMVideoFormatDescriptionRef format = NULL;
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &format) == noErr && format) {
            [_video setFormatRef:format];
            CFRelease(format);
        }
    }
    if (!_video.format) return;
    if (!_gotKeyFrame) {
        if (!keyFrame) return;                              // a file has to begin with a key frame
        _gotKeyFrame = YES;
    }

    int64_t rawDTS = VGUnwrap(dts, _videoRaw);
    int64_t rawPTS = VGUnwrap(pts, rawDTS);
    _videoRaw = rawDTS;
    int64_t outDTS = rawDTS + _videoShift;
    if (_held) {
        // a jump in the clock (segments joined across a discontinuity): carry on where the last sample ends
        if (outDTS < _heldDTS - kClock || outDTS > _heldDTS + 10 * kClock) {
            int64_t shift = (_heldDTS + _videoLastDuration) - outDTS;
            _videoShift += shift;
            outDTS += shift;
        }
    }
    int64_t outPTS = rawPTS + _videoShift;
    [self releaseHeld:outDTS];
    _heldData = unit;
    _heldPTS = outPTS;
    _heldDTS = outDTS;
    _heldSync = keyFrame;
    _held = YES;
}

/// The held access unit goes out, now that the next one's time gives its duration.
- (void)releaseHeld:(int64_t)nextDTS {
    if (!_held) return;
    _held = NO;
    int64_t duration = nextDTS == VG_NO_TIME ? _videoLastDuration : nextDTS - _heldDTS;
    if (duration <= 0 || duration > kClock) duration = _videoLastDuration;
    _videoLastDuration = duration;

    CMBlockBufferRef block = VGCopyBlock(_heldData.bytes, _heldData.length);
    if (!block) return;
    CMSampleTimingInfo timing = {CMTimeMake(duration, (int32_t)kClock), CMTimeMake(_heldPTS, (int32_t)kClock), CMTimeMake(_heldDTS, (int32_t)kClock)};
    size_t size = _heldData.length;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _video.format, 1, 1, &timing, 1, &size, &sample);
    CFRelease(block);
    _heldData = nil;
    if (status != noErr || !sample) return;
    if (!_heldSync) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef first = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(first, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
            CFDictionarySetValue(first, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
        }
    }
    [_video.queue addObject:(__bridge id)sample];
    CFRelease(sample);
    _videoSamples++;
}

#pragma mark sound

- (void)audioPES {
    int64_t pts, dts;
    NSUInteger offset;
    const uint8_t *b = _audioPES.bytes;
    if (!VGParsePES(b, _audioPES.length, &pts, &dts, &offset)) return;
    [self feedAAC:b + offset length:_audioPES.length - offset stamp:pts];
}

- (BOOL)makeAudioFormat {
    if (_objectType < 1 || _objectType > 4 || _rate <= 0 || _channels < 1 || _channels > 7) return NO;
    // the two bytes that describe the sound to a decoder, wrapped the way an MP4 stores them
    uint8_t config[2] = {(uint8_t)((_objectType << 3) | (_rateIndex >> 1)), (uint8_t)(((_rateIndex & 1) << 7) | (_channels << 3))};
    uint8_t cookie[] = {0x03, 0x19, 0x00, 0x00, 0x00,
                        0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x05, 0x02, config[0], config[1],
                        0x06, 0x01, 0x02};
    AudioStreamBasicDescription description;
    memset(&description, 0, sizeof(description));
    description.mFormatID = kAudioFormatMPEG4AAC;
    UInt32 size = sizeof(description);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, sizeof(cookie), cookie, &size, &description) != noErr
        || description.mSampleRate <= 0) {
        memset(&description, 0, sizeof(description));
        description.mFormatID = kAudioFormatMPEG4AAC;
        description.mFormatFlags = (UInt32)_objectType;
        description.mSampleRate = _rate;
        description.mChannelsPerFrame = (UInt32)(_channels == 7 ? 8 : _channels);
        description.mFramesPerPacket = 1024;
    }
    CMAudioFormatDescriptionRef format = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &description, 0, NULL, sizeof(cookie), cookie, NULL, &format);
    if (status != noErr || !format) return NO;
    _rate = (int)description.mSampleRate;                   // what the decoder will put out counts for the clock
    [_audio setFormatRef:format];
    CFRelease(format);
    return YES;
}

/// The time stamp Apple's packagers put at the head of a packed audio segment.
- (int64_t)stampInTag:(const uint8_t *)tag length:(NSUInteger)length {
    static const char owner[] = "com.apple.streaming.transportStreamTimestamp";
    const size_t ownerLength = sizeof(owner);               // with its closing zero
    if (length < ownerLength + 8) return VG_NO_TIME;
    for (NSUInteger i = 0; i + ownerLength + 8 <= length; i++) {
        if (tag[i] == 'c' && memcmp(tag + i, owner, ownerLength) == 0) {
            const uint8_t *v = tag + i + ownerLength;
            int64_t value = 0;
            for (int k = 0; k < 8; k++) value = (value << 8) | v[k];
            return value & 0x1FFFFFFFFLL;
        }
    }
    return VG_NO_TIME;
}

- (void)feedAAC:(const uint8_t *)bytes length:(NSUInteger)length stamp:(int64_t)stamp {
    if (_audioBroken) return;
    if (stamp != VG_NO_TIME) {
        int64_t raw = VGUnwrap(stamp, _audioRaw);
        _audioRaw = raw;
        _hint = raw + _audioShift;
        _hintFresh = YES;
        _stampSeen = YES;
    }
    [_aacCarry appendBytes:bytes length:length];
    const uint8_t *b = _aacCarry.bytes;
    NSUInteger n = _aacCarry.length, pos = 0;

    enum { kBatch = 48 };
    NSUInteger offsets[kBatch], sizes[kBatch];
    NSUInteger count = 0;
    while (n - pos >= 10) {
        if (b[pos] == 'I' && b[pos + 1] == 'D' && b[pos + 2] == '3' && b[pos + 3] < 0xFF && b[pos + 6] < 0x80) {
            NSUInteger tag = 10 + (((NSUInteger)b[pos + 6] << 21) | ((NSUInteger)b[pos + 7] << 14) | ((NSUInteger)b[pos + 8] << 7) | b[pos + 9]);
            if (b[pos + 5] & 0x10) tag += 10;               // a footer
            if (pos + tag > n) break;
            if (!_stampSeen) {
                int64_t value = [self stampInTag:b + pos length:tag];
                if (value != VG_NO_TIME) {
                    _hint = value;
                    _hintFresh = YES;
                    _stampSeen = YES;
                    _audioRaw = value;
                }
            }
            pos += tag;
            continue;
        }
        if (!(b[pos] == 0xFF && (b[pos + 1] & 0xF6) == 0xF0)) {
            pos++;
            continue;
        }
        NSUInteger header = (b[pos + 1] & 1) ? 7 : 9;
        NSUInteger frame = (((NSUInteger)b[pos + 3] & 3) << 11) | ((NSUInteger)b[pos + 4] << 3) | (b[pos + 5] >> 5);
        int rateIndex = (b[pos + 2] >> 2) & 0xF;
        if (frame <= header || kAACRates[rateIndex] == 0) {
            pos++;
            continue;
        }
        if (pos + frame > n) break;
        if (!_audio.format) {
            _objectType = ((b[pos + 2] >> 6) & 3) + 1;
            _rateIndex = rateIndex;
            _rate = kAACRates[rateIndex];
            _channels = ((b[pos + 2] & 1) << 2) | ((b[pos + 3] >> 6) & 3);
            if (![self makeAudioFormat]) {
                _audioBroken = YES;
                _note = @"sound in an AAC variant that cannot be copied";
                return;
            }
        }
        offsets[count] = pos + header;
        sizes[count] = frame - header;
        count++;
        pos += frame;
        if (count == kBatch) {
            [self emitAAC:b offsets:offsets sizes:sizes count:count];
            count = 0;
        }
    }
    if (count) [self emitAAC:b offsets:offsets sizes:sizes count:count];
    if (pos) [_aacCarry replaceBytesInRange:NSMakeRange(0, pos) withBytes:NULL length:0];
}

- (void)emitAAC:(const uint8_t *)base offsets:(const NSUInteger *)offsets sizes:(const NSUInteger *)sizes count:(NSUInteger)count {
    // where the clock stands against the last time stamp
    if (!_audioClockSet) {
        _audioSamples = _hint == VG_NO_TIME ? 0 : (int64_t)llround((double)_hint * _rate / (double)kClock);
        _audioClockSet = YES;
        _audio.timelineKnown = _hint != VG_NO_TIME;
        _hintFresh = NO;
    } else if (_hintFresh) {
        _hintFresh = NO;
        int64_t expected = (int64_t)llround((double)_audioSamples * kClock / (double)_rate);
        int64_t difference = _hint - expected;
        if (difference < -kClock || difference > 10 * kClock) {
            _audioShift -= difference;                      // the stream's clock jumped: ours runs on
        } else if (llabs(difference) > kClock / 10) {
            _audioSamples = (int64_t)llround((double)_hint * _rate / (double)kClock);      // sound really is missing here
        }
    }
    size_t total = 0;
    for (NSUInteger i = 0; i < count; i++) total += sizes[i];
    uint8_t *joined = malloc(total);
    AudioStreamPacketDescription packets[48];
    size_t at = 0;
    for (NSUInteger i = 0; i < count; i++) {
        memcpy(joined + at, base + offsets[i], sizes[i]);
        packets[i].mStartOffset = (SInt64)at;
        packets[i].mVariableFramesInPacket = 0;
        packets[i].mDataByteSize = (UInt32)sizes[i];
        at += sizes[i];
    }
    CMBlockBufferRef block = VGCopyBlock(joined, total);
    free(joined);
    if (!block) return;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, _audio.format, (CMItemCount)count,
                                                                           CMTimeMake(_audioSamples, _rate), packets, &sample);
    CFRelease(block);
    _audioSamples += 1024 * (int64_t)count;
    if (status != noErr || !sample) return;
    [_audio.queue addObject:(__bridge id)sample];
    CFRelease(sample);
    _audioPackets += (NSInteger)count;
}

@end
