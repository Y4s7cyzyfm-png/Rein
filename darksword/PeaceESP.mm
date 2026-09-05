//
//  PeaceESP.mm
//  Rein
//
//  v7：游戏内存改经 TaskRop 的 vmmapremotepage（vm_object 共享内存映射）
//  读取——不再走 ptov_table / pmap 页表遍历（iOS 18.6 上两者语义均与预期不符）。
//  远程 ObjC 调用层移植自 DarkSpeed 的 DSBridge（NSInvocation on SB main thread）。
//

#import "PeaceESP.h"
#import "ReinBridge.h"
#import "DSRemoteCall.h"

#import <UIKit/UIKit.h>
#import <os/log.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

extern "C" {
#import "darksword.h"
#import "utils.h"
#import "offsets.h"

// TaskRop/vm.h 的接口（vm.m 为 C 链接；完整 vm.h 含 ObjC @interface，不整体引入）。
// vmmapremotepage：把目标进程 vm_map 里某页所属的 vm_object 经引用计数 +
// 本地 memory entry 替换，映射进本进程地址空间——无需 ptov/页表遍历。
struct vmshmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool     used;
};
struct vmshmem vmmapremotepage(uint64_t vmMap, uint64_t address);
void vmmapiterateentries(uint64_t vmmaptptr, void (^itblock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop));
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
}

// ============================================================
// 控制台日志（os_log）
// Xcode 控制台直接输出；真机用 Console.app / idevicesyslog
// 过滤 subsystem “com.rein.peaceesp” 即可看到全部 [PE] 日志。
// ============================================================

static NSString *gLastErrorDetail = @""; // 最近一次初始化失败的具体原因

static os_log_t pe_log_handle(void) {
    static os_log_t handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = os_log_create("com.rein.peaceesp", "esp");
    });
    return handle;
}

// os_log 隐私标记仅 %{public}s/{public} 形式；镜像前剔除 "{public}"（不带 %，
// 否则 "%{public}@" 会变成字面 "@"，参数被丢弃——真机已踩坑）
static NSString *pe_console_fmt(NSString *fmt) {
    return [fmt stringByReplacingOccurrencesOfString:@"{public}" withString:@""];
}

// 统一先把整行渲染成 NSString，再以常量格式 + %s 送 os_log：
// os_log 对 %@ 支持不可靠，且镜像与 os_log 用同一份渲染结果，杜绝两边不一致。
static NSString *pe_console_vformat(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *out = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return out;
}

#define PE_LOG(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *pe_log_line = \
            pe_console_vformat(pe_console_fmt(@"[PE] " fmt), ##__VA_ARGS__); \
        os_log(pe_log_handle(), "[PE] %{public}s", pe_log_line.UTF8String ?: "(null)"); \
        ReinAppendConsoleLog(pe_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

#define PE_LOG_ERROR(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *pe_log_line = \
            pe_console_vformat(pe_console_fmt(@"[PE] " fmt), ##__VA_ARGS__); \
        os_log_error(pe_log_handle(), "[PE] %{public}s", pe_log_line.UTF8String ?: "(null)"); \
        ReinAppendConsoleLog(pe_log_line); \
        _Pragma("clang diagnostic pop") \
    } while (0)

/// 记录初始化失败的具体原因（拼进 PeaceESPLastError 的提示，并输出错误级日志）
static void pe_detail(NSString *detail) {
    if (detail.length == 0) return;
    gLastErrorDetail = [detail copy];
    PE_LOG_ERROR("失败原因：%{public}@", detail);
}

// ============================================================
// 配置
// ============================================================

#define PE_OVERLAY_PROCESS  "SpringBoard"
#define PE_GAME_PROCESS     "ShadowTrackerExtra"
#define PE_MAX_ENEMIES       60
#define PE_DEFAULT_INTERVAL  0.033
#define PE_FAR_CLIP          40000.0f
#define PE_PLAYER_HEIGHT     175.0f

// 远程页缓存（开放寻址哈希；容量 2 的幂）
#define PE_PAGE_CACHE_CAP 512
#define PE_PAGE_NCACHE_CAP 256

// ============================================================
// 基础类型
// ============================================================

typedef struct { double x, y, width, height; } PE_Rect;
typedef struct { float x, y, z; } PE_Vec3;
typedef struct { float x, y; bool visible; } PE_Vec2S;

typedef struct {
    PE_Vec3 location;
    float   health, healthMax, distance;
    bool    isAI, isDead;
    int     teamID;
    __unsafe_unretained NSString *name; // 仅供 tick 内立即使用
    PE_Vec3 top, bottom;
} PE_Enemy;

// ============================================================
// 全局状态
// ============================================================

static volatile bool gRun = false, gOverlayReady = false, gGameOK = false;
static uint64_t gOverlayWin = 0;
static uint64_t gBox[PE_MAX_ENEMIES], gName[PE_MAX_ENEMIES], gDist[PE_MAX_ENEMIES];
static double   gSW = 0, gSH = 0;
static int      gVis = 0, gMyTeam = -1;
static uint64_t gFrames = 0, gGameBase = 0;
static PE_Vec3  gMyPos = {0};

// ============================================================
// 游戏内存读取基础设施（vm_object 映射 + 远程页缓存）
// ============================================================

static uint64_t gGameVMMap = 0;         // 游戏 vm_map（内核地址）
static int      gPageShift = 0;          // 12=4KB, 14=16KB

typedef struct {
    uint64_t remotePage; // 远程页基址（key；0 = 空槽）
    uint64_t localPage;  // 本地映射基址（value）
} PEPageSlot;

static PEPageSlot gPageCache[PE_PAGE_CACHE_CAP];
static int  gPageCacheCount = 0;
static uint64_t gPageNeg[PE_PAGE_NCACHE_CAP]; // 近期映射失败的页（负缓存）
static int  gMapFailLogged = 0;

// 帧循环环节诊断计数（限流：每种失败只记前 3 次，防 30fps 刷屏）
static int gFailMyinfo = 0, gFailVp = 0, gFailActors = 0;

// ---- 检测页大小 ----
static void pe_detect_page_size(void)
{
    if (gPageShift != 0) return;
    vm_size_t ps = 0;
    if (host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps > 0) {
        if (ps >= 16384)      gPageShift = 14;
        else if (ps >= 4096)  gPageShift = 12;
    }
    if (gPageShift == 0) gPageShift = 14; // 默认 16KB
    PE_LOG("page_size=%d shift=%d", 1 << gPageShift, gPageShift);
}

// ---- 游戏内存读取层（vm_object 共享内存映射 + 页缓存） ----
// vmmapremotepage 会遍历游戏 vm_map 找到地址所属 entry 的 vm_object，
// 把该对象映射进本进程（并把失败结果缓存，避免坏指针反复全表遍历）。

static uint64_t pe_page_size(void) {
    return (uint64_t)1 << (gPageShift ? gPageShift : 14);
}

// 整体回收：解除全部本地映射并清空正/负缓存（ESP 重启、周期防陈旧时调用）
static void pe_page_cache_flush(void) {
    uint64_t ps = pe_page_size();
    for (int i = 0; i < PE_PAGE_CACHE_CAP; i++) {
        if (gPageCache[i].remotePage) {
            mach_vm_deallocate(mach_task_self(),
                               (mach_vm_address_t)gPageCache[i].localPage, ps);
            gPageCache[i].remotePage = 0;
        }
    }
    gPageCacheCount = 0;
    memset(gPageNeg, 0, sizeof(gPageNeg));
    gMapFailLogged = 0;
}

static bool pe_page_is_bad(uint64_t page) {
    uint64_t mask = PE_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < PE_PAGE_NCACHE_CAP; i++) {
        uint64_t v = gPageNeg[(h + i) & mask];
        if (v == page) return true;
        if (v == 0) return false;
    }
    return false;
}

static void pe_page_mark_bad(uint64_t page) {
    uint64_t mask = PE_PAGE_NCACHE_CAP - 1;
    uint64_t h = (page >> 14) & mask;
    for (uint64_t i = 0; i < PE_PAGE_NCACHE_CAP; i++) {
        uint64_t slot = (h + i) & mask;
        if (gPageNeg[slot] == page) return;
        if (gPageNeg[slot] == 0) { gPageNeg[slot] = page; return; }
    }
    gPageNeg[h] = page; // 满则覆盖首个槽
}

static uint64_t pe_page_cache_get(uint64_t remotePage) {
    uint64_t mask = PE_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PE_PAGE_CACHE_CAP; i++) {
        PEPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) return s->localPage;
        if (s->remotePage == 0) break;
    }
    return 0;
}

