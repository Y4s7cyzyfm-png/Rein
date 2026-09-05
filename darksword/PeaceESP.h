//
//  PeaceESP.h
//  Rein
//
//  跨 app ESP：通过 RemoteCall 在 SpringBoard 内创建 Overlay 窗口绘制，
//  游戏内存经 DarkSword 内核读写（physmap + 页表遍历）读取。
//  目标进程：ShadowTrackerExtra。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动 ESP。需要先完成「初始化 DarkSword 内核」与「初始化 RemoteCall」。
/// 异步执行（游戏基址扫描可能耗时数秒）；用 PeaceESPIsRunning() 查询状态。
OBJC_EXTERN void PeaceESPStart(void);

/// 停止 ESP 并移除 SpringBoard 中的 Overlay。
OBJC_EXTERN void PeaceESPStop(void);

/// 阻塞等待 ESP 完全收尾（帧循环退出 + Overlay 已移除）。
/// timeout 秒内收尾返回 YES，超时返回 NO。未运行时立即返回 YES。
OBJC_EXTERN BOOL PeaceESPWaitFullyStopped(NSTimeInterval timeout);

/// ESP 是否正在运行（Overlay 已建立且帧循环存活）。
OBJC_EXTERN BOOL PeaceESPIsRunning(void);

/// 上次错误（可能为空）。
OBJC_EXTERN NSString * _Nullable PeaceESPLastError(void);

NS_ASSUME_NONNULL_END
