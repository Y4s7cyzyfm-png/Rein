//
//  ReinBridge.h
//  Rein
//
//  Bridge between Rein's UI and the bundled DarkSword runtime
//  (adapted from DarkSpeed's DSBridge).
//

#import <Foundation/Foundation.h>
#import "DSRemoteCall.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted on any progress / stage / state change (observe on main queue).
OBJC_EXTERN NSString * const ReinBridgeProgressNotification;

/// YES after a successful DarkSword kernel bootstrap (KRW ready).
OBJC_EXTERN BOOL ReinKernelIsReady(void);

/// YES after a successful RemoteCall attach to SpringBoard.
OBJC_EXTERN BOOL ReinRemoteCallIsReady(void);

/// YES while the kernel bootstrap (or kernelcache prefetch) is running.
OBJC_EXTERN BOOL ReinKernelIsRunning(void);

/// YES while the RemoteCall initialization is running.
OBJC_EXTERN BOOL ReinRemoteCallIsRunning(void);

/// Last human-readable error (may be empty).
OBJC_EXTERN NSString *ReinBridgeLastError(void);

/// Current neutral, user-visible stage label (may be empty).
OBJC_EXTERN NSString *ReinBridgeStage(void);

/// DarkSword bootstrap progress (0.0 – 1.0).
OBJC_EXTERN double ReinBridgeProgress(void);

/// pid of the attached SpringBoard RemoteCall (0 when not attached).
OBJC_EXTERN pid_t ReinRemoteCallPID(void);

/// Button "初始化 DarkSword 内核": network warm-up + kernelcache prefetch +
/// offsets + ds_run(). Asynchronous; observe ReinBridgeProgressNotification.
OBJC_EXTERN void ReinInitializeDarkSwordKernel(void);

/// Button "初始化 RemoteCall": attach RemoteCall to SpringBoard.
/// Requires the kernel to be ready first. Asynchronous.
OBJC_EXTERN void ReinInitializeRemoteCall(void);

/// The live RemoteCall session attached to SpringBoard
/// (NULL until "初始化 RemoteCall" succeeded). Do not destroy it.
OBJC_EXTERN RemoteCall * _Nullable ReinBridgeRemoteCall(void);

/// Button "读取游戏进程": locate ShadowTrackerExtra via kernel proc walk.
/// Requires the kernel to be ready. Synchronous (fast). Returns the pid.
OBJC_EXTERN BOOL ReinReadGameProcess(int * _Nullable outPid);

#pragma mark - In-app console log

/// 追加一行日志到 App 内控制台日志（自动加时间戳，线程安全）。
/// ReinBridge 与 PeaceESP 的所有日志都会镜像到这里。
OBJC_EXTERN void ReinAppendConsoleLog(NSString *line);

/// 当前缓存的日志行（旧→新），供「控制台日志」查看器显示。
OBJC_EXTERN NSArray<NSString *> *ReinConsoleLogLines(void);

/// 清空 App 内控制台日志。
OBJC_EXTERN void ReinClearConsoleLog(void);

NS_ASSUME_NONNULL_END
