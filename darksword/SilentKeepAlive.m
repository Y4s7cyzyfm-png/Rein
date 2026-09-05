//
//  SilentKeepAlive.m
//  Rein
//

#import "SilentKeepAlive.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString * const SilentKeepAlivePreferenceKey = @"rein.keepalive.enabled";

static AVAudioPlayer *sPlayer = nil;
static BOOL sWantPlaying = NO; // 期望状态（应对来电等中断后的恢复）

// ------------------------------------------------------------------
// 静音 WAV 生成：44 字节头 + 16-bit PCM 样本（全 0）。
// 运行时生成，避免在仓库里放二进制资源。
// ------------------------------------------------------------------
static NSString *SilentKeepAliveGenerateWAV(void) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 44100;
        const uint32_t durationFrames = 4410; // 0.1 秒
        const uint32_t dataBytes = durationFrames * sizeof(int16_t);
        const uint32_t fileSize = 36 + dataBytes;

        NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
        uint8_t header[44] = {0};

        memcpy(header + 0, "RIFF", 4);
        memcpy(header + 4, &fileSize, 4);
        memcpy(header + 8, "WAVE", 4);
        memcpy(header + 12, "fmt ", 4);
        uint32_t fmtSize = 16;
        memcpy(header + 16, &fmtSize, 4);
        uint16_t audioFormat = 1; // PCM
        memcpy(header + 20, &audioFormat, 2);
        uint16_t channels = 1;
        memcpy(header + 22, &channels, 2);
        memcpy(header + 24, &sampleRate, 4);
        uint32_t byteRate = sampleRate * channels * sizeof(int16_t);
        memcpy(header + 28, &byteRate, 4);
        uint16_t blockAlign = channels * sizeof(int16_t);
        memcpy(header + 32, &blockAlign, 2);
        uint16_t bitsPerSample = 16;
        memcpy(header + 34, &bitsPerSample, 2);
        memcpy(header + 36, "data", 4);
        memcpy(header + 40, &dataBytes, 4);

        [wav appendBytes:header length:sizeof(header)];
        [wav increaseLengthBy:dataBytes]; // 样本全 0 = 静音

        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"rein_silent_keepalive.wav"];
        NSError *writeError = nil;
        if ([wav writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            cachedPath = path;
        } else {
            NSLog(@"[KeepAlive] WAV 写入失败: %@", writeError.localizedDescription);
        }
    });
    return cachedPath;
}

// ------------------------------------------------------------------
// 音频会话配置：playback + 与其他 App 混音（不打断用户正在听的音乐）。
// ------------------------------------------------------------------
static BOOL SilentKeepAliveConfigureSession(void) {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error];
    if (error) {
        NSLog(@"[KeepAlive] setCategory 失败: %@", error.localizedDescription);
        return NO;
    }
    [session setActive:YES
             withOptions:0
                   error:&error];
    if (error) {
        NSLog(@"[KeepAlive] setActive 失败: %@", error.localizedDescription);
        return NO;
    }
    return YES;
}

// 中断结束（来电/闹钟）或音频服务重置后自动恢复播放
static void SilentKeepAliveHandleInterruption(NSNotification *notification) {
    BOOL shouldResume = sWantPlaying;
    NSNumber *typeValue = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeValue) {
        AVAudioSessionInterruptionType type =
            (AVAudioSessionInterruptionType)[typeValue unsignedIntegerValue];
        // 中断开始不处理；中断结束才恢复
        shouldResume = sWantPlaying && type == AVAudioSessionInterruptionTypeEnded;
    }
    if (!shouldResume) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sWantPlaying && !sPlayer.playing) {
            NSError *error = nil;
            [[AVAudioSession sharedInstance] setActive:YES
                                            withOptions:0
                                                  error:&error];
            if (error) return;
            [sPlayer play];
        }
    });
}

BOOL SilentKeepAliveStart(void) {
    if (sPlayer && sPlayer.playing) {
        sWantPlaying = YES;
        return YES;
    }

    if (!SilentKeepAliveConfigureSession()) return NO;

    NSString *wavPath = SilentKeepAliveGenerateWAV();
    if (!wavPath) return NO;

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc]
        initWithContentsOfURL:[NSURL fileURLWithPath:wavPath]
                        error:&error];
    if (!player) {
        NSLog(@"[KeepAlive] 播放器创建失败: %@", error.localizedDescription);
        return NO;
    }
    player.numberOfLoops = -1; // 无限循环
    player.volume = 0.0;
    if (![player play]) {
        NSLog(@"[KeepAlive] play 失败");
        return NO;
    }

    sPlayer = player;
    sWantPlaying = YES;

    static BOOL sObserversInstalled = NO;
    if (!sObserversInstalled) {
        sObserversInstalled = YES;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        // 中断（来电/闹钟）结束后恢复播放
        [center addObserverForName:AVAudioSessionInterruptionNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *notification) {
                            SilentKeepAliveHandleInterruption(notification);
                        }];
        // 音频服务被重置时也尝试恢复
        [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *notification) {
                            SilentKeepAliveHandleInterruption(notification);
                        }];
    }
    NSLog(@"[KeepAlive] 静音循环已启动");
    return YES;
}

void SilentKeepAliveStop(void) {
    sWantPlaying = NO;
    [sPlayer stop];
    sPlayer = nil;
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:0
                                         error:&error];
    if (error) {
        NSLog(@"[KeepAlive] 会话停用失败: %@", error.localizedDescription);
    }
}

BOOL SilentKeepAliveIsPlaying(void) {
    return sPlayer != nil && sPlayer.playing;
}

BOOL SilentKeepAlivePreferenceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:SilentKeepAlivePreferenceKey];
}

BOOL SilentKeepAliveIsEnabled(void) {
    return SilentKeepAlivePreferenceEnabled() && SilentKeepAliveIsPlaying();
}

/// 偏好变化时调用：开则启播，关则停止
void SilentKeepAliveSetPreference(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                             forKey:SilentKeepAlivePreferenceKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (enabled) {
        SilentKeepAliveStart();
    } else {
        SilentKeepAliveStop();
    }
}