static void pe_page_cache_put(uint64_t remotePage, uint64_t localPage) {
    if (gPageCacheCount >= PE_PAGE_CACHE_CAP) {
        PE_LOG("页缓存满（%d），整体回收", gPageCacheCount);
        pe_page_cache_flush();
    }
    uint64_t mask = PE_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < PE_PAGE_CACHE_CAP; i++) {
        PEPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) { s->localPage = localPage; return; }
        if (s->remotePage == 0) {
            s->remotePage = remotePage;
            s->localPage = localPage;
            gPageCacheCount++;
            return;
        }
    }
}

static uint64_t pe_map_remote_page(uint64_t remotePage) {
    uint64_t local = pe_page_cache_get(remotePage);
    if (local) return local;
    if (pe_page_is_bad(remotePage)) return 0;

    struct vmshmem sh = vmmapremotepage(gGameVMMap, remotePage);
    if (!sh.used || !sh.localAddress) {
        if (gMapFailLogged < 3) { // 坏指针常见，只记前几次防刷屏
            PE_LOG_ERROR("映射远程页失败 page=0x%llx",
                         (unsigned long long)remotePage);
            gMapFailLogged++;
        }
        pe_page_mark_bad(remotePage);
        return 0;
    }
    pe_page_cache_put(remotePage, sh.localAddress);
    return sh.localAddress;
}

// ---- 内核读原语（远程页映射，失败回退 0，绝不 panic） ----
static bool kreadbuf(uint64_t va, void *out, size_t sz) {
    if (sz == 0 || gPageShift == 0 || sz > pe_page_size()) return false;
    uint64_t ps = pe_page_size();
    uint64_t page = va & ~(ps - 1);
    uint64_t off = va - page;
    if (off + sz > ps) { // 跨页：分段映射
        size_t first = (size_t)(ps - off);
        return kreadbuf(va, out, first) &&
               kreadbuf(va + first, (char *)out + first, sz - first);
    }
    uint64_t local = pe_map_remote_page(page);
    if (!local) return false;
    memcpy(out, (const void *)(local + off), sz);
    return true;
}
static uint64_t kread64(uint64_t va) {
    uint64_t v = 0;
    kreadbuf(va, &v, sizeof(v));
    return v;
}
static uint32_t kread32(uint64_t va) {
    uint32_t v = 0;
    kreadbuf(va, &v, sizeof(v));
    return v;
}

// ============================================================
// 远程 ObjC 调用层（移植自 DSBridge：NSInvocation on SB main thread）
// ============================================================

static RemoteCall *gRC = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gSelCache = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gClassCache = nil;

typedef struct {
    const void *bytes;
    uint64_t size;
} PEArg;

static uint64_t pe_sel(const char *name) {
    if (!gRC || !gRC.trojanMem || !name) return 0;
    if (!gSelCache) gSelCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = gSelCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_sel(gRC, name);
    if (value) gSelCache[key] = @(value);
    return value;
}

static uint64_t pe_class(const char *name) {
    if (!gRC || !gRC.trojanMem || !name) return 0;
    if (!gClassCache) gClassCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = gClassCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_getClass(gRC, name);
    if (value) gClassCache[key] = @(value);
    return value;
}

static BOOL pe_perform_main(uint64_t target, uint64_t selector,
                            uint64_t argument, BOOL wait) {
    if (!gRC || !gRC.trojanMem || !target || !selector) return NO;
    uint64_t perform = pe_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return NO;
    remote_msg(gRC, target, perform, selector, argument, wait ? 1 : 0, 0);
    return gRC.trojanMem != 0;
}

// 在调用线程组 NSInvocation，再同步投递到 SpringBoard 真实主线程执行
// （照搬 DSBridge 的做法：task->threads.next 在 iOS 17 上可能不是主线程）
static BOOL pe_invoke_main_result(uint64_t target, uint64_t selector,
                                  const PEArg *arguments, NSUInteger argumentCount,
                                  void *result, NSUInteger resultSize) {
    if (!gRC || !target || !selector || !gRC.trojanMem) return NO;

    uint64_t poolClass = pe_class("NSAutoreleasePool");
    uint64_t allocSelector = pe_sel("alloc");
    uint64_t initSelector = pe_sel("init");
    uint64_t drainSelector = pe_sel("drain");
    uint64_t autoreleasePool = poolClass && allocSelector && initSelector && drainSelector
        ? remote_msg(gRC,
                     remote_msg(gRC, poolClass, allocSelector, 0, 0, 0, 0),
                     initSelector, 0, 0, 0, 0)
        : 0;
    if (!autoreleasePool) return NO;

    @try {
        uint64_t signature = remote_msg(gRC, target,
                                        pe_sel("methodSignatureForSelector:"),
                                        selector, 0, 0, 0);
        if (!gRC.trojanMem) return NO;
        uint64_t invocationClass = pe_class("NSInvocation");
        uint64_t invocation = signature && invocationClass
            ? remote_msg(gRC, invocationClass,
                         pe_sel("invocationWithMethodSignature:"),
                         signature, 0, 0, 0)
            : 0;
        if (!invocation || !gRC.trojanMem) return NO;

        remote_msg(gRC, invocation, pe_sel("setTarget:"), target, 0, 0, 0);
        if (!gRC.trojanMem) return NO;
        remote_msg(gRC, invocation, pe_sel("setSelector:"), selector, 0, 0, 0);
        if (!gRC.trojanMem) return NO;

        uint64_t scratch = gRC.trojanMem + 0x800;
        for (NSUInteger index = 0; index < argumentCount; index++) {
            if (!arguments[index].bytes || arguments[index].size == 0 ||
                ![gRC remote_write:scratch
                              from:arguments[index].bytes
                              size:(uint64_t)arguments[index].size]) {
                return NO;
            }
            remote_msg(gRC, invocation, pe_sel("setArgument:atIndex:"),
                       scratch, index + 2, 0, 0);
            if (!gRC.trojanMem) return NO;
            scratch += (arguments[index].size + 15) & ~15ULL;
        }

        pe_perform_main(invocation, pe_sel("invoke"), 0, YES);
        if (!gRC.trojanMem) return NO;
        if (result && resultSize > 0) {
            uint64_t resultScratch = gRC.trojanMem + 0xC00;
            memset(result, 0, resultSize);
            if (![gRC remote_write:resultScratch from:result size:(uint64_t)resultSize]) return NO;
            remote_msg(gRC, invocation, pe_sel("getReturnValue:"),
                       resultScratch, 0, 0, 0);
            if (!gRC.trojanMem) return NO;
            if (![gRC remoteRead:resultScratch to:result size:(uint64_t)resultSize]) return NO;
        }
        return YES;
    } @finally {
        if (gRC.trojanMem) {
            remote_msg(gRC, autoreleasePool, drainSelector, 0, 0, 0, 0);
        }
    }
}

