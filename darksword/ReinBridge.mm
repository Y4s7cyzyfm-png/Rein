//
//  ReinBridge.mm
//  Rein
//
//  Functional core for "初始化 DarkSword 内核" and "初始化 RemoteCall".
//  The kernel bootstrap flow mirrors DarkSpeed's DSBridge (ds_finish_enable
//  + DSBridgeBootstrap) with the SpringBoard HUD view machinery removed.
//

#import "ReinBridge.h"
#import "DSRemoteCall.h"

#import <UIKit/UIKit.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <stdlib.h>
#include <string.h>

// Vendored DarkSword headers are plain C / Objective-C.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

NSString * const ReinBridgeProgressNotification = @"com.rein.bridge.progress";

static os_unfair_lock g_stateLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_lastError = @"";
static NSString *g_stage = @"等待开始";
static pid_t g_remotePID = 0;

static std::atomic_bool g_kernelReady(false);
static std::atomic_bool g_kernelRunning(false);
static std::atomic_bool g_remoteReady(false);
static std::atomic_bool g_remoteRunning(false);
static std::atomic<double> g_progress(0.0);

static RemoteCall *g_springBoard = nil;

// ---------------------------------------------------------------------------
// kernelcache prefetch (ported from DarkSpeed's DSBridge)
// ---------------------------------------------------------------------------

static std::atomic<int> g_kernelPrefetchState(0); // 0 idle, 1 running, 2 ready, 3 failed
static dispatch_group_t g_kernelPrefetchGroup = nil;
static std::atomic<int> g_networkWarmupState(0); // 0 idle, 1 waiting, 2 ready, 3 timed out
static dispatch_group_t g_networkWarmupGroup = nil;
static const NSTimeInterval kNetworkWarmupTimeout = 180.0;
static const NSTimeInterval kNetworkRetryDelay = 3.0;

static dispatch_queue_t rein_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.rein.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void rein_set_stage(NSString *stage) {
    os_unfair_lock_lock(&g_stateLock);
    g_stage = [stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    os_log(OS_LOG_DEFAULT, "[ReinBridge] stage: %{public}@", g_stage);
}

static void rein_set_error(NSString *message) {
    os_unfair_lock_lock(&g_stateLock);
    g_lastError = [message copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    if (g_lastError.length > 0) {
        os_log_error(OS_LOG_DEFAULT, "[ReinBridge] %{public}@", g_lastError);
    }
}

static void rein_post_progress(void) {
    notify_post("com.rein.bridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ReinBridgeProgressNotification object:nil];
    });
}

static void rein_bridge_log(const char *message) {
    if (message && message[0]) {
        os_log(OS_LOG_DEFAULT, "[ReinBridge] %{public}s", message);
    }
}

// Feed DarkSword's native progress callback into the UI.
static void rein_bridge_progress(double progress) {
    g_progress.store(progress);
    rein_post_progress();
}

static BOOL rein_has_symbol_offsets(void) {
    return kernel_symbol_offsets_are_current();
}

static dispatch_group_t rein_kernel_prefetch_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_kernelPrefetchGroup = dispatch_group_create();
    });
    return g_kernelPrefetchGroup;
}

static dispatch_group_t rein_network_warmup_group(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_networkWarmupGroup = dispatch_group_create();
    });
    return g_networkWarmupGroup;
}

static BOOL rein_mark_network_warmup_ready(void) {
    int expected = 1;
    if (!g_networkWarmupState.compare_exchange_strong(expected, 2)) return NO;
    dispatch_group_leave(rein_network_warmup_group());
    return YES;
}

