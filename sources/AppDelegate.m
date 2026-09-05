//
//  AppDelegate.m
//  Rein
//

#import "AppDelegate.h"
#import "RootViewController.h"
#import "ReinBridge.h"
#import "PeaceESP.h"
#import <unistd.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[RootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

// 退后台后 App 会被冻结，无法再应答 trojan 线程停在 FAKE_LR_TROJAN(0x401)
// 的 mach 异常；随后进程被回收时端口销毁，悬停线程会以 SIGBUS 把
// SpringBoard 打崩（即“注销”）。这里在系统给的存活窗口内把会话安全拆掉：
// 先停 ESP（Overlay 会从 SpringBoard 移除），再销毁远程线程与异常端口。
- (void)applicationDidEnterBackground:(UIApplication *)application {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:task];
    }];
    ReinTeardownRemoteCall();
    // teardown 在 bridge 串行队列上异步执行，结束后释放后台任务
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 等 teardown 完成（上限 ~25s，随后交由后台任务到期兜底）
        for (int i = 0; i < 125 &&
             (ReinRemoteCallIsReady() || ReinRemoteCallIsRunning()); i++) {
            usleep(200000);
            if (app.applicationState != UIApplicationStateBackground) break;
        }
        [app endBackgroundTask:task];
    });
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // 正常退出（少见，但有机会跑）：同步尽最后一份力拆干净
    PeaceESPStop();
    PeaceESPWaitFullyStopped(3.0);
    RemoteCall *process = ReinBridgeRemoteCall();
    if (process) {
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
        }
    }
}

@end