static BOOL pe_call_main_noarg(uint64_t target, const char *selectorName) {
    return pe_invoke_main_result(target, pe_sel(selectorName), NULL, 0, NULL, 0);
}

static uint64_t pe_get_main(uint64_t target, const char *selectorName) {
    uint64_t result = 0;
    pe_invoke_main_result(target, pe_sel(selectorName), NULL, 0, &result, sizeof(result));
    return (result && gRC.trojanMem) ? result : 0;
}

// 工厂方法结果立即 retain，跨 performSelector 轮次保活（DSBridge 经验）
static uint64_t pe_get_main_retained(uint64_t target, const char *selectorName,
                                     const PEArg *args, NSUInteger argc) {
    uint64_t result = 0;
    pe_invoke_main_result(target, pe_sel(selectorName), args, argc, &result, sizeof(result));
    if (!result || !gRC.trojanMem) return 0;
    remote_msg(gRC, result, pe_sel("retain"), 0, 0, 0, 0);
    return gRC.trojanMem ? result : 0;
}

static BOOL pe_set_double_main(uint64_t target, const char *selectorName, double value) {
    PEArg argument = { &value, sizeof(value) };
    return pe_invoke_main_result(target, pe_sel(selectorName), &argument, 1, NULL, 0);
}

static BOOL pe_set_u64_main(uint64_t target, const char *selectorName, uint64_t value) {
    PEArg argument = { &value, sizeof(value) };
    return pe_invoke_main_result(target, pe_sel(selectorName), &argument, 1, NULL, 0);
}

static BOOL pe_set_rect_main(uint64_t target, const char *selectorName, CGRect value) {
    PEArg argument = { &value, sizeof(value) };
    return pe_invoke_main_result(target, pe_sel(selectorName), &argument, 1, NULL, 0);
}

// 远程 NSString：字节常驻 trojanMem 保留页，避免每帧 remote malloc/write/free
static const uint64_t kPETextScratchOffset = 0x1000;
static const size_t kPETextScratchCapacity = 0x400;

static uint64_t pe_nsstring(NSString *value) {
    if (!gRC || !gRC.trojanMem || !value) return 0;
    const char *utf8 = value.UTF8String;
    if (!utf8) return 0;
    size_t length = strlen(utf8) + 1;
    if (length > kPETextScratchCapacity) return 0;

    uint64_t scratch = gRC.trojanMem + kPETextScratchOffset;
    if (![gRC remote_write:scratch from:utf8 size:(uint64_t)length]) return 0;

    uint64_t stringClass = pe_class("NSString");
    uint64_t alloc = pe_sel("alloc");
    uint64_t init = pe_sel("initWithUTF8String:");
    if (!stringClass || !alloc || !init) return 0;
    uint64_t object = remote_msg(gRC, stringClass, alloc, 0, 0, 0, 0);
    if (!object) return 0;
    uint64_t string = remote_msg(gRC, object, init, scratch, 0, 0, 0);
    if (!string) {
        uint64_t release = pe_sel("release");
        if (release) remote_msg(gRC, object, release, 0, 0, 0, 0);
    }
    return string;
}

// ============================================================
// 偏移（2026-09 版本数据，随游戏版本更新）
// ============================================================

enum {
    // 全局（映像内）
    O_GWORLD = 0x1148B608,
    O_GNAME  = 0x11FBA198,

    // 自身链（GWorld 起，五级指针 → 自身 Pawn）
    O_SELF2 = 0xC0, O_SELF3 = 0x88, O_SELF4 = 0x30, O_SELF5 = 0x3540,

    // 相机（PC → 相机指针 0x680 → CameraCache/POV 沿用旧值，待验证）
    O_CAMPTR  = 0x680,  // 相机指针（自 PC）
    O_CAMCACHE = 0x640, // Cache 条目指针（自相机；POV 在 Cache+0x28）

    // Actor / Pawn 字段（安卓 SDK 对照表，iOS 同源）
    O_ROOTCOMP  = 0x260,  // 坐标1（RootComponent 指针）
    O_LOC       = 0x1B0,  // 坐标2：RootComponent 内 vec3（安卓表 0x1f0）
    O_NAME      = 0xAF8,  // 玩家名字（FString）
    O_UID       = 0xB20,  // 玩家 UID
    O_PLAYERDATA= 0x5F0,  // 玩家数据指针
    O_ISREAL    = 0xB50,  // 是否真人
    O_TEAM      = 0xB78,  // 队伍编号
    O_AI        = 0xB94,  // 人机判断
    O_ADV_AI    = 0xB9C,  // 高级人机判断
    O_HP        = 0x1060, // 当前血量
    O_HPMAX     = 0x1068, // 最大血量
    O_ACTION    = 0x1700, // 人物状态
    O_RANK1     = 0x3334, // 一称判断
    O_HEIGHT    = 0x10C0, // 人物高度
    O_CROSSHAIR_ID = 0x3B9C, // 人物过滤/判断

    // 骨骼（预留，骨骼 ESP 用）
    O_MESHARRAY = 0x658,  // 阵列偏移
    O_BONEARRAY = 0x1D0,  // 骨骼阵列
    O_BONEPTR   = 0x838,  // 骨骼指针

    // 关卡 / Actor 数组（沿用旧值，本次未提供新数据）
    O_PERSISTLEVEL = 0xB8, O_ACTORS = 0xA0, O_ACTORCNT = 0xA8,

    // ---- 以下为 2026-09 新增功能偏移（已录入，功能逐步接入） ----

    // 击杀信息（对象地址 → 击杀指针 0x2988 → 击杀数量 0x2C；含击杀者/受害者名字）
    O_KILLLIST = 0x2988, O_KILLCOUNT = 0x2C,

    // 载具（对象地址 → 载具指针 0xC00 → 耐久/油量；ID 0x20B0）
    O_VEHICLE = 0xC00, O_VEHID = 0x20B0,
    O_VEHHP = 0x1F8, O_VEHHPMAX = 0x1F4, O_VEHFUEL = 0x21C, O_VEHFUELMAX = 0x218,