static void rein_start_kernel_prefetch(BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || rein_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        rein_set_stage(@"系统数据就绪");
        return;
    }

    int state = g_kernelPrefetchState.load();
    while (state != 1 && state != 2) {
        if (state == 3 && !retryFailed) return;
        if (g_kernelPrefetchState.compare_exchange_weak(state, 1)) break;
    }
    if (state == 1 || state == 2) return;

    rein_set_error(@"");
    rein_set_stage(@"正在缓存内核缓存");
    dispatch_group_t group = rein_kernel_prefetch_group();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = dlkcache();
        g_kernelPrefetchState.store(ready ? 2 : 3);
        if (ready) {
            os_log(OS_LOG_DEFAULT, "[ReinBridge] kernelcache prefetch ready");
            rein_mark_network_warmup_ready();
            rein_set_error(@"");
            rein_set_stage(@"内核缓存完成");
        } else {
            os_log_error(OS_LOG_DEFAULT, "[ReinBridge] kernelcache prefetch failed");
            if (g_networkWarmupState.load() == 1) {
                rein_set_stage(@"正在请求网络权限");
            } else {
                rein_set_stage(@"内核缓存失败");
            }
        }
        dispatch_group_leave(group);
    });
}

static BOOL rein_wait_for_kernel_attempt(CFAbsoluteTime deadline) {
    if (rein_has_symbol_offsets()) return YES;
    if (g_kernelPrefetchState.load() != 1) return NO;

    NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
    if (remaining <= 0.0) return NO;
    long waitResult = dispatch_group_wait(
        rein_kernel_prefetch_group(),
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    if (waitResult != 0) {
        os_log_error(OS_LOG_DEFAULT, "[ReinBridge] kernelcache prefetch timed out");
        return NO;
    }
    return rein_has_symbol_offsets();
}

static void rein_probe_network_until_ready(CFAbsoluteTime startedAt, NSUInteger attempt) {
    if (g_networkWarmupState.load() != 1) return;

    NSTimeInterval elapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
    rein_set_stage([NSString stringWithFormat:@"等待网络（%.0f 秒，第 %lu 次）",
                    elapsed, (unsigned long)attempt]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://api.appledb.dev/ios/main.json.xz"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8.0];
    request.HTTPMethod = @"HEAD";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL httpOK = !httpResponse ||
                (httpResponse.statusCode >= 200 && httpResponse.statusCode < 400);
            if (!error && response && httpOK) {
                if (!rein_mark_network_warmup_ready()) return;
                os_log(OS_LOG_DEFAULT, "[ReinBridge] network access ready after %.0fs",
                       CFAbsoluteTimeGetCurrent() - startedAt);
                rein_set_error(@"");
                rein_set_stage(@"网络已连接，正在准备内核缓存");
                rein_start_kernel_prefetch(YES);
                return;
            }

            NSTimeInterval totalElapsed = MAX(0.0, CFAbsoluteTimeGetCurrent() - startedAt);
            if (g_networkWarmupState.load() != 1) return;
            if (totalElapsed >= kNetworkWarmupTimeout) {
                int expected = 1;
                if (!g_networkWarmupState.compare_exchange_strong(expected, 3)) return;
                NSString *detail = error.localizedDescription;
                if (!detail.length && httpResponse) {
                    detail = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
                }
                if (!detail.length) detail = @"无有效响应";
                os_log_error(OS_LOG_DEFAULT,
                             "[ReinBridge] network warm-up timed out: %{public}@", detail);
                rein_set_stage(@"等待网络超时");
                rein_set_error([NSString stringWithFormat:
                    @"等待 %.0f 秒后仍无法连接：%@\n请检查网络权限与连接后重试。", totalElapsed, detail]);
                dispatch_group_leave(rein_network_warmup_group());
                return;
            }

            rein_set_stage([NSString stringWithFormat:
                @"网络未就绪，已等待 %.0f 秒，%.0f 秒后重试", totalElapsed, kNetworkRetryDelay]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kNetworkRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                rein_probe_network_until_ready(startedAt, attempt + 1);
            });
        }] resume];
}

