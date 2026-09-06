//
//  UESDumper.h
//  Rein
//
//  Dump UE4 SDK：参考 MJx0/iOS_UEDumper（基于 UE4Dumper-4.25）移植，
//  改用 Rein 的内核远程读（vmmapremotepage 页映射）读取游戏内存，
//  无需注入游戏进程，只需要 DarkSword 内核就绪 + 游戏正在运行。
//
//  输出（Documents/SDK/，Files app 可见）：
//    Objects.txt   全部 UObject 清单（地址 | 类 | 完整路径）
//    Offsets.txt   关键地址（镜像基址 / GWorld / GNames / GUObjectArray）
//    SDK.hpp       类/结构/枚举的 SDK 头文件
//    script.json   函数名+地址（IDA/Ghidra 导入用）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 开始 dump（异步）。前置：内核就绪 + ShadowTrackerExtra 正在运行。
OBJC_EXTERN void UESDumperStart(void);

/// dump 是否正在进行。
OBJC_EXTERN BOOL UESDumperIsRunning(void);

/// 上次错误（可能为空）。
OBJC_EXTERN NSString * _Nullable UESDumperLastError(void);

/// 上次输出的目录路径（dump 成功后有效）。
OBJC_EXTERN NSString * _Nullable UESDumperLastOutputPath(void);

NS_ASSUME_NONNULL_END