    // 准星（准星X 0x600 / 准星Y 0x604）
    O_CROSSX = 0x600, O_CROSSY = 0x604,

    // 开火 / 开镜判断（对象地址；安卓表：开火 0x2750，开镜 0x1848）
    O_FIRING = 0x2750, O_SCOPED = 0x1848,

    // 投掷物（组件 0x33B0 → 配置 0x130 → 更多配置 0x8 → 手雷爆炸时间 0x88C）
    O_THROWCOMP = 0x33B0, O_THROWCONF = 0x130, O_THROWMORE = 0x8, O_GRENADEFUSE = 0x88C,

    // 手持武器（武器指针 0x37A0 → [武器实体 0x2048] → 当前武器 0x990 → 手持 0xDD0）
    O_WEAPTR = 0x37A0, O_WEAPENTITY = 0x2048, O_CURWEAP = 0x990, O_HOLDWEAP = 0xDD0,
    O_CURAMMO = 0x2058, O_MAXAMMO = 0x205C, O_BARRELBULLET = 0x2068, O_BULLETSPEED = 0x15D4,

    // 无后座（自身 → 0x1170 → 0xC80 → 无后X 0x1ED8 / 无后Y 0x1EE4）
    O_NR1 = 0x1170, O_NR2 = 0xC80, O_NR_X = 0x1ED8, O_NR_Y = 0x1EE4,

    // 掩体判断（自身 → 玩家控制器 0x60C8 → 相机指针 0x680；调用 Controller.LineOfSightTo）
    O_PC_FROM_PAWN = 0x60C8,
};

// ============================================================
// 第 1 层：游戏内存
// ============================================================

// 遍历游戏 vm_map 条目定位主映像基址：
// 在 [0x100000000, 0x800000000) 窗口内（共享缓存之下的 app 映像区），
// 优先检查大段（≥16MB，UE4 主映像 __TEXT 量级）的首页 Mach-O magic。
static bool pe_find_game_base(void)
{
    // block 按值捕获 C 数组且为只读——用堆缓冲区 + 指针捕获
    typedef struct { uint64_t start, end; } PEMapCand;
    PEMapCand *cand = (PEMapCand *)calloc(64, sizeof(PEMapCand));
    if (!cand) return false;
    __block int n = 0;
    vmmapiterateentries(gGameVMMap, ^(uint64_t start, uint64_t end,
                                      uint64_t entry, BOOL *stop) {
        if (n >= 64) { *stop = YES; return; }
        if (start < 0x100000000ULL || start >= 0x800000000ULL) return;
        if (end - start < 0x4000ULL) return;
        cand[n].start = start;
        cand[n].end = end;
        n++;
    });
    PE_LOG("vm_map 窗口内候选条目 %d 个", n);
    for (int i = 0; i < n; i++) { // 全量打出布局，便于离线分析偏移
        PE_LOG("  entry[%d] [0x%llx,0x%llx) size=%lluKB",
               i, (unsigned long long)cand[i].start,
               (unsigned long long)cand[i].end,
               (unsigned long long)((cand[i].end - cand[i].start) >> 10));
    }

    // 按大小降序验证：主映像（UE4 可执行）通常是最大的 Mach-O 条目，
    // 且基址 + 偏移必须落在所选条目内——GWorld 全局在映像数据段里。
    typedef struct { uint64_t size, start, end; } PESorted;
    PESorted list[64];
    int m = 0;
    for (int i = 0; i < n && m < 64; i++) {
        if (cand[i].end > cand[i].start) {
            list[m].size = cand[i].end - cand[i].start;
            list[m].start = cand[i].start;
            list[m].end = cand[i].end;
            m++;
        }
    }
    // 插入排序（m ≤ 64，规模小）
    for (int i = 1; i < m; i++) {
        PESorted key = list[i];
        int j = i - 1;
        while (j >= 0 && list[j].size < key.size) { list[j+1] = list[j]; j--; }
        list[j+1] = key;
    }

    // iOS 会把一个映像的各 Mach-O 段拆成多个相邻 vm_map 条目，
    // 单条目大小不代表映像大小——不再用“条目容纳偏移”做硬性过滤，
    // 而是直接读 base+O_GWORLD 并校验值本身：
    //   1) GWorld 是用户态指针（0x1B..0x8B 窗口内）
    //   2) 自身链第一跳 GWorld+0xC0 也是用户态指针
    // 页映射对空洞免疫（读不到的页返回 0，且有负缓存），不会误判。
    bool found = false;
    for (int i = 0; i < m && !found; i++) {
        uint32_t magic = 0;
        if (!kreadbuf(list[i].start, &magic, sizeof(magic))) continue;
        if (magic != 0xFEEDFACF && magic != 0xCFFAEDFE) continue;
        uint64_t gwv = kread64(list[i].start + O_GWORLD);
        if (gwv < 0x100000000ULL || gwv >= 0x800000000ULL) {
            PE_LOG("entry [0x%llx,0x%llx) 是 Mach-O 但 base+O_GWORLD 处的值 0x%llx 不是有效指针，跳过",
                   (unsigned long long)list[i].start,
                   (unsigned long long)list[i].end,
                   (unsigned long long)gwv);
            continue;
        }
        uint64_t hop1 = kread64(gwv + O_SELF2);
        if (hop1 < 0x100000000ULL || hop1 >= 0x800000000ULL) {
            PE_LOG("entry [0x%llx,0x%llx) 的 GWorld=0x%llx 但 +0x%x 处 0x%llx 不是有效指针，跳过",
                   (unsigned long long)list[i].start,
                   (unsigned long long)list[i].end,
                   (unsigned long long)gwv, O_SELF2, (unsigned long long)hop1);
            continue;
        }
        gGameBase = list[i].start;
        PE_LOG("base=0x%llx（entry [0x%llx,0x%llx) size=%lluKB；GWorld=0x%llx +0x%x=0x%llx 双重校验通过）",
               (unsigned long long)gGameBase,
               (unsigned long long)list[i].start,
               (unsigned long long)list[i].end,
               (unsigned long long)(list[i].size >> 10),
               (unsigned long long)gwv, O_SELF2, (unsigned long long)hop1);
        found = true;
    }
    free(cand);
    if (found) return true;

    if (m > 0) {
        PE_LOG_ERROR("所有 Mach-O 条目的 base+O_GWORLD=0x%x 处均无有效 GWorld 指针——"
                     "偏移可能与游戏版本不匹配（或主映像不在窗口内），请把上方条目布局日志发回分析",
                     O_GWORLD);
        pe_detail([NSString stringWithFormat:
            @"base+O_GWORLD（0x%x）处无有效 GWorld 指针，偏移或基址候选有误（详见控制台日志）", O_GWORLD]);
    } else {
        PE_LOG_ERROR("窗口内 %d 个条目均未命中 Mach-O 头，请把控制台日志发回分析", n);
        pe_detail(@"未在游戏 vm_map 条目中找到 Mach-O 主映像（详见控制台日志）");
    }
    return false;
}

