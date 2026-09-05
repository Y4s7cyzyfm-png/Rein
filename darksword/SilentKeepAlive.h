//
//  SilentKeepAlive.h
//  Rein
//
//  后台保活：静音音频循环播放（AVAudioSession playback + 无限循环的静音 WAV）。
//  配合 Info.plist 的 UIBackgroundModes: audio，使 App 退后台后不被冻结，
//  RemoteCall 异常端口可继续应答，避免 trojan 线程悬停把 SpringBoard 打崩。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 用户偏好键（NSUserDefaults）：是否启用后台保活。
OBJC_EXTERN NSString * const SilentKeepAlivePreferenceKey;

/// 开启保活：配置音频会话并开始静音循环播放（幂等）。
/// 在前台调用最可靠（iOS 8+ 后台激活音频会话受限）。
OBJC_EXTERN BOOL SilentKeepAliveStart(void);

/// 停止保活：停掉播放并停用音频会话（幂等）。
OBJC_EXTERN void SilentKeepAliveStop(void);

/// 当前是否正在播放静音循环。
OBJC_EXTERN BOOL SilentKeepAliveIsPlaying(void);

/// 是否启用了保活（用户偏好 + 当前正在播放）。
OBJC_EXTERN BOOL SilentKeepAliveIsEnabled(void);

/// 读取用户偏好（仅 NSUserDefaults，不反映实时播放状态）。
OBJC_EXTERN BOOL SilentKeepAlivePreferenceEnabled(void);

/// 设置用户偏好并立即生效：开则启播，关则停止（持久化到 NSUserDefaults）。
OBJC_EXTERN void SilentKeepAliveSetPreference(BOOL enabled);

NS_ASSUME_NONNULL_END