static void rein_warm_up_network_and_prefetch_kernel_cache(void) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || rein_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        rein_set_error(@"");
        rein_set_stage(@"系统数据就绪");
        return;
    }

    BOOL shouldStartProbe = NO;
    int expected = 0;
    if (g_networkWarmupState.compare_exchange_strong(expected, 1)) {
        shouldStartProbe = YES;
    } else if (expected == 3) {
        expected = 3;
        shouldStartProbe = g_networkWarmupState.compare_exchange_strong(expected, 1);
    }

    if (shouldStartProbe) {
        rein_set_error(@"");
        rein_set_stage(@"正在请求网络权限");
        dispatch_group_enter(rein_network_warmup_group());
        rein_probe_network_until_ready(CFAbsoluteTimeGetCurrent(), 1);
    }

    // The real request is the source of truth; devices without a regional
    // network prompt can proceed immediately.
    rein_start_kernel_prefetch(YES);
}

static BOOL rein_wait_for_kernel_prefetch(NSTimeInterval timeout, BOOL retryFailed) {
    BOOL hasBuiltinOffsets = install_builtin_kernel_symbol_offsets();
    if (hasBuiltinOffsets || rein_has_symbol_offsets()) {
        g_kernelPrefetchState.store(2);
        return YES;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    rein_warm_up_network_and_prefetch_kernel_cache();
    rein_start_kernel_prefetch(retryFailed);
    if (rein_wait_for_kernel_attempt(deadline)) return YES;

    if (g_networkWarmupState.load() == 1) {
        NSTimeInterval remaining = MAX(0.0, deadline - CFAbsoluteTimeGetCurrent());
        if (remaining <= 0.0) return NO;
        long networkWaitResult = dispatch_group_wait(
            rein_network_warmup_group(),
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if (networkWaitResult != 0) {
            os_log_error(OS_LOG_DEFAULT, "[ReinBridge] network warm-up timed out");
            return NO;
        }
    }
    if (rein_has_symbol_offsets()) return YES;
    if (g_networkWarmupState.load() != 2) return NO;

    rein_start_kernel_prefetch(retryFailed);
    return rein_wait_for_kernel_attempt(deadline);
}

// ---------------------------------------------------------------------------
// DarkSword kernel bootstrap (mirrors DSBridgeBootstrap)
// ---------------------------------------------------------------------------

static BOOL rein_bootstrap_kernel(void) {
    if (g_kernelReady.load() && ds_is_ready()) return YES;

    ds_set_log_callback(rein_bridge_log);
    ds_set_progress_callback(rein_bridge_progress);
    os_log(OS_LOG_DEFAULT, "[ReinBridge] running DarkSword chain off-main-thread");

    // offsets_init() must run BEFORE ds_run() — pe_v1() needs the socket/inpcb
    // offsets to find the corrupted socket.
    init_offsets();
    offsets_init();
    install_builtin_kernel_symbol_offsets();

    rein_set_stage(@"正在初始化 DarkSword");
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        rein_set_error([NSString stringWithFormat:@"DarkSword 初始化失败（%d）", result]);
        return NO;
    }

    g_kernelReady.store(true);
    rein_set_stage(@"DarkSword 初始化完成");
    rein_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[ReinBridge] DarkSword ready");
    return YES;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

BOOL ReinKernelIsReady(void) { return g_kernelReady.load() && ds_is_ready(); }
BOOL ReinRemoteCallIsReady(void) { return g_remoteReady.load(); }
BOOL ReinKernelIsRunning(void) { return g_kernelRunning.load(); }
BOOL ReinRemoteCallIsRunning(void) { return g_remoteRunning.load(); }

NSString *ReinBridgeLastError(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *error = [g_lastError copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return error;
}

NSString *ReinBridgeStage(void) {
    os_unfair_lock_lock(&g_stateLock);
    NSString *stage = [g_stage copy] ?: @"";
    os_unfair_lock_unlock(&g_stateLock);
    return stage;
}

double ReinBridgeProgress(void) { return g_progress.load(); }
pid_t ReinRemoteCallPID(void) { return g_remotePID; }

void ReinInitializeDarkSwordKernel(void) {
    if (ReinKernelIsReady()) {
        rein_set_stage(@"DarkSword 已就绪");
        rein_post_progress();
        return;
    }
    if (g_kernelRunning.load()) return;

    g_kernelRunning.store(true);
    g_progress.store(0.0);
    rein_set_error(@"");
    rein_set_stage(@"正在准备启动");
    rein_post_progress();

    dispatch_async(rein_bridge_queue(), ^{
        @autoreleasepool {
            g_progress.store(0.03);
            rein_set_stage(@"正在准备系统数据");
            rein_post_progress();

            if (!rein_wait_for_kernel_prefetch(240.0, YES)) {
                NSString *preparationError = ReinBridgeLastError();
                g_kernelRunning.store(false);
                rein_set_stage(@"启动失败");
                rein_set_error(preparationError.length > 0 ? preparationError :
                    @"内核缓存下载或解析失败，网络权限可能仍在等待。请检查网络后重试。");
                rein_post_progress();
                return;
            }

            if (!rein_bootstrap_kernel()) {
                g_kernelRunning.store(false);
                rein_set_stage(@"启动失败");
                rein_post_progress();
                return;
            }

            g_kernelRunning.store(false);
            g_progress.store(1.0);
            rein_set_stage(@"DarkSword 内核就绪");
            rein_post_progress();
        }
    });
}

void ReinInitializeRemoteCall(void) {
    if (ReinRemoteCallIsReady()) {
        rein_set_stage(@"RemoteCall 已就绪");
        rein_post_progress();
        return;
    }
    if (g_remoteRunning.load()) return;

    if (!ReinKernelIsReady()) {
        rein_set_error(@"请先初始化 DarkSword 内核，再初始化 RemoteCall。");
        rein_set_stage(@"内核未就绪");
        rein_post_progress();
        return;
    }

    g_remoteRunning.store(true);
    rein_set_stage(@"正在定位 SpringBoard");
    rein_post_progress();

    dispatch_async(rein_bridge_queue(), ^{
        @autoreleasepool {
            @try {
                uint64_t sbProc = proc_find_by_name("SpringBoard");
                if (!sbProc) {
                    g_remoteRunning.store(false);
                    rein_set_stage(@"RemoteCall 失败");
                    rein_set_error(@"未找到 SpringBoard 进程，无法建立 RemoteCall。");
                    rein_post_progress();
                    return;
                }

                os_log(OS_LOG_DEFAULT,
                       "[ReinBridge] SpringBoard proc=0x%llx self=0x%llx — starting RemoteCall",
                       (unsigned long long)sbProc, (unsigned long long)ds_get_our_proc());

                rein_set_stage(@"正在连接 SpringBoard");
                rein_post_progress();

                RemoteCall *process = [[RemoteCall alloc] initWithProcess:@"SpringBoard"
                                                     useMigFilterBypass:NO];
                if (!process || !process.trojanMem || process.pid <= 1) {
                    NSString *remoteError = [RemoteCall lastInitError];
                    if (remoteError.length == 0 && process) remoteError = process.lastError;
                    if (remoteError.length == 0) remoteError = @"RemoteCall 初始化失败（无详细信息）";
                    g_remoteRunning.store(false);
                    rein_set_stage(@"RemoteCall 失败");
                    rein_set_error([NSString stringWithFormat:@"SpringBoard 连接失败：%@", remoteError]);
                    rein_post_progress();
                    return;
                }

                g_springBoard = process;
                g_remotePID = process.pid;
                g_remoteReady.store(true);
                g_remoteRunning.store(false);
                rein_set_stage(@"RemoteCall 已连接");
                rein_set_error(@"");
                rein_post_progress();
                os_log(OS_LOG_DEFAULT, "[ReinBridge] RemoteCall active (SpringBoard pid=%d)", process.pid);
            } @catch (NSException *exception) {
                g_springBoard = nil;
                g_remoteReady.store(false);
                g_remoteRunning.store(false);
                rein_set_stage(@"RemoteCall 失败");
                rein_set_error([NSString stringWithFormat:@"RemoteCall 异常：%@", exception.reason]);
                rein_post_progress();
            }
        }
    });
}