static bool pe_init_game(void)
{
    pe_detect_page_size();
    PE_LOG("内核基址=0x%llx VM_MIN_KERNEL_ADDRESS=0x%llx VM_MAX_KERNEL_ADDRESS=0x%llx",
           (unsigned long long)ds_get_kernel_base(),
           (unsigned long long)VM_MIN_KERNEL_ADDRESS,
           (unsigned long long)VM_MAX_KERNEL_ADDRESS);

    uint64_t proc = procbyname(PE_GAME_PROCESS);
    if (!proc) {
        PE_LOG_ERROR("procbyname 未找到 %{public}s", PE_GAME_PROCESS);
        pe_detail(@"procbyname 未找到游戏进程 ShadowTrackerExtra");
        return false;
    }
    PE_LOG("proc=0x%llx", (unsigned long long)proc);
    uint64_t task = proc_task(proc);
    if (!task) {
        PE_LOG_ERROR("proc_task 取不到 task（proc=0x%llx）", (unsigned long long)proc);
        pe_detail([NSString stringWithFormat:@"proc_task 取不到 task（proc=0x%llx）",
                   (unsigned long long)proc]);
        return false;
    }

    // vm_map：DarkSword offsets（off_task_map，随内核版本解析）
    gGameVMMap = task_get_vm_map(task);
    if (!ds_isvalid(gGameVMMap)) {
        PE_LOG_ERROR("task_get_vm_map 取不到 vm_map（task=0x%llx off_task_map=0x%x）",
                     (unsigned long long)task, off_task_map);
        pe_detail([NSString stringWithFormat:@"task_get_vm_map 取不到 vm_map（task=0x%llx）",
                   (unsigned long long)task]);
        return false;
    }
    PE_LOG("vm_map=0x%llx (off_task_map=0x%x)",
           (unsigned long long)gGameVMMap, off_task_map);

    pe_page_cache_flush();
    gFailMyinfo = 0; gFailVp = 0; gFailActors = 0;
    if (!pe_find_game_base()) return false;

    uint64_t gworld = kread64(gGameBase + O_GWORLD);
    PE_LOG("GWorld=0x%llx", (unsigned long long)gworld);
    gGameOK = (gworld > 0x100000000ULL && gworld < 0x800000000ULL);
    if (!gGameOK) {
        PE_LOG_ERROR("GWorld=0x%llx 不在预期范围，ESP 可能无数据——游戏版本偏移可能需要更新",
                     (unsigned long long)gworld);
    }
    return true;
}

static uint64_t gw(void) { return gGameOK ? kread64(gGameBase + O_GWORLD) : 0; }

// ---- 帧循环环节诊断 ----
static bool pe_myinfo(void) {
    uint64_t g = gw(); if (!g) return false;
    // 自身链：GWorld → +0xC0 → +0x88 → +0x30（PlayerController）→ +0x3540（Pawn）
    uint64_t a   = kread64(g + O_SELF2);
    uint64_t b   = a ? kread64(a + O_SELF3) : 0;
    uint64_t pc  = b ? kread64(b + O_SELF4) : 0;
    uint64_t pawn = pc ? kread64(pc + O_SELF5) : 0;
    if (!pawn || pawn < 0x100000000ULL || pawn >= 0x800000000ULL) {
        if (gFailMyinfo < 3) {
            PE_LOG_ERROR("自身链断链：GWorld=0x%llx +0x%x→0x%llx +0x%x→0x%llx +0x%x→0x%llx +0x%x→0x%llx",
                         (unsigned long long)g, O_SELF2, (unsigned long long)a,
                         O_SELF3, (unsigned long long)b,
                         O_SELF4, (unsigned long long)pc,
                         O_SELF5, (unsigned long long)pawn);
            gFailMyinfo++;
        }
        return false;
    }
    gMyTeam = (int)kread32(pawn + O_TEAM);
    uint64_t rc = kread64(pawn + O_ROOTCOMP);
    if (!rc || rc < 0x100000000ULL || rc >= 0x800000000ULL) {
        if (gFailMyinfo < 3) {
            PE_LOG_ERROR("坐标指针无效：pawn=0x%llx +0x%x→0x%llx",
                         (unsigned long long)pawn, O_ROOTCOMP, (unsigned long long)rc);
            gFailMyinfo++;
        }
        return false;
    }
    if (!kreadbuf(rc + O_LOC, &gMyPos, sizeof(gMyPos))) {
        if (gFailMyinfo < 3) {
            PE_LOG_ERROR("自身坐标读取失败：RootComp=0x%llx +0x%x（O_LOC 可能过期）",
                         (unsigned long long)rc, O_LOC);
            gFailMyinfo++;
        }
        return false;
    }
    gFailMyinfo = 0;
    return true;
}

// 相机 POV（安卓表：Fov1 0x60C8 / Fov2 0x680 / Fov3[+0x40] 0x640）
// 链：GWorld → 0xC0 → 0x88 → 0x30（PC）→ +0x680（相机）→ +0x640（Cache 条目）
// POV（FMinimalViewInfo）落在 Cache+0x28：Location +0x28，Rotation +0x34，FOV +0x40
typedef struct {
    PE_Vec3 loc;   // 相机位置
    PE_Vec3 rot;   // 旋转（Pitch / Yaw / Roll，度）
    float   fov;   // FOV（度）
} PECamera;

static bool pe_vp(PECamera *cam) {
    uint64_t g = gw(); if (!g) return false;
    // 相机链（按安卓表）：
    //   GWorld +0xC0 → +0x88 → +0x30（三级对象）→ +0x3540（自身 Pawn）
    //   Pawn +0x60C8（玩家控制器，见“掩体判断”区）→ +0x680（相机）→ +0x640（Cache 条目）
    //   POV 落在 Cache+0x28：Location/Rotation/FOV（FOV 正好落在 +0x40，与表 Fov3[+0x40] 吻合）
    uint64_t a    = kread64(g + O_SELF2);
    uint64_t b    = a ? kread64(a + O_SELF3) : 0;
    uint64_t c    = b ? kread64(b + O_SELF4) : 0;
    uint64_t pawn = c ? kread64(c + O_SELF5) : 0;
    uint64_t pc   = pawn ? kread64(pawn + O_PC_FROM_PAWN) : 0;
    uint64_t camPtr = pc ? kread64(pc + O_CAMPTR) : 0;
    if (!camPtr || camPtr < 0x100000000ULL || camPtr >= 0x800000000ULL) {
        if (gFailVp < 3) {
            PE_LOG_ERROR("相机链断链：GWorld=0x%llx +0x%x→0x%llx +0x%x→0x%llx +0x%x→0x%llx "
                         "+0x%x(Pawn)→0x%llx +0x%x(PC)→0x%llx +0x%x(相机)→0x%llx",
                         (unsigned long long)g, O_SELF2, (unsigned long long)a,
                         O_SELF3, (unsigned long long)b,
                         O_SELF4, (unsigned long long)c,
                         O_SELF5, (unsigned long long)pawn,
                         O_PC_FROM_PAWN, (unsigned long long)pc,
                         O_CAMPTR, (unsigned long long)camPtr);
            gFailVp++;
        }
        return false;
    }
    // POV 内嵌在相机对象 +0x640（表：Fov3[+0x40] 0x0640——FOV 在该结构 +0x40）。
    // 之前把它当指针解引用读到 0x4104b96f/0x403462e3，按 float 正是 8.14/3.05
    // ——UE4 FCameraCacheEntry.TimeStamp（秒），证实结构是内嵌的：
    //   +0x00 TimeStamp(float)  +0x28 Location  +0x34 Rotation  +0x40 FOV
    uint64_t povBase = camPtr + O_CAMCACHE;
    // POV：+0x28 Location / +0x34 Rotation / +0x40 FOV，一次读完（0x28+0x1C = 68 字节）
    unsigned char buf[68];
    if (!kreadbuf(povBase + 0x28, buf, sizeof(buf))) {
        if (gFailVp < 3) {
            PE_LOG_ERROR("POV 读取失败：相机=0x%llx +0x%x +0x28（POV 布局可能不符）",
                         (unsigned long long)camPtr, O_CAMCACHE);
            gFailVp++;
        }
        return false;
    }
    memcpy(&cam->loc, buf, 12);        // +0x28
    memcpy(&cam->rot, buf + 0xC, 12);  // +0x34
    memcpy(&cam->fov, buf + 0x18, 4);  // +0x40
    // 合理性校验：FOV 10..170，位置在用户态量级
    if (cam->fov < 10.0f || cam->fov > 170.0f ||
        fabsf(cam->loc.x) > 1e7f || fabsf(cam->loc.y) > 1e7f || fabsf(cam->loc.z) > 1e7f) {
        if (gFailVp < 3) {
            PE_LOG_ERROR("POV 数据可疑：相机=0x%llx loc=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) fov=%.1f"
                         "（把此日志发回分析）",
                         (unsigned long long)camPtr,
                         cam->loc.x, cam->loc.y, cam->loc.z,
                         cam->rot.x, cam->rot.y, cam->rot.z, cam->fov);
            gFailVp++;
        }
        return false;
    }
    if (gFailVp == 0) { // 首次成功打一遍，便于核对
        PE_LOG("相机就绪：loc=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) fov=%.1f",
               cam->loc.x, cam->loc.y, cam->loc.z,
               cam->rot.x, cam->rot.y, cam->rot.z, cam->fov);
        gFailVp = 1; // 防重复打印（0 是“未打印”哨兵）
    }
    return true;
}

