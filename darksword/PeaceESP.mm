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
    return sh.localPage;
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
// 偏移（需随游戏版本更新）
// ============================================================

enum {
    O_GWORLD = 0xF1CD938, O_PERSISTLEVEL = 0xB0, O_ACTORS = 0xA0, O_ACTORCNT = 0xA8,
    O_NETDRIVER = 0xB8, O_SERVCONN = 0x88, O_LOCALPC = 0x30, O_PAWN = 0x3438,
    O_CAMMGR = 0x658, O_CAMCACHE = 0x640, O_POV = 0x13A0,
    O_ROOTCOMP = 0x268, O_LOC = 0x200, O_HP = 0xFD8, O_BDEAD = 0x1058,
    O_TEAM = 0xB68, O_AI = 0xB84,
};

// ============================================================
// 第 1 层：游戏内存
// ============================================================

// 遍历游戏 vm_map 条目定位主映像基址：
// 在 [0x100000000, 0x800000000) 窗口内（共享缓存之下的 app 映像区），
// 优先检查大段（≥16MB，UE4 主映像 __TEXT 量级）的首页 Mach-O magic。
static bool pe_find_game_base(void)
{
    struct { uint64_t start, end; } cand[24];
    __block int n = 0;
    vmmapiterateentries(gGameVMMap, ^(uint64_t start, uint64_t end,
                                      uint64_t entry, BOOL *stop) {
        if (n >= 24) { *stop = YES; return; }
        if (start < 0x100000000ULL || start >= 0x800000000ULL) return;
        if (end - start < 0x4000ULL) return;
        cand[n].start = start;
        cand[n].end = end;
        n++;
    });
    PE_LOG("vm_map 窗口内候选条目 %d 个", n);

    for (int pass = 0; pass < 2 && !gGameBase; pass++) {
        uint64_t minSize = (pass == 0) ? 0x1000000ULL : 0x4000ULL;
        for (int i = 0; i < n; i++) {
            if (cand[i].end - cand[i].start < minSize) continue;
            uint32_t magic = 0;
            if (!kreadbuf(cand[i].start, &magic, sizeof(magic))) continue;
            if (magic == 0xFEEDFACF || magic == 0xCFFAEDFE) {
                gGameBase = cand[i].start;
                PE_LOG("base=0x%llx（条目 #%d 区间 [0x%llx,0x%llx) 首页命中 Mach-O）",
                       (unsigned long long)gGameBase, i,
                       (unsigned long long)cand[i].start,
                       (unsigned long long)cand[i].end);
                return true;
            }
        }
    }

    PE_LOG_ERROR("窗口内 %d 个条目均未命中 Mach-O 头，请把控制台日志发回分析", n);
    pe_detail(@"未在游戏 vm_map 条目中找到 Mach-O 主映像（详见控制台日志）");
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

static uint64_t chain(uint64_t base, const uint64_t *offs, int n) {
    uint64_t a = base;
    for (int i = 0; i < n; i++) {
        if (!a) return 0;
        a = kread64(a + offs[i]);
    }
    return a;
}

static bool pe_myinfo(void) {
    uint64_t g = gw(); if (!g) return false;
    uint64_t ch[] = {O_NETDRIVER, O_SERVCONN, O_LOCALPC};
    uint64_t pc = chain(g, ch, 3); if (!pc) return false;
    gMyTeam = (int)kread32(pc + O_TEAM);
    uint64_t pawn = kread64(pc + O_PAWN); if (!pawn) return false;
    uint64_t rc = kread64(pawn + O_ROOTCOMP); if (!rc) return false;
    return kreadbuf(rc + O_LOC, &gMyPos, sizeof(gMyPos));
}

static bool pe_vp(float out[16]) {
    uint64_t g = gw(); if (!g) return false;
    uint64_t ch[] = {O_NETDRIVER, O_SERVCONN, O_LOCALPC, O_CAMMGR, O_CAMCACHE};
    uint64_t c = chain(g, ch, 5); if (!c) return false;
    uint64_t pov = c + O_POV;
    if (!kreadbuf(pov + 0x1A0, out, 64)) return false;
    if (out[12] == 0 && out[13] == 0 && out[14] == 0 && out[15] == 0) return false;
    return true;
}

static int pe_actors(PE_Enemy *out, int max) {
    uint64_t g = gw(); if (!g) return 0;
    uint64_t lv = kread64(g + O_PERSISTLEVEL); if (!lv) return 0;
    uint64_t arr = kread64(lv + O_ACTORS);
    int cnt = (int)kread32(lv + O_ACTORCNT);
    if (!arr || cnt <= 0 || cnt > 2000) return 0;
    int w = 0;
    for (int i = 0; i < cnt && w < max; i++) {
        uint64_t a = kread64(arr + (uint64_t)i * 8); if (!a) continue;
        if ((int)kread32(a + O_TEAM) == gMyTeam && gMyTeam != -1) continue;
        if (kread32(a + O_BDEAD) & 0xFF) continue;
        uint64_t rc = kread64(a + O_ROOTCOMP); if (!rc) continue;
        PE_Vec3 loc; if (!kreadbuf(rc + O_LOC, &loc, sizeof(loc))) continue;
        float hp; uint32_t hr = kread32(a + O_HP); memcpy(&hp, &hr, 4); if (hp <= 0) continue;
        float dx = loc.x - gMyPos.x, dy = loc.y - gMyPos.y, dz = loc.z - gMyPos.z;
        float dist = sqrtf(dx * dx + dy * dy + dz * dz); if (dist > PE_FAR_CLIP) continue;
        PE_Enemy *e = &out[w];
        e->location = loc; e->health = hp; e->healthMax = 100; e->distance = dist;
        e->isAI = (kread32(a + O_AI) & 0xFF) != 0; e->isDead = false;
        e->teamID = (int)kread32(a + O_TEAM);
        e->bottom = loc; e->top = loc; e->top.z += PE_PLAYER_HEIGHT;
        w++;
    }
    return w;
}

// ============================================================
// 第 2 层：WorldToScreen
// ============================================================

static PE_Vec2S w2s(PE_Vec3 w, const float vp[16], double sw, double sh) {
    PE_Vec2S r = {0, 0, false};
    float w4 = vp[3] * w.x + vp[7] * w.y + vp[11] * w.z + vp[15];
    if (w4 < 0.01f) return r;
    r.x = (float)((vp[0] * w.x + vp[4] * w.y + vp[8] * w.z + vp[12]) / w4 * 0.5 + 0.5) * (float)sw;
    r.y = (float)(1.0 - (vp[1] * w.x + vp[5] * w.y + vp[9] * w.z + vp[13]) / w4 * 0.5) * (float)sh;
    r.visible = true; return r;
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
    gSW = sb.size.width; gSH = sb.size.height;
    PE_LOG("screen %dx%d", (int)gSW, (int)gSH);

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
    float vp[16]; if (!pe_vp(vp)) return;

    PE_Enemy es[PE_MAX_ENEMIES];
    int n = pe_actors(es, PE_MAX_ENEMIES);
    int vi = 0;
    PE_Rect zeroRect = {0, 0, 0, 0};
    for (int i = 0; i < n && vi < PE_MAX_ENEMIES; i++) {
        PE_Enemy *e = &es[i];
        PE_Vec2S tp = w2s(e->top, vp, gSW, gSH);
        PE_Vec2S bt = w2s(e->bottom, vp, gSW, gSH);
        if (!tp.visible || !bt.visible) continue;
        float h = (float)fabs(bt.y - tp.y), w = h * 0.4f, x = tp.x - w * 0.5f, y = tp.y;
        if (x + w < 0 || x > gSW || y + h < 0 || y > gSH) continue;
        PE_Rect boxRect = {x, y, (double)w, (double)h};
        pe_box(vi, boxRect, true);
        PE_Rect nameRect = {x - 10, y - 18, (double)w + 20, 16};
        pe_lbl(gName[vi], (e->isAI ? @"BOT" : @"Player"), nameRect, true);
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
