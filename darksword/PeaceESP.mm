//
//  PeaceESP.mm
//  Rein
//
//  v6-safe：自适应 4KB/16KB 页面；PA→KVA 一律经内核官方 ptov_table 换算
//  （由 libxpf 从 kernelcache 解析符号，读取仅触及内核 data 段，安全），
//  绝不探测任意 KVA——探测会触发 copy_validate_kernel_addr 内核 panic。
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
#import "xpf.h"
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

// %{public} 仅供 os_log 使用，镜像前剔除以保证 NSString 格式化安全
static NSString *pe_console_fmt(NSString *fmt) {
    return [fmt stringByReplacingOccurrencesOfString:@"%{public}" withString:@""];
}

// PE_LOG：os_log（Console.app 可见）+ 镜像到 ReinBridge 内存日志（App 内查看器可见）
#define PE_LOG(fmt, ...) \
    do { \
        os_log(pe_log_handle(), "[PE] " fmt, ##__VA_ARGS__); \
        ReinAppendConsoleLog([NSString \
            stringWithFormat:pe_console_fmt(@"[PE] " fmt), ##__VA_ARGS__]); \
    } while (0)

#define PE_LOG_ERROR(fmt, ...) \
    do { \
        os_log_error(pe_log_handle(), "[PE] " fmt, ##__VA_ARGS__); \
        ReinAppendConsoleLog([NSString \
            stringWithFormat:pe_console_fmt(@"[PE] " fmt), ##__VA_ARGS__]); \
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

// XNU ptov_table：32 条目，每条覆盖 64GB 物理地址段（PTOV_SHIFT = 36）
#define PE_PTOV_SIZE  32
#define PE_PTOV_SHIFT 36

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
// 内核内存读取基础设施（ptov_table + 页表）
// ============================================================

static uint64_t gGameTTBR0 = 0;          // 游戏进程页表基址（PA）
static int      gPageShift = 0;          // 12=4KB, 14=16KB
static uint64_t gPtovTable[PE_PTOV_SIZE]; // XNU ptov_table 缓存
static bool     gPtovReady = false;

// ---- PA → KVA：只经内核官方 ptov_table 换算，无映射即失败 ----
// 绝不探测任意内核地址：ds_kread 对非法 KVA 会触发
// copy_validate_kernel_addr 内核 panic（真机已验证）。
static uint64_t pe_pa_to_kva(uint64_t pa) {
    if (!gPtovReady) return 0;
    uint64_t idx = (pa >> PE_PTOV_SHIFT) & (PE_PTOV_SIZE - 1);
    uint64_t off = gPtovTable[idx];
    if (!off) return 0; // 该物理段无 physmap 映射
    uint64_t kva = off + pa;
    if (!ds_isvalid(kva)) return 0;
    // offsets 机制解析出的内核 VA 布局边界（xpf "translation" set）
    if (VM_MIN_KERNEL_ADDRESS != 0 && kva < VM_MIN_KERNEL_ADDRESS) return 0;
    if (VM_MAX_KERNEL_ADDRESS != 0 && kva > VM_MAX_KERNEL_ADDRESS) return 0;
    return kva;
}

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

// ---- 解析 ptov_table 符号并缓存映射表 ----
// 符号经 libxpf 从 Documents/kernelcache 解析（只解析不运行），
// 表本体位于内核 __data 段，ds_kread 读取安全。
static bool pe_init_ptov(void)
{
    if (gPtovReady) return true;

    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *kc = docs.length ? [docs stringByAppendingPathComponent:@"kernelcache"] : nil;
    if (!kc || ![[NSFileManager defaultManager] fileExistsAtPath:kc]) {
        PE_LOG_ERROR("kernelcache 不存在（path=%{public}@），无法解析 ptov_table", kc);
        pe_detail(@"Documents 下未找到 kernelcache（请先在「内核」页初始化 DarkSword 内核）");
        return false;
    }

    if (xpf_start_with_kernel_path(kc.UTF8String) != 0) {
        const char *err = xpf_get_error();
        PE_LOG_ERROR("xpf start 失败: %{public}s", err ? err : "(null)");
        pe_detail([NSString stringWithFormat:@"xpf 解析 kernelcache 失败：%s",
                   err ? err : "unknown"]);
        return false;
    }
    uint64_t sym = xpf_item_resolve("kernelSymbol.ptov_table");
    uint64_t fileBase = gXPF.kernelBase;
    xpf_stop();

    if (!sym || !fileBase || sym < fileBase) {
        PE_LOG_ERROR("ptov_table 符号解析失败（sym=0x%llx fileBase=0x%llx）",
                     (unsigned long long)sym, (unsigned long long)fileBase);
        pe_detail([NSString stringWithFormat:@"ptov_table 符号解析失败（sym=0x%llx fileBase=0x%llx）",
                   (unsigned long long)sym, (unsigned long long)fileBase]);
        return false;
    }

    uint64_t runtime = sym - fileBase + ds_get_kernel_base();
    PE_LOG("ptov_table: sym=0x%llx runtime=0x%llx",
           (unsigned long long)sym, (unsigned long long)runtime);

    uint64_t table[PE_PTOV_SIZE];
    memset(table, 0, sizeof(table));
    ds_kread(runtime, table, sizeof(table));

    int valid = 0;
    for (int i = 0; i < PE_PTOV_SIZE; i++) {
        gPtovTable[i] = table[i];
        if (table[i]) valid++;
    }
    if (valid == 0) {
        PE_LOG_ERROR("ptov_table 全零（runtime=0x%llx），无法建立 PA→KVA 映射",
                     (unsigned long long)runtime);
        pe_detail(@"ptov_table 读取结果全零，无法建立 PA→KVA 映射");
        return false;
    }

    gPtovReady = true;
    PE_LOG("ptov_table 就绪（%d 个映射段）", valid);
    for (int i = 0; i < PE_PTOV_SIZE; i++) {
        if (gPtovTable[i]) {
            PE_LOG("  seg[%d] off=0x%llx → VA base=0x%llx",
                   i, (unsigned long long)gPtovTable[i],
                   (unsigned long long)(gPtovTable[i] + ((uint64_t)i << PE_PTOV_SHIFT)));
        }
    }
    return true;
}

// ---- 游戏 pmap → TTBR0 ----
static bool pe_init_game_pmap(void)
{
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

    uint64_t vmmap = 0;
    for (int off = 0x10; off <= 0x40; off += 8) {
        uint64_t val = ds_kread64(task + off);
        if (val > 0xFFFFFFF000000000ULL && val < 0xFFFFFFFFFFFFFFFFULL) {
            vmmap = val;
            PE_LOG("vm_map=0x%llx (task+0x%x)", (unsigned long long)vmmap, off);
            break;
        }
    }
    if (!vmmap) {
        PE_LOG_ERROR("task+0x10..0x40 未扫描到 vm_map（task=0x%llx）",
                     (unsigned long long)task);
        pe_detail([NSString stringWithFormat:@"task+0x10..0x40 未扫描到 vm_map（task=0x%llx）",
                   (unsigned long long)task]);
        return false;
    }

    uint64_t pmap = 0;
    for (int off = 0; off < 0x80; off += 8) {
        uint64_t val = ds_kread64(vmmap + off);
        if (val > 0xFFFFFFF000000000ULL && val < 0xFFFFFFFFFFFFFFFFULL && val != vmmap) {
            uint64_t vfy = ds_kread64(val);
            if (vfy != 0 && vfy != 0xFFFFFFFFFFFFFFFFULL) {
                pmap = val;
                PE_LOG("pmap=0x%llx (vmmap+0x%x)", (unsigned long long)pmap, off);
                break;
            }
        }
    }
    if (!pmap) {
        PE_LOG_ERROR("vm_map+0x10..0x78 未扫描到 pmap（vm_map=0x%llx）",
                     (unsigned long long)vmmap);
        pe_detail([NSString stringWithFormat:@"vm_map+0x10..0x78 未扫描到 pmap（vm_map=0x%llx）",
                   (unsigned long long)vmmap]);
        return false;
    }

    for (int off = 0; off < 0x40; off += 8) {
        uint64_t val = ds_kread64(pmap + off);
        if (val > 0x100000000ULL && val < 0x1000000000ULL && (val & 0xFFF) == 0) {
            // 候选 TTBR0（PA）：经 ptov_table 安全换算后再验证
            uint64_t l1_kva = pe_pa_to_kva(val);
            if (!l1_kva) continue;
            uint64_t l1e = ds_kread64(l1_kva);
            if (l1e != 0 && l1e != 0xFFFFFFFFFFFFFFFFULL) {
                gGameTTBR0 = val;
                PE_LOG("TTBR0=0x%llx (pmap+0x%x L1[0]=0x%llx)",
                       (unsigned long long)val, off, (unsigned long long)l1e);
                return true;
            }
        }
    }
    PE_LOG_ERROR("pmap+0x10..0x40 未找到有效 TTBR0（pmap=0x%llx）",
                 (unsigned long long)pmap);
    pe_detail([NSString stringWithFormat:@"pmap+0x10..0x40 未找到有效 TTBR0（pmap=0x%llx）",
               (unsigned long long)pmap]);
    return false;
}

// ---- 安全 VA → PA（自适应 4KB/16KB，全部经 ptov_table 换算） ----
static uint64_t pe_va_to_pa(uint64_t va)
{
    if (!gGameTTBR0 || gPageShift == 0) return 0;

    if (gPageShift == 12) {
        // ---- 4KB: L0(9)→L1(9)→L2(9) ----
        uint64_t l0 = (va >> 30) & 0x1FF;
        uint64_t l1 = (va >> 21) & 0x1FF;
        uint64_t l2 = (va >> 12) & 0x1FF;

        uint64_t l0_kva = pe_pa_to_kva(gGameTTBR0);
        if (!l0_kva) return 0;
        uint64_t l0e = ds_kread64(l0_kva + l0 * 8);
        if (!(l0e & 3)) return 0;
        if (l0e & 2) return (l0e & 0x0000FFFFC0000000ULL) | (va & 0x3FFFFFFF);

        uint64_t l1pa = l0e & 0x0000FFFFFFFFF000ULL;
        if (!l1pa) return 0;
        uint64_t l1_kva = pe_pa_to_kva(l1pa);
        if (!l1_kva) return 0;
        uint64_t l1e = ds_kread64(l1_kva + l1 * 8);
        if (!(l1e & 3)) return 0;
        if (l1e & 2) return (l1e & 0x0000FFFFFE000000ULL) | (va & 0x1FFFFF);

        uint64_t l2pa = l1e & 0x0000FFFFFFFFF000ULL;
        if (!l2pa) return 0;
        uint64_t l2_kva = pe_pa_to_kva(l2pa);
        if (!l2_kva) return 0;
        uint64_t l2e = ds_kread64(l2_kva + l2 * 8);
        if (!(l2e & 3)) return 0;
        return (l2e & 0x0000FFFFFFFFF000ULL) | (va & 0xFFF);

    } else {
        // ---- 16KB: L1(12)→L2(11)→L3(11) ----
        uint64_t l1 = (va >> 36) & 0xFFF;
        uint64_t l2 = (va >> 25) & 0x7FF;
        uint64_t l3 = (va >> 14) & 0x7FF;

        uint64_t l1_kva = pe_pa_to_kva(gGameTTBR0);
        if (!l1_kva) return 0;
        uint64_t l1e = ds_kread64(l1_kva + l1 * 8);
        if (!(l1e & 3)) return 0;
        if (l1e & 2) {
            return (l1e & 0x0000FFFF80000000ULL) | (va & 0xFFFFFFFFFULL);
        }

        uint64_t l2pa = l1e & 0x0000FFFFFFFFC000ULL;
        if (!l2pa) return 0;
        uint64_t l2_kva = pe_pa_to_kva(l2pa);
        if (!l2_kva) return 0;
        uint64_t l2e = ds_kread64(l2_kva + l2 * 8);
        if (!(l2e & 3)) return 0;
        if (l2e & 2) {
            return (l2e & 0x0000FFFFFFFE0000ULL) | (va & 0x1FFFFFF);
        }

        uint64_t l3pa = l2e & 0x0000FFFFFFFFC000ULL;
        if (!l3pa) return 0;
        uint64_t l3_kva = pe_pa_to_kva(l3pa);
        if (!l3_kva) return 0;
        uint64_t l3e = ds_kread64(l3_kva + l3 * 8);
        if (!(l3e & 3)) return 0;
        return (l3e & 0x0000FFFFFFFFC000ULL) | (va & 0x3FFF);
    }
}

// ---- 内核读原语（ptov_table 换算，失败回退 0，绝不 panic） ----
static uint64_t kread64(uint64_t va) {
    uint64_t pa = pe_va_to_pa(va);
    if (!pa) return 0;
    uint64_t kva = pe_pa_to_kva(pa);
    if (!kva) return 0;
    return ds_kread64(kva);
}
static uint32_t kread32(uint64_t va) {
    uint64_t pa = pe_va_to_pa(va);
    if (!pa) return 0;
    uint64_t kva = pe_pa_to_kva(pa);
    if (!kva) return 0;
    return ds_kread32(kva);
}
static bool kreadbuf(uint64_t va, void *out, size_t sz) {
    if (sz > 4096 || gPageShift == 0) return false;
    uint64_t pa = pe_va_to_pa(va);
    if (!pa) return false;
    uint64_t kva = pe_pa_to_kva(pa); // pa 已含页内偏移
    if (!kva) return false;

    size_t pageMask = (size_t)((1ULL << gPageShift) - 1);
    size_t off = (size_t)(va & pageMask);
    size_t avail = ((size_t)1 << gPageShift) - off;
    if (avail < sz) {
        // 跨页：第二段单独换算
        uint64_t pa2 = pe_va_to_pa(va + (uint64_t)avail);
        if (!pa2) return false;
        uint64_t kva2 = pe_pa_to_kva(pa2);
        if (!kva2) return false;
        ds_kread(kva, out, avail);
        ds_kread(kva2, (char *)out + avail, sz - avail);
        return true;
    }
    ds_kread(kva, out, sz);
    return true;
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

static bool pe_init_game(void)
{
    pe_detect_page_size();
    PE_LOG("内核基址=0x%llx VM_MIN_KERNEL_ADDRESS=0x%llx VM_MAX_KERNEL_ADDRESS=0x%llx",
           (unsigned long long)ds_get_kernel_base(),
           (unsigned long long)VM_MIN_KERNEL_ADDRESS,
           (unsigned long long)VM_MAX_KERNEL_ADDRESS);
    if (!pe_init_ptov()) {
        PE_LOG_ERROR("ptov_table 初始化失败，game init aborted（绝不探测，防内核 panic）");
        return false;
    }
    if (!pe_init_game_pmap()) return false;

    uint64_t probe = 0x100000000ULL;
    for (int i = 0; i < 20000; i++) {
        uint64_t pa = pe_va_to_pa(probe);
        if (pa) {
            uint64_t kva = pe_pa_to_kva(pa);
            if (kva) {
                uint32_t m = ds_kread32(kva);
                if (m == 0xFEEDFACF || m == 0xCFFAEDFE) {
                    // 验证：Mach-O magic 落在可执行映像头部
                    gGameBase = probe;
                    PE_LOG("base=0x%llx iter=%d", (unsigned long long)gGameBase, i);
                    break;
                }
            }
        }
        probe += 0x4000;
    }
    if (!gGameBase) {
        gGameBase = 0x100000000ULL;
        PE_LOG_ERROR("基址扫描未命中 Mach-O 头（0x100000000 起 20000 页），回退默认基址 0x100000000，GWorld 读取可能无效");
    }
    uint64_t gw = kread64(gGameBase + O_GWORLD);
    PE_LOG("GWorld=0x%llx", (unsigned long long)gw);
    gGameOK = (gw > 0x100000000ULL && gw < 0x800000000ULL);
    if (!gGameOK) {
        PE_LOG_ERROR("GWorld=0x%llx 不在预期范围，ESP 可能无数据——游戏版本偏移可能需要更新",
                     (unsigned long long)gw);
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

static void peace_esp_tick(void) {
    if (!gOverlayReady || !gRun || !gGameOK) return;

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
                pe_fail(@"游戏初始化失败（ptov_table / 页表 / 基址扫描），详细日志见 Console.app（subsystem: com.rein.peaceesp）。");
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