// 玩家名字（0xAF8，FString：指针 → UTF-16 缓冲）
static NSString *pe_actor_name(uint64_t a) {
    uint64_t fstr = kread64(a + O_NAME);
    if (fstr < 0x100000000ULL || fstr >= 0x800000000ULL) return nil;
    uint16_t buf[24];
    if (!kreadbuf(fstr, buf, sizeof(buf))) return nil;
    int len = 0;
    while (len < 24 && buf[len] != 0) len++;
    if (len == 0 || len >= 24) return nil; // 空串或未终止（可疑）
    if (len > 16) len = 16; // 显示上限
    return [[NSString alloc] initWithBytes:buf length:(NSUInteger)len * 2
                                  encoding:NSUTF16LittleEndianStringEncoding];
}

static int pe_actors(PE_Enemy *out, int max) {
    uint64_t g = gw(); if (!g) return 0;
    uint64_t lv = kread64(g + O_PERSISTLEVEL);
    if (!lv || lv < 0x100000000ULL || lv >= 0x800000000ULL) {
        if (gFailActors < 3) {
            PE_LOG_ERROR("PersistentLevel 无效：GWorld=0x%llx +0x%x→0x%llx（偏移可能过期）",
                         (unsigned long long)g, O_PERSISTLEVEL, (unsigned long long)lv);
            gFailActors++;
        }
        return 0;
    }
    uint64_t arr = kread64(lv + O_ACTORS);
    int cnt = (int)kread32(lv + O_ACTORCNT);
    if (!arr || arr < 0x100000000ULL || arr >= 0x800000000ULL || cnt <= 0 || cnt > 2000) {
        if (gFailActors < 3) {
            PE_LOG_ERROR("Actor 数组无效：Level=0x%llx +0x%x→0x%llx cnt(+0x%x)=%d（偏移可能过期）",
                         (unsigned long long)lv, O_ACTORS, (unsigned long long)arr,
                         O_ACTORCNT, cnt);
            gFailActors++;
        }
        return 0;
    }
    int w = 0;
    for (int i = 0; i < cnt && w < max; i++) {
        uint64_t a = kread64(arr + (uint64_t)i * 8); if (!a) continue;
        if ((int)kread32(a + O_TEAM) == gMyTeam && gMyTeam != -1) continue;
        float hp; uint32_t hr = kread32(a + O_HP); memcpy(&hp, &hr, 4); if (hp <= 0) continue;
        uint64_t rc = kread64(a + O_ROOTCOMP); if (!rc) continue;
        PE_Vec3 loc; if (!kreadbuf(rc + O_LOC, &loc, sizeof(loc))) continue;
        float dx = loc.x - gMyPos.x, dy = loc.y - gMyPos.y, dz = loc.z - gMyPos.z;
        float dist = sqrtf(dx * dx + dy * dy + dz * dz); if (dist > PE_FAR_CLIP) continue;
        PE_Enemy *e = &out[w];
        e->location = loc; e->distance = dist;
        float hmax; uint32_t hmr = kread32(a + O_HPMAX); memcpy(&hmax, &hmr, 4);
        e->health = hp; e->healthMax = (hmax > 0 && hmax < 10000) ? hmax : 100;
        e->isAI = (kread32(a + O_AI) & 0xFF) != 0; e->isDead = false;
        e->teamID = (int)kread32(a + O_TEAM);
        e->name = pe_actor_name(a);
        e->bottom = loc; e->top = loc; e->top.z += PE_PLAYER_HEIGHT;
        w++;
    }
    return w;
}

// ============================================================
// 第 2 层：WorldToScreen
// ============================================================

// WorldToScreen：UE4 旋转（度）+ FOV 投影
// forward=(cp·cy, cp·sy, sp)，right=(sy,−cy,0)，up=right×forward（Roll 忽略，一般为 0）
static PE_Vec2S w2s(PE_Vec3 w, const PECamera *cam, double sw, double sh) {
    PE_Vec2S r = {0, 0, false};
    float pitch = cam->rot.x * (float)M_PI / 180.0f;
    float yaw   = cam->rot.y * (float)M_PI / 180.0f;
    float cp = cosf(pitch), sp = sinf(pitch), cy = cosf(yaw), sy = sinf(yaw);

    float fx = cp * cy, fy = cp * sy, fz = sp;          // forward
    float rx = sy,     ry = -cy,    rz = 0.0f;          // right
    float ux = ry * fz - rz * fy;                       // up = right × forward
    float uy = rz * fx - rx * fz;
    float uz = rx * fy - ry * fx;

    float dx = w.x - cam->loc.x, dy = w.y - cam->loc.y, dz = w.z - cam->loc.z;
    float xf = dx * fx + dy * fy + dz * fz;             // 前向距离
    if (xf < 1.0f) return r;                            // 背后
    float xr = dx * rx + dy * ry + dz * rz;
    float xu = dx * ux + dy * uy + dz * uz;

    float halfTan = tanf(cam->fov * (float)M_PI / 360.0f); // tan(fov/2)
    if (halfTan < 0.01f) return r;
    r.x = (float)(sw * 0.5 + (double)(xr / xf) / halfTan * sw * 0.5);
    r.y = (float)(sh * 0.5 - (double)(xu / xf) / halfTan * sw * 0.5); // 同宽高比
    r.visible = true;
    return r;
}

// ============================================================
// 第 3 层：SpringBoard Overlay
// ============================================================

static void pe_overlay_destroy(void) {
    if (gOverlayWin) {
        pe_set_u64_main(gOverlayWin, "setHidden:", 1);
    }
    for (int i = 0; i < PE_MAX_ENEMIES; i++) {
        if (gBox[i]) {
            pe_call_main_noarg(gBox[i], "removeFromSuperview");
            gBox[i] = 0;
        }
        if (gName[i]) {
            pe_call_main_noarg(gName[i], "removeFromSuperview");
            gName[i] = 0;
        }
        if (gDist[i]) {
            pe_call_main_noarg(gDist[i], "removeFromSuperview");
            gDist[i] = 0;
        }
    }
    gOverlayWin = 0;
    gOverlayReady = false;
}

static bool pe_overlay_create(void) {
    CGRect sb = UIScreen.mainScreen.bounds;
    // 游戏为横屏；本 App 竖屏时 mainScreen.bounds 也是竖屏（428x926），
    // 但游戏画面/相机投影是 926x428——统一按横屏建 Overlay（宽=长边）。
    gSW = MAX(sb.size.width, sb.size.height);
    gSH = MIN(sb.size.width, sb.size.height);
    PE_LOG("screen %dx%d（横屏；原始 bounds=%.0fx%.0f）",
           (int)gSW, (int)gSH, sb.size.width, sb.size.height);

    uint64_t windowClass = pe_class("UIWindow");
    uint64_t viewClass = pe_class("UIView");
    uint64_t labelClass = pe_class("UILabel");
    uint64_t workspaceClass = pe_class("SBMainWorkspace");
    if (!windowClass || !viewClass || !labelClass || !workspaceClass) return false;

    // HUD 所在窗口挂到 SBMainWorkspace.mainWindowScene（DSBridge 验证过的路径）
    uint64_t workspace = pe_get_main(workspaceClass, "sharedInstance");
    uint64_t scene = workspace ? pe_get_main(workspace, "mainWindowScene") : 0;
    if (!scene) {
        PE_LOG_ERROR("SBMainWorkspace.mainWindowScene 为 nil");
        pe_detail(@"SBMainWorkspace.mainWindowScene 为 nil（SpringBoard 场景未就绪）");
        return false;
    }

    uint64_t alloc = pe_sel("alloc");
    uint64_t window = remote_msg(gRC, windowClass, alloc, 0, 0, 0, 0);
    if (!window) {
        PE_LOG_ERROR("UIWindow alloc 失败");
        pe_detail(@"远程 UIWindow alloc 失败");
        return false;
    }
    if (!pe_call_main_noarg(window, "init")) {
        PE_LOG_ERROR("UIWindow init 失败");
        pe_detail(@"远程 UIWindow init 失败");
        return false;
    }
    gOverlayWin = window;

    pe_perform_main(window, pe_sel("setWindowScene:"), scene, YES);
    pe_set_double_main(window, "setWindowLevel:", 999999.0);
    pe_set_u64_main(window, "setUserInteractionEnabled:", 0);

    uint64_t colorClass = pe_class("UIColor");
    uint64_t clearColor = colorClass ? pe_get_main_retained(colorClass, "clearColor", NULL, 0) : 0;
    uint64_t whiteColor = colorClass ? pe_get_main_retained(colorClass, "whiteColor", NULL, 0) : 0;
    uint64_t greenColor = colorClass ? pe_get_main_retained(colorClass, "greenColor", NULL, 0) : 0;
    uint64_t greenCGColor = greenColor ? pe_get_main(greenColor, "CGColor") : 0;
    if (!clearColor || !whiteColor) {
        PE_LOG_ERROR("UIColor clearColor/whiteColor 远程获取失败");
        pe_detail(@"UIColor clearColor/whiteColor 远程获取失败");
        pe_overlay_destroy();
        return false;
    }

    pe_perform_main(window, pe_sel("setBackgroundColor:"), clearColor, YES);
    pe_set_rect_main(window, "setFrame:", CGRectMake(0, 0, gSW, gSH));

    uint64_t fontClass = pe_class("UIFont");
    uint64_t font = 0;
    if (fontClass) {
        double fs = 11.0, wt = 0.0;
        PEArg args[] = { { &fs, sizeof(fs) }, { &wt, sizeof(wt) } };
        font = pe_get_main_retained(fontClass, "systemFontOfSize:weight:", args, 2);
        if (!font) {
            double fsonly = 11.0;
            PEArg a1 = { &fsonly, sizeof(fsonly) };
            font = pe_get_main_retained(fontClass, "systemFontOfSize:", &a1, 1);
        }
    }

    for (int i = 0; i < PE_MAX_ENEMIES; i++) {
        // 方框
        uint64_t box = remote_msg(gRC, viewClass, alloc, 0, 0, 0, 0);
        if (box) {
            pe_call_main_noarg(box, "init");
            pe_perform_main(box, pe_sel("setBackgroundColor:"), clearColor, YES);
            uint64_t layer = pe_get_main(box, "layer");
            if (layer) {
                pe_set_double_main(layer, "setBorderWidth:", 2.0);
                if (greenCGColor) pe_perform_main(layer, pe_sel("setBorderColor:"), greenCGColor, YES);
            }
            pe_set_u64_main(box, "setHidden:", 1);
            pe_perform_main(window, pe_sel("addSubview:"), box, YES);
        }
        gBox[i] = box;

        // 名称 label
        uint64_t name = remote_msg(gRC, labelClass, alloc, 0, 0, 0, 0);
        if (name) {
            pe_call_main_noarg(name, "init");
            pe_set_u64_main(name, "setTextAlignment:", 1);
            pe_set_u64_main(name, "setNumberOfLines:", 1);
            if (font) pe_perform_main(name, pe_sel("setFont:"), font, YES);
            pe_perform_main(name, pe_sel("setTextColor:"), whiteColor, YES);
            pe_perform_main(name, pe_sel("setBackgroundColor:"), clearColor, YES);
            pe_set_u64_main(name, "setHidden:", 1);
            pe_perform_main(window, pe_sel("addSubview:"), name, YES);
        }
        gName[i] = name;

        // 距离 label
        uint64_t dist = remote_msg(gRC, labelClass, alloc, 0, 0, 0, 0);
        if (dist) {
            pe_call_main_noarg(dist, "init");
            pe_set_u64_main(dist, "setTextAlignment:", 1);
            pe_set_u64_main(dist, "setNumberOfLines:", 1);
            if (font) pe_perform_main(dist, pe_sel("setFont:"), font, YES);
            pe_perform_main(dist, pe_sel("setTextColor:"), whiteColor, YES);
            pe_perform_main(dist, pe_sel("setBackgroundColor:"), clearColor, YES);
            pe_set_u64_main(dist, "setHidden:", 1);
            pe_perform_main(window, pe_sel("addSubview:"), dist, YES);
        }
        gDist[i] = dist;
    }

    pe_set_u64_main(window, "setHidden:", 0);
    PE_LOG("overlay %dx%d %d slots", (int)gSW, (int)gSH, PE_MAX_ENEMIES);
    gOverlayReady = true;
    return true;
}

// ============================================================
// 第 4 层：更新 views
// ============================================================

static void pe_box(int i, PE_Rect r, bool v) {
    if (i < 0 || i >= PE_MAX_ENEMIES) return;
    uint64_t bx = gBox[i]; if (!bx) return;
    if (!v) { pe_set_u64_main(bx, "setHidden:", 1); return; }
    pe_set_rect_main(bx, "setFrame:", CGRectMake(r.x, r.y, r.width, r.height));
    pe_set_double_main(bx, "setAlpha:", 0.85);
    pe_set_u64_main(bx, "setHidden:", 0);
}

static void pe_lbl(uint64_t lb, NSString *text, PE_Rect r, bool v) {
    if (!lb) return;
    if (!v || !text) { pe_set_u64_main(lb, "setHidden:", 1); return; }
    uint64_t ns = pe_nsstring(text);
    if (ns) {
        pe_perform_main(lb, pe_sel("setText:"), ns, YES);
        uint64_t release = pe_sel("release");
        if (release && gRC.trojanMem) remote_msg(gRC, ns, release, 0, 0, 0, 0);
        pe_set_rect_main(lb, "setFrame:", CGRectMake(r.x, r.y, r.width, r.height));
        pe_set_u64_main(lb, "setHidden:", 0);
    } else {
        pe_set_u64_main(lb, "setHidden:", 1);
    }
}

// ============================================================
// 第 5 层：帧
// ============================================================

static int gFlushCounter = 0;

static void peace_esp_tick(void) {
    if (!gOverlayReady || !gRun || !gGameOK) return;

    // 周期回收远程页缓存：防游戏换图/重映射后读到陈旧对象（对象被我们
    // 引用计数保活，内容不再更新）。约 5 秒一次，重建代价一次性的。
    if (++gFlushCounter >= 150) {
        gFlushCounter = 0;
        pe_page_cache_flush();
    }

    if (!pe_myinfo()) return;
    PECamera cam; if (!pe_vp(&cam)) return;

    PE_Enemy es[PE_MAX_ENEMIES];
    for (int i = 0; i < PE_MAX_ENEMIES; i++) es[i].name = nil;
    int n = pe_actors(es, PE_MAX_ENEMIES);
    static int sLoggedCount = 0; // 首帧打一次敌人数，便于确认 Actor 列表是否可用
    if (sLoggedCount < 3) {
        PE_LOG("帧数据：敌人数=%d（0 且无报错 = Actor 过滤全灭，坐标/血量偏移可疑）", n);
        sLoggedCount++;
    }
    int vi = 0;
    PE_Rect zeroRect = {0, 0, 0, 0};
    for (int i = 0; i < n && vi < PE_MAX_ENEMIES; i++) {
        PE_Enemy *e = &es[i];
        PE_Vec2S tp = w2s(e->top, &cam, gSW, gSH);
        PE_Vec2S bt = w2s(e->bottom, &cam, gSW, gSH);
        if (!tp.visible || !bt.visible) continue;
        float h = (float)fabs(bt.y - tp.y), w = h * 0.4f, x = tp.x - w * 0.5f, y = tp.y;
        if (x + w < 0 || x > gSW || y + h < 0 || y > gSH) continue;
        PE_Rect boxRect = {x, y, (double)w, (double)h};
        pe_box(vi, boxRect, true);
        PE_Rect nameRect = {x - 10, y - 18, (double)w + 20, 16};
        pe_lbl(gName[vi], (e->name.length > 0 ? e->name : (e->isAI ? @"BOT" : @"Player")), nameRect, true);
        char ds[32];
        snprintf(ds, sizeof(ds), "%.0fm", e->distance / 100.0f);
        PE_Rect distRect = {x - 10, (double)y + h + 2, (double)w + 20, 16};
        pe_lbl(gDist[vi], [NSString stringWithUTF8String:ds], distRect, true);
        vi++;
    }
    for (int i = vi; i < PE_MAX_ENEMIES; i++) {
        pe_box(i, zeroRect, false);
        pe_lbl(gName[i], nil, zeroRect, false);
        pe_lbl(gDist[i], nil, zeroRect, false);
    }
    gVis = vi;
    gFrames++;
}

// ============================================================
// 生命周期
// ============================================================

static NSString *gLastError = @"";
static volatile bool gThreadDone = true;

static void pe_fail(NSString *message) {
    NSString *full = gLastErrorDetail.length > 0
        ? [NSString stringWithFormat:@"%@ 原因：%@", message, gLastErrorDetail]
        : message;
    gLastError = [full copy];
    PE_LOG_ERROR("%{public}@", full);
    gThreadDone = true;
}

void PeaceESPStart(void) {
    if (gRun) return;
    // 等待上一次停止流程收尾（最多 ~2s）
    for (int i = 0; i < 200 && !gThreadDone; i++) usleep(10000);
    if (!gThreadDone) return;

    gLastError = @"";
    gLastErrorDetail = @"";
    gFrames = 0; gVis = 0;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (!ReinKernelIsReady()) { pe_fail(@"请先初始化 DarkSword 内核，再启动 ESP。"); return; }
            if (!ReinRemoteCallIsReady()) { pe_fail(@"请先初始化 RemoteCall，再启动 ESP。"); return; }
            gRC = ReinBridgeRemoteCall();
            if (!gRC || !gRC.trojanMem) { pe_fail(@"RemoteCall 会话不可用，请重新初始化。"); return; }

            if (!proc_find_by_name(PE_GAME_PROCESS)) {
                pe_fail(@"未找到游戏进程 ShadowTrackerExtra，请先进入游戏。");
                return;
            }

            PE_LOG("=== start (4KB/16KB adaptive) ===（Console.app 过滤 subsystem: com.rein.peaceesp）");
            if (!pe_init_game()) {
                pe_fail(@"游戏初始化失败（vm_map / 基址扫描），详细日志见 Console.app（subsystem: com.rein.peaceesp）。");
                return;
            }

            if (!pe_overlay_create()) {
                pe_fail(@"SpringBoard Overlay 创建失败，详细日志见 Console.app（subsystem: com.rein.peaceesp）。");
                return;
            }

            gRun = true;
            gThreadDone = false;
            PE_LOG("running");
            while (gRun && gOverlayReady) {
                @autoreleasepool {
                    peace_esp_tick();
                }
                usleep((useconds_t)(PE_DEFAULT_INTERVAL * 1000000.0));
            }
            pe_overlay_destroy();
            pe_page_cache_flush();
            gGameVMMap = 0;
            gRun = false;
            gThreadDone = true;
            PE_LOG("loop exit");
        }
    });
}

void PeaceESPStop(void) {
    gRun = false;
    // 等帧循环退出并移除 Overlay（最多 ~2s）
    for (int i = 0; i < 200 && !gThreadDone; i++) usleep(10000);
}

BOOL PeaceESPIsRunning(void) {
    return gRun && gOverlayReady;
}

NSString *PeaceESPLastError(void) {
    return gLastError ?: @"";
}
