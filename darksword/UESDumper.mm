//
//  UESDumper.mm
//  Rein
//
//  UE4 SDK Dumper（内核远程读版）
//
//  移植自 MJx0/iOS_UEDumper（MIT）的思路：通过 GNames + GUObjectArray
//  遍历 UE4 反射系统，生成 SDK。区别：iOS_UEDumper 是注入游戏的 tweak
//  （本地读内存）；本模块用 DarkSword 内核的 vmmapremotepage 远程页映射
//  读取游戏内存，只需游戏正在运行，不动游戏进程，也不依赖 RemoteCall。
//
//  布局依据（2026-09-06 真机诊断日志 + iOS_UEDumper 参考实现）：
//  - UObject 为 stock UE4.23+ 布局（GWorld 转储验证：Class@0x10 /
//    Name@0x18 / Outer@0x20 / InternalIndex@0x0C）
//  - GNames 为定制 TNameEntryArray 风格：
//      [base+offGNames] → 块指针数组（+0x00 起，无头部）
//      每块             → 条目指针数组（位置即索引）
//      条目             → {+0x00 哈希链; +0x08 u32 id; +0x0C u16; +0x0E NUL 结尾名字}
//    条目 id = (块<<15)|(位置<<1)，与全部观测样本吻合；FName index 的
//    编码用三候选 + 「GWorld 类名必须是 World」锚点在运行时确定。
//  - GUObjectArray 布局组合候选自适应 + 双锚点确认：
//      ObjObjects 内偏移 ∈ {0x10, 0x00}；Num 偏移 ∈ {0x14, 0x0C, 0x08}；
//      chunk 元素数 1<<{16,13,6} 或 UE4.18/19 旧式平铺数组；item 步长
//      ∈ {0x18, 0x20}、Object 槽内偏移 ∈ {0x00, 0x08}（反 dump 改版兜底）。
//      主锚点 = GWorld 的 InternalIndex 反查指针相等；次锚点 = 头/尾整排
//      合法 UObject（不依赖 InternalIndex，防字段偏移被改）。首选值扫描
//      （堆里搜 GWorld 槽位反推数组再反查全局指针），回退为远程解析主映像
//      Mach-O 的 __DATA* 各 section 逐段扫描（含 __bss）。
//  - UStruct 代际（4.18 / 4.20-22 / 4.23+）在运行时用「World 的
//    SuperStruct 类名必须是 Object」锚点校准，防止旧引擎游戏用 4.25
//    公式生成出错误 SDK。
//

#import "UESDumper.h"
#import "ReinBridge.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

extern "C" {
#import "darksword.h"
#import "utils.h"
#import "offsets.h"

// TaskRop/vm.h 的接口（C 链接，同 PeaceESP.mm 的做法）
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
// 日志（镜像到 App 内控制台日志，同 PE/RB 的做法）
// ============================================================

static os_log_t ud_log_handle(void) {
    static os_log_t handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = os_log_create("com.rein.uesdumper", "dump");
    });
    return handle;
}

#define UD_LOG(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *ud_line = [NSString stringWithFormat:(@"" fmt), ##__VA_ARGS__]; \
        os_log(ud_log_handle(), "[UD] %{public}s", ud_line.UTF8String ?: "(null)"); \
        ReinAppendConsoleLog([@"[UESDumper] " stringByAppendingString:ud_line]); \
        _Pragma("clang diagnostic pop") \
    } while (0)

#define UD_LOG_ERROR(fmt, ...) \
    do { \
        _Pragma("clang diagnostic push") \
        _Pragma("clang diagnostic ignored \"-Wformat-security\"") \
        NSString *ud_line = [NSString stringWithFormat:(@"" fmt), ##__VA_ARGS__]; \
        os_log_error(ud_log_handle(), "[UD] %{public}s", ud_line.UTF8String ?: "(null)"); \
        ReinAppendConsoleLog([@"[UESDumper][错误] " stringByAppendingString:ud_line]); \
        _Pragma("clang diagnostic pop") \
    } while (0)

// ============================================================
// UE 偏移配置（随游戏版本更新改这里）
// ============================================================
static struct {
    // ---- 主映像内全局（base + offset 处存放指针）----
    uint32_t offGWorld;      // GWorld 全局（已验证：0x1148B608）
    uint32_t offGNames;      // GNames 全局（已验证：0x11FBA198）
    uint32_t offGObjects;    // GUObjectArray 全局；0 = 自动扫描（找到后自动记忆）

    // ---- UObject（stock UE4.23+；GWorld 转储已验证）----
    uint32_t uobjName;       // FName：index@+0x18（u32），number@+0x1C（u32）
    uint32_t uobjClass;      // ClassPrivate @+0x10
    uint32_t uobjOuter;      // OuterPrivate @+0x20
    uint32_t uobjIndex;      // InternalIndex @+0x0C

    // ---- UField / UStruct（iOS_UEDumper UE4.25 公式）----
    uint32_t ufieldNext;     // UField::Next @+0x28
    uint32_t ustructSuper;   // UStruct::SuperStruct @+0x40
    uint32_t ustructChildren;// UStruct::Children @+0x48
    uint32_t ustructChildProps; // UStruct::ChildProperties（FField 链）@+0x50
    uint32_t ustructSize;    // UStruct::PropertiesSize（u32）@+0x58

    // ---- FField / FProperty（iOS_UEDumper UE4.25 公式）----
    uint32_t ffieldClass;    // FField::ClassPrivate @+0x08
    uint32_t ffieldName;    // FField::NamePrivate：index@+0x28，number@+0x2C
    uint32_t ffieldNext;    // FField::Next @+0x20
    uint32_t fpropArrayDim;  // FProperty::ArrayDim（u32）@+0x34
    uint32_t fpropOffset;    // FProperty::Offset_Internal（u32）@+0x4C

    // ---- UEnum / UFunction（iOS_UEDumper UE4.25 公式）----
    uint32_t uenumNames;     // UEnum::Names（TArray：data@+0x40，num@+0x48）
    uint32_t ufuncExec;      // UFunction::Func @+0xD8
} UE = {
    0x1148B608,  // offGWorld
    0x11FBA198,  // offGNames
    0,           // offGObjects：自动扫描

    0x18, 0x10, 0x20, 0x0C,        // UObject

    0x28, 0x40, 0x48, 0x50, 0x58,  // UField/UStruct

    0x08, 0x28, 0x20, 0x34, 0x4C,  // FField/FProperty

    0x40, 0xD8,                     // UEnum/UFunction
};

static NSString * const kUDGObjectsOffKey = @"rein.uesdumper.gobjectsOff";

// ============================================================
// 远程读层（vm_object 页映射 + 开放寻址页缓存；独立于 PeaceESP）
// ============================================================

static uint64_t gVMMap = 0;
static int gPageShift = 0;
static long gUDMapFail = 0; // 页映射失败计数（内核通道不稳时读全零，必漏）

#define UD_PAGE_CACHE_CAP 4096 // 64MB 热窗口（16KB 页）
typedef struct { uint64_t remotePage; uint64_t localPage; } UDPageSlot;
static UDPageSlot gPageCache[UD_PAGE_CACHE_CAP];
static int gPageCacheCount = 0;

static uint64_t ud_page_size(void) { return (uint64_t)1 << (gPageShift ? gPageShift : 14); }

static void ud_page_cache_flush(void) {
    uint64_t ps = ud_page_size();
    for (int i = 0; i < UD_PAGE_CACHE_CAP; i++) {
        if (gPageCache[i].remotePage) {
            mach_vm_deallocate(mach_task_self(),
                               (mach_vm_address_t)gPageCache[i].localPage, ps);
            gPageCache[i].remotePage = 0;
        }
    }
    gPageCacheCount = 0;
}

static uint64_t ud_page_cache_get(uint64_t remotePage) {
    uint64_t mask = UD_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < UD_PAGE_CACHE_CAP; i++) {
        UDPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) return s->localPage;
        if (s->remotePage == 0) break;
    }
    return 0;
}

static void ud_page_cache_put(uint64_t remotePage, uint64_t localPage) {
    if (gPageCacheCount >= UD_PAGE_CACHE_CAP) {
        UD_LOG("页缓存满（%d），整体回收（dump 会继续，只是变慢）", gPageCacheCount);
        ud_page_cache_flush();
    }
    uint64_t mask = UD_PAGE_CACHE_CAP - 1;
    uint64_t h = (remotePage >> 14) & mask;
    for (uint64_t i = 0; i < UD_PAGE_CACHE_CAP; i++) {
        UDPageSlot *s = &gPageCache[(h + i) & mask];
        if (s->remotePage == remotePage) { s->localPage = localPage; return; }
        if (s->remotePage == 0) {
            s->remotePage = remotePage;
            s->localPage = localPage;
            gPageCacheCount++;
            return;
        }
    }
}

static uint64_t ud_map_remote_page(uint64_t remotePage) {
    uint64_t local = ud_page_cache_get(remotePage);
    if (local) return local;
    // 内核层对坏页会抛 ObjC 异常（set_target_kaddr）——扫描阶段会对任意
    // 候选地址探测，必须兜住，否则一个坏页就崩掉整个 App
    struct vmshmem sh;
    @try {
        sh = vmmapremotepage(gVMMap, remotePage);
    } @catch (NSException *exception) {
        gUDMapFail++; // 内核通道异常（计数供扫描结束时汇总提示）
        return 0; // 当作不可映射处理
    }
    if (!sh.used || !sh.localAddress) { gUDMapFail++; return 0; }
    ud_page_cache_put(remotePage, sh.localAddress);
    return sh.localAddress;
}

static bool ud_kreadbuf(uint64_t va, void *out, size_t sz) {
    if (sz == 0 || gPageShift == 0 || sz > ud_page_size()) return false;
    uint64_t ps = ud_page_size();
    uint64_t page = va & ~(ps - 1);
    uint64_t off = va - page;
    if (off + sz > ps) {
        size_t first = (size_t)(ps - off);
        return ud_kreadbuf(va, out, first) &&
               ud_kreadbuf(va + first, (char *)out + first, sz - first);
    }
    uint64_t local = ud_map_remote_page(page);
    if (!local) return false;
    memcpy(out, (const void *)(local + off), sz);
    return true;
}

static uint64_t ud_kread64(uint64_t va) { uint64_t v = 0; ud_kreadbuf(va, &v, 8); return v; }
static uint32_t ud_kread32(uint64_t va) { uint32_t v = 0; ud_kreadbuf(va, &v, 4); return v; }

// 区域批量读（扫描用）：逐页拷贝、页大小自适应、坏页置零跳过。
// 与 ud_kreadbuf 的区别：不受单页大小上限约束，尽力读完整个区域。
static void ud_kread_best_effort(uint64_t va, void *out, size_t sz) {
    uint64_t ps = ud_page_size();
    size_t done = 0;
    while (done < sz) {
        uint64_t cur = va + done;
        uint64_t page = cur & ~(ps - 1);
        uint64_t off = cur - page;
        size_t chunk = (size_t)(ps - off);
        if (chunk > sz - done) chunk = sz - done;
        uint64_t local = ud_map_remote_page(page);
        if (local) {
            memcpy((char *)out + done, (const void *)(local + off), chunk);
        } else {
            memset((char *)out + done, 0, chunk); // 坏页置零（qword 预筛会跳过）
        }
        done += chunk;
    }
}

static bool ud_userland(uint64_t p) { return p >= 0x100000000ULL && p < 0x800000000ULL; }

// 宽指针判定（仅用于 GUObjectArray 定位）：Objects 数组可达十几 MB，
// 属于大分配，可能落在较高的 VM 区间。最终命中仍由 item==GWorld 强校验
// 兜底，放宽预筛只影响速度不影响正确性。
static bool ud_ptr_wide(uint64_t p) { return p >= 0x100000000ULL && p < 0x80000000000ULL; }

// ============================================================
// GNames（定制 TNameEntryArray 风格；真机诊断已确认布局）
// ============================================================

static uint64_t gGNames = 0;
static int gNameIndexMode = 1; // 0=(块<<14|位置) 1=(块<<15)|(位置<<1) 2=(块<<16|位置)

// 条目名字：NUL 结尾字符串 @+0x0E
static bool ud_entry_name(uint64_t entry, char *out, size_t cap) {
    if (!ud_userland(entry) || cap == 0) return false;
    uint8_t buf[256];
    if (!ud_kreadbuf(entry + 0x0E, buf, sizeof(buf))) return false;
    size_t len = 0;
    while (len < sizeof(buf) && buf[len] != 0) len++;
    if (len == 0 || len >= sizeof(buf)) return false; // 无 NUL 或名字超长
    if (len + 1 > cap) return false;
    memcpy(out, buf, len + 1);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)out[i];
        if (c < 0x20 || c > 0x7E) return false; // 防错位读到垃圾
    }
    return true;
}

// 按指定 index 编码解码名字
static bool ud_name_decode(int mode, uint32_t F, char *out, size_t cap) {
    uint32_t chunk, pos;
    switch (mode) {
        case 0:  chunk = F >> 14; pos = F & 0x3FFF;       break;
        case 1:  chunk = F >> 15; pos = (F & 0x7FFF) >> 1; break;
        default: chunk = F >> 16; pos = F & 0xFFFF;      break;
    }
    if (chunk >= 8192) return false;
    uint64_t chunkPtr = ud_kread64(gGNames + (uint64_t)chunk * 8);
    if (!ud_userland(chunkPtr)) return false;
    uint64_t entry = ud_kread64(chunkPtr + (uint64_t)pos * 8);
    if (!ud_userland(entry)) return false;
    return ud_entry_name(entry, out, cap);
}

// 名字缓存：槽位带 idx 键（命中才用），保证不因哈希冲突串名
#define UD_NAME_CACHE_CAP (1 << 20)
typedef struct { uint32_t idx; char *str; } UDNameSlot;
static UDNameSlot *gNameCache = NULL;

static const char *ud_name_cached(uint32_t idx) {
    if (!gNameCache) {
        gNameCache = (UDNameSlot *)calloc(UD_NAME_CACHE_CAP, sizeof(UDNameSlot));
        if (!gNameCache) return NULL;
    }
    uint32_t mask = UD_NAME_CACHE_CAP - 1;
    uint32_t slot = (idx * 2654435761u) & mask;
    if (gNameCache[slot].str && gNameCache[slot].idx == idx) {
        return gNameCache[slot].str;
    }
    char buf[320];
    if (!ud_name_decode(gNameIndexMode, idx, buf, sizeof(buf))) return NULL;
    if (gNameCache[slot].str) free(gNameCache[slot].str);
    gNameCache[slot].idx = idx;
    gNameCache[slot].str = strdup(buf);
    return gNameCache[slot].str;
}

static void ud_name_cache_free(void) {
    if (!gNameCache) return;
    for (int i = 0; i < UD_NAME_CACHE_CAP; i++) {
        if (gNameCache[i].str) free(gNameCache[i].str);
    }
    free(gNameCache);
    gNameCache = NULL;
}

// 对象名（含 number 后缀：number>0 → "_{number-1}"）。
// 返回值指向循环缓冲，调用方需立即使用（拼路径时当场拷贝）。
static char gNameBuf[8][352];
static int gNameBufIdx = 0;

static const char *ud_obj_name(uint64_t obj) {
    uint32_t idx = ud_kread32(obj + UE.uobjName);
    uint32_t num = ud_kread32(obj + UE.uobjName + 4);
    const char *base = ud_name_cached(idx);
    if (!base) return NULL;
    char *buf = gNameBuf[gNameBufIdx = (gNameBufIdx + 1) & 7];
    if (num > 0 && num < 1000000) {
        snprintf(buf, 352, "%s_%u", base, num - 1);
    } else {
        snprintf(buf, 352, "%s", base);
    }
    return buf;
}

// 完整路径（沿 Outer 链向上拼；深度限 10 防环）
static void ud_full_path(uint64_t obj, char *out, size_t cap) {
    out[0] = 0;
    if (!ud_userland(obj)) return;
    char parts[12][352];
    int n = 0;
    uint64_t cur = obj;
    while (n < 10) {
        const char *nm = ud_obj_name(cur);
        if (!nm) break;
        snprintf(parts[n], sizeof(parts[n]), "%s", nm);
        n++;
        uint64_t outer = ud_kread64(cur + UE.uobjOuter);
        if (!ud_userland(outer)) break;
        cur = outer;
    }
    size_t used = 0;
    for (int i = n - 1; i >= 0; i--) {
        int w = snprintf(out + used, cap - used, "%s%s", (i == n - 1) ? "" : ".", parts[i]);
        if (w <= 0 || (size_t)w >= cap - used) break;
        used += (size_t)w;
    }
}

// ============================================================
// 状态
// ============================================================

static volatile bool gUDRunning = false;
static NSString *gUDError = @"";
static NSString *gUDOutput = @"";

BOOL UESDumperIsRunning(void) { return gUDRunning; }
NSString *UESDumperLastError(void) { return gUDError ?: @""; }
NSString *UESDumperLastOutputPath(void) { return gUDOutput ?: @""; }

static void ud_fail(NSString *msg) {
    gUDError = [msg copy];
    UD_LOG_ERROR("%@", msg);
}

// ============================================================
// 附加游戏 + 定位基址（与 PeaceESP.pe_init_game 同思路）
// ============================================================
static uint64_t gBase = 0, gGWorld = 0, gGObjects = 0;

// 指定地址起 n 字节的 hex+ASCII 双视图（诊断用）
static void ud_dump_hex_ascii(const char *tag, uint64_t addr, int bytes) {
    uint8_t b[64];
    int n = (bytes < 64) ? bytes : 64;
    if (n <= 0) return;
    if (!ud_kreadbuf(addr, b, (size_t)n)) {
        UD_LOG("%s @0x%llx = <读取失败>", tag, (unsigned long long)addr);
        return;
    }
    NSMutableString *hex = [NSMutableString string];
    NSMutableString *asc = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        [hex appendFormat:@"%02x ", b[i]];
        [asc appendFormat:@"%c", (b[i] >= 0x20 && b[i] <= 0x7E) ? b[i] : '.'];
    }
    UD_LOG("%s @0x%llx\n  hex: %@\n  asc: %@", tag, (unsigned long long)addr, hex, asc);
}

/// GNames 失败时的深度诊断（布局证据采集）
static void ud_gnames_dump_diagnose(void) {
    UD_LOG_ERROR("── GNames 深度诊断开始 ──");
    UD_LOG("GNames=0x%llx GWorld=0x%llx Class=0x%llx",
           (unsigned long long)gGNames, (unsigned long long)gGWorld,
           (unsigned long long)ud_kread64(gGWorld + UE.uobjClass));
    UD_LOG("GWorld: NameIdx=0x%x NameNum=0x%x InternalIndex=0x%x",
           ud_kread32(gGWorld + UE.uobjName), ud_kread32(gGWorld + UE.uobjName + 4),
           ud_kread32(gGWorld + UE.uobjIndex));
    ud_dump_hex_ascii("GWorld头", gGWorld, 64);
    ud_dump_hex_ascii("pool头", gGNames, 64);
    for (int i = 0; i < 3; i++) {
        uint64_t chunk = ud_kread64(gGNames + (uint64_t)i * 8);
        if (!ud_userland(chunk)) continue;
        ud_dump_hex_ascii("块头", chunk, 32);
        uint64_t entry = ud_kread64(chunk);
        if (ud_userland(entry)) ud_dump_hex_ascii("条目0", entry, 48);
    }
    // 三种 index 编码对 GWorld 类名的解码结果（正常其一应为 "World"）
    uint64_t cls = ud_kread64(gGWorld + UE.uobjClass);
    if (ud_userland(cls)) {
        uint32_t clsF = ud_kread32(cls + UE.uobjName);
        for (int mode = 0; mode < 3; mode++) {
            char n[256];
            if (ud_name_decode(mode, clsF, n, sizeof(n))) {
                UD_LOG("mode%d 解码 GWorld 类名 = %s", mode, n);
            } else {
                UD_LOG("mode%d 解码失败", mode);
            }
        }
    }
    UD_LOG_ERROR("── GNames 深度诊断结束 ──");
}

static bool ud_attach_game(void) {
    if (gPageShift == 0) {
        vm_size_t ps = 0;
        if (host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps > 0) {
            gPageShift = (ps >= 16384) ? 14 : 12;
        } else {
            gPageShift = 14;
        }
    }

    uint64_t proc = procbyname("ShadowTrackerExtra");
    if (!proc) { ud_fail(@"未找到游戏进程 ShadowTrackerExtra，请先进入游戏"); return false; }
    uint64_t task = proc_task(proc);
    if (!task) { ud_fail(@"proc_task 取不到 task"); return false; }
    gVMMap = task_get_vm_map(task);
    if (!ds_isvalid(gVMMap)) { ud_fail(@"task_get_vm_map 取不到 vm_map"); return false; }
    UD_LOG("vm_map=0x%llx", (unsigned long long)gVMMap);

    // 基址扫描：窗口内 Mach-O 条目 + base+offGWorld 双重校验（同 PeaceESP）
    // block 按值捕获 C 数组且为只读——用堆缓冲 + 指针捕获（PeaceESP 同款做法）
    typedef struct { uint64_t start, end; } UDMapCand;
    UDMapCand *cand = (UDMapCand *)calloc(128, sizeof(UDMapCand));
    if (!cand) { ud_fail(@"内存不足（候选条目缓冲）"); return false; }
    __block int n = 0;
    vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (n >= 128) { *stop = YES; return; }
        if (start < 0x100000000ULL || start >= 0x800000000ULL) return;
        if (end - start < 0x4000ULL) return;
        cand[n].start = start; cand[n].end = end; n++;
    });
    UD_LOG("vm_map 窗口内候选条目 %d 个", n);

    for (int i = 0; i < n && !gBase; i++) {
        uint32_t magic = 0;
        if (!ud_kreadbuf(cand[i].start, &magic, sizeof(magic))) continue;
        if (magic != 0xFEEDFACF && magic != 0xCFFAEDFE) continue;
        uint64_t gwv = ud_kread64(cand[i].start + UE.offGWorld);
        if (!ud_userland(gwv)) continue;
        uint64_t hop1 = ud_kread64(gwv + 0xC0);
        if (!ud_userland(hop1)) continue;
        gBase = cand[i].start;
    }
    free(cand);
    if (!gBase) { ud_fail(@"未找到主映像基址（base+offGWorld 校验全灭，offGWorld 可能过期）"); return false; }
    UD_LOG("base=0x%llx", (unsigned long long)gBase);

    gGWorld = ud_kread64(gBase + UE.offGWorld);
    if (!ud_userland(gGWorld)) { ud_fail(@"GWorld 无效（游戏可能还在加载，或 offGWorld 过期）"); return false; }

    // ---- GNames 校验（锚点1：块0/条目0 的名字必须是 "None"）----
    gGNames = ud_kread64(gBase + UE.offGNames);
    if (!ud_userland(gGNames)) { ud_fail(@"GNames 无效（offGNames 可能过期）"); return false; }
    char noneBuf[64];
    uint64_t chunk0 = ud_kread64(gGNames);
    uint64_t entry0 = ud_userland(chunk0) ? ud_kread64(chunk0) : 0;
    if (!ud_entry_name(entry0, noneBuf, sizeof(noneBuf)) || strcmp(noneBuf, "None") != 0) {
        ud_gnames_dump_diagnose();
        ud_fail(@"GNames 布局校验失败（块0/条目0 应为 None，详见诊断日志）");
        return false;
    }
    UD_LOG("GNames OK（条目0 = %s，id=0x%x）", noneBuf, ud_kread32(entry0 + 0x08));

    // ---- index 编码确定（锚点2：GWorld 的类名必须是 "World"）----
    uint64_t cls = ud_kread64(gGWorld + UE.uobjClass);
    if (!ud_userland(cls)) { ud_fail(@"GWorld ClassPrivate 无效"); return false; }
    uint32_t clsF = ud_kread32(cls + UE.uobjName);
    gNameIndexMode = -1;
    for (int mode = 0; mode < 3; mode++) {
        char n[256];
        if (ud_name_decode(mode, clsF, n, sizeof(n)) && strcmp(n, "World") == 0) {
            gNameIndexMode = mode;
            break;
        }
    }
    if (gNameIndexMode < 0) {
        // 没有候选命中 "World"——打出三者结果供离线分析
        for (int mode = 0; mode < 3; mode++) {
            char n[256];
            if (ud_name_decode(mode, clsF, n, sizeof(n))) {
                UD_LOG("mode%d 解码 GWorld 类名 = %s", mode, n);
            }
        }
        ud_fail(@"GNames index 编码确定失败（无候选解出类名 World）");
        return false;
    }
    UD_LOG("index 编码 = mode%d（GWorld 类名 = World ✓）", gNameIndexMode);
    return true;
}

// ============================================================
// GUObjectArray 定位（组合候选自适应 + 自动扫描，找到后记忆）
// ============================================================
// 布局候选（iOS_UEDumper 公式 + 真机适配 + 反 dump 改版兜底）：
//   ObjObjects 内偏移 / Num 偏移 / chunk 元素数 / item 步长 / 槽内偏移
//   全维候选（见下方 gUD* 表）。第三轮真机证据：该游戏 GNames 为定制
//   容器（16384 条目/块 × 每条目 8B 指针），GUObjectArray 很可能同风格
//   ——纯指针数组（stride=8）/ 16384 条目块（shift=14）均纳入候选。
// 确认法（双锚点，任一命中即真）：
//   主锚点 = 已知 GWorld 的 InternalIndex 反查数组，指针精确相等，
//   且数组尾部有合法 UObject（防 Num 槽位误中）；
//   次锚点 = Num ≥ 0x10000 且数组头 8 项 + 尾部 4 项均为可解出类名的
//   合法 UObject——不依赖 InternalIndex 偏移，防其被改导致主锚点失效。
static struct {
    uint32_t innerOff;  // ObjObjects 在候选结构内的偏移
    uint32_t numOff;    // Num 在 TUObjectArray 内的偏移
    int chunkShift;     // 每 chunk 元素数 = 1 << chunkShift；0 = 平铺（非 chunk）
    uint32_t itemStride;// FUObjectItem 步长
    uint32_t itemObjOff;// Object 在 FUObjectItem 内的偏移
    bool weakAnchor;    // true = 次锚点命中（主锚点未中，InternalIndex 可能被改）
} gOA = { 0x10, 0x14, 16, 0x18, 0x00, false };

// 候选空间（确认与扫描预筛共用）
static const uint32_t gUDInner[]  = { 0x10, 0x00, 0x08, 0x18, 0x20 };
static const uint32_t gUDNum[]    = { 0x14, 0x0C, 0x08, 0x10, 0x18 };
static const int      gUDShift[]  = { 16, 14, 13, 6, 0 }; // 0 = 平铺
static const uint32_t gUDStride[] = { 0x18, 0x20, 0x08, 0x10, 0x28, 0x30 };
static const uint32_t gUDObjOff[] = { 0x00, 0x08 };
#define UD_ARR_LEN(a) (sizeof(a) / sizeof((a)[0]))

static int gUDNearMiss = 0;           // 高价值近失日志配额（Num ≥ gworldIdx/2 才记）
static uint64_t gUDNearMissLastV = 0; // 去重：同 V 的全部组合只记一条
static long gUDNearMissJunk = 0;      // 低价值近失计数（字节花纹垃圾，仅汇总）
static long gUDSkippedBig = 0;        // 值扫描跳过的超大区域数（共享缓存等）

static const char *ud_oa_desc(void) {
    static char buf[80];
    char mode[24];
    if (gOA.chunkShift == 0) snprintf(mode, sizeof(mode), "flat平铺");
    else snprintf(mode, sizeof(mode), "chunk=1<<%d", gOA.chunkShift);
    snprintf(buf, sizeof(buf), "%s stride=0x%x obj@+0x%x%s", mode,
             gOA.itemStride, gOA.itemObjOff, gOA.weakAnchor ? "（次锚点）" : "");
    return buf;
}

// 按候选布局取第 idx 个 UObject 的槽位值（不校验有效性）
static uint64_t ud_oa_item_at(uint64_t objects, uint32_t idx,
                              int chunkShift, uint32_t stride, uint32_t objOff) {
    if (chunkShift == 0) {
        // UE4.18/19 旧式 TUObjectArray：Objects 本身就是平铺 FUObjectItem 数组
        return ud_kread64(objects + (uint64_t)idx * stride + objOff);
    }
    uint32_t mask = (1u << chunkShift) - 1;
    uint64_t chunk = ud_kread64(objects + (uint64_t)(idx >> chunkShift) * 8);
    if (!ud_ptr_wide(chunk)) return 0;
    return ud_kread64(chunk + (uint64_t)(idx & mask) * stride + objOff);
}

// 对象是否为「可解出类名的合法 UObject」（锚点校验用）
static bool ud_is_named_uobject(uint64_t obj) {
    if (!ud_userland(obj)) return false;
    uint64_t c = ud_kread64(obj + UE.uobjClass);
    if (!ud_userland(c)) return false;
    return ud_obj_name(c) != NULL;
}

// ---- 组合确认的读缓存（memo）----
// 同一候选 V 的全部组合里，数组槽位读取只依赖 (inner, shift, stride,
// objOff) 四个维度——按候选表索引缓存后，每个 V 的内核往返从上千次降到
// 最多 ~150 次（第四轮真机实测：__common 4MB 扫 9 分钟即此瓶颈）。
#define UD_MEMO_IDX_GW 8 // item 槽位下标：0..7 = 头部 idx，8 = gworldIdx
typedef struct {
    uint64_t V;
    uint64_t item[5][5][6][2][9];
    bool set[5][5][6][2][9];
} UDOAMemo;
static UDOAMemo gOAMemo;

static uint64_t ud_memo_item(uint64_t V, uint64_t objects, uint32_t gworldIdx,
                             size_t a, size_t c, size_t d, size_t e, uint32_t idxSlot) {
    if (gOAMemo.V != V) {
        memset(gOAMemo.set, 0, sizeof(gOAMemo.set));
        gOAMemo.V = V;
    }
    uint64_t *val = &gOAMemo.item[a][c][d][e][idxSlot];
    if (!gOAMemo.set[a][c][d][e][idxSlot]) {
        uint32_t idx = (idxSlot == UD_MEMO_IDX_GW) ? gworldIdx : idxSlot;
        *val = ud_oa_item_at(objects, idx, gUDShift[c], gUDStride[d], gUDObjOff[e]);
        gOAMemo.set[a][c][d][e][idxSlot] = true;
    }
    return *val;
}

// 返回 0=未中 1=主锚点 2=次锚点（a..e 为候选表索引，配合 memo 缓存）
static int ud_oa_try(uint64_t V, uint32_t gworldIdx, uint64_t gworld,
                     size_t a, size_t b, size_t c, size_t d, size_t e) {
    const uint32_t innerOff = gUDInner[a], numOff = gUDNum[b];
    uint64_t objects = ud_kread64(V + innerOff);
    if (!ud_ptr_wide(objects)) return 0;
    int32_t numE = (int32_t)ud_kread32(V + innerOff + numOff);
    if (numE <= 0 || numE > 0x1000000) return 0; // 真实对象数在几十万量级
    if ((uint32_t)numE <= gworldIdx && numE < 0x10000) return 0; // 主/次锚点都够不着
    // Max 取 Num 的前/后邻槽之一（兼容 Num/Max 互换的改版）
    bool maxOK = false;
    for (int side = -1; side <= 1 && !maxOK; side += 2) {
        int32_t mx = (int32_t)ud_kread32(V + innerOff + numOff + side * 4);
        if (mx >= numE && mx <= 0x1000000) maxOK = true;
    }
    if (!maxOK) return 0;

    // 主锚点：GWorld 反查（memo 缓存；InternalIndex → 槽位 → 指针相等），
    // 再以数组尾部合法对象二次锚定 Num 槽位（反查本身不依赖 Num）
    uint64_t itemGW = ud_memo_item(V, objects, gworldIdx, a, c, d, e, UD_MEMO_IDX_GW);
    if (itemGW == gworld) {
        for (int back = 1; back <= 4; back++) {
            if (numE <= back) break;
            if (ud_is_named_uobject(ud_oa_item_at(objects, (uint32_t)(numE - back),
                                                  gUDShift[c], gUDStride[d], gUDObjOff[e])))
                return 1;
        }
        UD_LOG("主锚点命中但尾锚失败 base+0x%llx（Num@+0x%x：Num=%d）",
               (unsigned long long)(V - gBase), innerOff + numOff, numE);
        return 0;
    }
    // 次锚点：仅当 gworldIdx 槽位读出的是真指针（真数组特征）才做头部
    // 校验——垃圾结构的该槽位多为非指针，直接跳过（省 8 次内核读/组合）
    if (numE >= 0x10000 && ud_ptr_wide(itemGW)) {
        int headOK = 0;
        for (uint32_t i = 0; i < 8; i++) {
            if (ud_is_named_uobject(ud_memo_item(V, objects, gworldIdx, a, c, d, e, i)))
                headOK++;
        }
        if (headOK >= 6) {
            for (int back = 1; back <= 4; back++) {
                if (numE <= back) break;
                if (ud_is_named_uobject(ud_oa_item_at(objects, (uint32_t)(numE - back),
                                                      gUDShift[c], gUDStride[d], gUDObjOff[e])))
                    return 2;
            }
        }
    }
    // 近失诊断：高价值（Num ≥ gworldIdx/2，真 Num 必须 > gworldIdx）记
    // 日志 + hex；其余只计数、结束汇总——不再让字节花纹垃圾烧光配额
    if (numE >= (int32_t)(gworldIdx / 2)) {
        if (gUDNearMiss < 8 && V != gUDNearMissLastV) {
            UD_LOG("高价值近失 base+0x%llx（Obj@+0x%x Num@+0x%x：Num=%d）",
                   (unsigned long long)(V - gBase), innerOff, numOff, numE);
            ud_dump_hex_ascii("nearmiss-hex", V, 0x40);
            gUDNearMissLastV = V;
            gUDNearMiss++;
        }
    } else {
        gUDNearMissJunk++;
    }
    return 0;
}

static bool ud_gobjects_confirms(uint64_t V, uint32_t gworldIdx, uint64_t gworld) {
    for (size_t a = 0; a < UD_ARR_LEN(gUDInner); a++) {
        for (size_t b = 0; b < UD_ARR_LEN(gUDNum); b++) {
            for (size_t c = 0; c < UD_ARR_LEN(gUDShift); c++) {
                for (size_t d = 0; d < UD_ARR_LEN(gUDStride); d++) {
                    for (size_t e = 0; e < UD_ARR_LEN(gUDObjOff); e++) {
                        int hit = ud_oa_try(V, gworldIdx, gworld, a, b, c, d, e);
                        if (hit) {
                            gOA.innerOff = gUDInner[a];
                            gOA.numOff = gUDNum[b];
                            gOA.chunkShift = gUDShift[c];
                            gOA.itemStride = gUDStride[d];
                            gOA.itemObjOff = gUDObjOff[e];
                            gOA.weakAnchor = (hit == 2);
                            return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

// 按已锁定的布局取第 idx 个 UObject
static uint64_t ud_uobject_at(uint32_t idx) {
    uint64_t objects = ud_kread64(gGObjects + gOA.innerOff);
    if (!ud_ptr_wide(objects)) return 0;
    if (gOA.chunkShift == 0)
        return ud_kread64(objects + (uint64_t)idx * gOA.itemStride + gOA.itemObjOff);
    uint32_t mask = (1u << gOA.chunkShift) - 1;
    uint64_t chunk = ud_kread64(objects + (uint64_t)(idx >> gOA.chunkShift) * 8);
    if (!ud_ptr_wide(chunk)) return 0;
    return ud_kread64(chunk + (uint64_t)(idx & mask) * gOA.itemStride + gOA.itemObjOff);
}

static int32_t ud_uobject_count(void) {
    return (int32_t)ud_kread32(gGObjects + gOA.innerOff + gOA.numOff);
}

// ============================================================
// 扫描辅助：主映像 Mach-O section 收集 + 区间扫描
// ============================================================
// 真机两轮扫描（GNames ±64/32MB 窗口）均未命中且无有效近失——要么全局
// 不在窗口内，要么布局被改。这里改为远程解析主映像 Mach-O 的
// LC_SEGMENT_64，逐 section 扫描全部 __DATA* 段（含 __bss/__common，
// GUObjectArray 全局可能在任一数据 section），保证覆盖完整；
// 按「距 GNames 全局的距离」从近到远扫，兼顾命中速度。

#define UD_MAX_SECTS 96
typedef struct { uint64_t addr, size; char name[32]; } UDSect;

static int ud_collect_data_sections(UDSect *out, int cap) {
    uint8_t hdr[32];
    if (!ud_kreadbuf(gBase, hdr, sizeof(hdr))) return 0;
    uint32_t magic = 0;
    memcpy(&magic, hdr, 4);
    if (magic != 0xFEEDFACF && magic != 0xCFFAEDFE) return 0;
    uint32_t ncmds = 0, sizeofcmds = 0;
    memcpy(&ncmds, hdr + 16, 4);      // mach_header_64.ncmds
    memcpy(&sizeofcmds, hdr + 20, 4); // mach_header_64.sizeofcmds
    if (ncmds == 0 || ncmds > 1024 || sizeofcmds < 16 || sizeofcmds > 0x40000) return 0;

    uint8_t *cmds = (uint8_t *)malloc(sizeofcmds);
    if (!cmds) return 0;
    // ud_kreadbuf 单次限一页内：按「页内剩余」分块读取 load commands
    uint64_t done = 0;
    while (done < sizeofcmds) {
        uint64_t ps = ud_page_size();
        uint64_t va = gBase + 32 + done;
        uint64_t inPage = ps - (va & (ps - 1));
        uint64_t chunk = sizeofcmds - done;
        if (chunk > inPage) chunk = inPage;
        if (!ud_kreadbuf(va, cmds + done, (size_t)chunk)) break;
        done += chunk;
    }
    if (done < sizeofcmds) { free(cmds); return 0; }

    // pass 1：__TEXT 段 vmaddr → 映射 slide
    uint64_t textVm = 0, off = 0;
    for (uint32_t i = 0; i < ncmds && off + 8 <= sizeofcmds; i++) {
        uint32_t cmd = 0, csz = 0;
        memcpy(&cmd, cmds + off, 4);
        memcpy(&csz, cmds + off + 4, 4);
        if (csz < 8 || off + csz > sizeofcmds) break;
        if (cmd == 0x19 /* LC_SEGMENT_64 */ && csz >= 72) {
            char seg[17];
            memcpy(seg, cmds + off + 8, 16); seg[16] = 0;
            if (!strcmp(seg, "__TEXT")) {
                memcpy(&textVm, cmds + off + 24, 8);
                break;
            }
        }
        off += csz;
    }
    if (!textVm) { free(cmds); return 0; }
    const uint64_t slide = gBase - textVm;

    // pass 2：收集 __DATA* 段（__DATA / __DATA_CONST / __DATA_DIRTY）的 section
    int count = 0;
    off = 0;
    for (uint32_t i = 0; i < ncmds && off + 8 <= sizeofcmds; i++) {
        uint32_t cmd = 0, csz = 0;
        memcpy(&cmd, cmds + off, 4);
        memcpy(&csz, cmds + off + 4, 4);
        if (csz < 8 || off + csz > sizeofcmds) break;
        if (cmd == 0x19 && csz >= 72) {
            char seg[17];
            memcpy(seg, cmds + off + 8, 16); seg[16] = 0;
            if (!strncmp(seg, "__DATA", 6)) {
                uint32_t nsects = 0;
                memcpy(&nsects, cmds + off + 64, 4);
                uint64_t soff = off + 72;
                for (uint32_t s = 0; s < nsects && count < cap; s++, soff += 80) {
                    if (soff + 80 > sizeofcmds) break;
                    char sect[17];
                    memcpy(sect, cmds + soff, 16); sect[16] = 0;
                    uint64_t addr = 0, size = 0;
                    memcpy(&addr, cmds + soff + 32, 8); // section_64.addr
                    memcpy(&size, cmds + soff + 40, 8); // section_64.size
                    uint64_t va = addr + slide;
                    if (size == 0 || va < 0x100000000ULL || va >= 0x80000000000ULL) continue;
                    snprintf(out[count].name, sizeof(out[count].name), "%s,%s", seg, sect);
                    out[count].addr = va;
                    out[count].size = size;
                    count++;
                }
            }
        }
        off += csz;
    }
    free(cmds);

    // 按「距 GNames / GWorld 两个已验证全局的最小距离」升序（插入排序；
    // 近似优先，覆盖不受影响）。第三轮真机：GWorld 在 __common、GNames 在
    // __bss——GUObjectArray 通常与二者之一链接相邻，这两段最先扫。
    const uint64_t anchorA = gBase + UE.offGNames;
    const uint64_t anchorB = gBase + UE.offGWorld;
#define UD_DIST_TO_ANCHORS(s) ({ \
    uint64_t _da = ((s).addr > anchorA) ? ((s).addr - anchorA) : (anchorA - (s).addr); \
    uint64_t _db = ((s).addr > anchorB) ? ((s).addr - anchorB) : (anchorB - (s).addr); \
    (_da < _db) ? _da : _db; })
    for (int i = 1; i < count; i++) {
        UDSect key = out[i];
        uint64_t kd = UD_DIST_TO_ANCHORS(key);
        int j = i - 1;
        while (j >= 0) {
            if (UD_DIST_TO_ANCHORS(out[j]) <= kd) break;
            out[j + 1] = out[j];
            j--;
        }
        out[j + 1] = key;
    }
#undef UD_DIST_TO_ANCHORS
    return count;
}

// 在 [scanLo, scanHi) 内扫描 GUObjectArray：整页批量读 + 本地预筛 + 组合确认。
// 预筛与 ud_oa_try 的廉价检查等价（宽指针 + Num 槽位 + Max 邻槽），
// 不产生额外内核往返，也不会误杀真身。
static bool ud_scan_range_for_gobjects(uint64_t scanLo, uint64_t scanHi,
                                       uint32_t gworldIdx, uint64_t gworld,
                                       uint64_t *foundOut) {
    __block uint64_t found = 0;
    uint8_t *scanBuf = (uint8_t *)malloc(0x4000);
    if (!scanBuf) return false;

    vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (found || end <= scanLo || start >= scanHi) return;
        // 页起点钳制到 scanLo：否则会从 VM entry 起点开始扫（窗口外的
        // 区域重复扫——上轮日志里 __bss 阶段扫到 __common 的近失即此原因）
        uint64_t page = start & ~0x3FFFULL;
        if (page < scanLo) page = scanLo & ~0x3FFFULL;
        for (; page < end && page < scanHi; page += 0x4000ULL) {
            // 进度心跳：每 512KB 一条，慢阶段（内核通道抖动）不再静默几分钟
            if (((page - (scanLo & ~0x3FFFULL)) & 0x7FFFFULL) == 0 && page > (scanLo & ~0x3FFFULL)) {
                UD_LOG("…已扫 %llu MB", (unsigned long long)((page - (scanLo & ~0x3FFFULL)) >> 20));
            }
            // 整段 16K 批量读（坏页置零）；本地预筛后再做完整确认
            ud_kread_best_effort(page, scanBuf, 0x4000);
            for (uint64_t o = 0; o + 0x18 <= 0x4000ULL; o += 8) {
                uint64_t V = page + o; // 候选 GUObjectArray
                if (o + 0x38 <= 0x4000ULL) {
                    // 本地预筛（与 ud_oa_try 廉价检查等价，不产生额外内核往返）：
                    // 某 inner 槽位是宽指针，且对应某 Num 槽位组合形似合理
                    bool plausible = false;
                    for (size_t a = 0; a < UD_ARR_LEN(gUDInner) && !plausible; a++) {
                        uint64_t p;
                        memcpy(&p, scanBuf + o + gUDInner[a], 8);
                        if (!ud_ptr_wide(p)) continue;
                        for (size_t b = 0; b < UD_ARR_LEN(gUDNum) && !plausible; b++) {
                            uint32_t slot = gUDInner[a] + gUDNum[b];
                            uint32_t numE, mx0, mx1;
                            memcpy(&numE, scanBuf + o + slot, 4);
                            memcpy(&mx0, scanBuf + o + slot - 4, 4);
                            memcpy(&mx1, scanBuf + o + slot + 4, 4);
                            if (numE == 0 || numE > 0x1000000) continue;
                            if (numE <= gworldIdx && numE < 0x10000) continue;
                            if ((mx0 >= numE && mx0 <= 0x1000000) ||
                                (mx1 >= numE && mx1 <= 0x1000000))
                                plausible = true;
                        }
                    }
                    if (!plausible) continue;
                }
                if (ud_gobjects_confirms(V, gworldIdx, gGWorld)) {
                    found = V;
                    *stop = YES;
                    return;
                }
            }
        }
    });
    free(scanBuf);
    if (found) *foundOut = found;
    return found != 0;
}

// ============================================================
// 值扫描定位（第四轮主攻）：堆里找 GWorld 槽位 → 反推数组 → 反查全局
// ============================================================
// 原理：FUObjectItem 数组第 gworldIdx 项存着 GWorld 指针。直接在大块
// VM 区域里搜这个指针值，命中后用 idx*stride+objOff 反推数组基址并验证
// 头部对象；再回主映像 __DATA 里搜指向该数组的指针 = GUObjectArray。
// 这是「扫 __DATA 找结构」的反问题——不依赖 Num/Max 槽位猜测，数组在哪、
// 什么布局一次解决。分块容器（全局只指向块指针数组）此法无效，回退
// section 扫描。
static bool ud_value_scan_find_array(uint32_t gworldIdx, uint64_t gworld,
                                     uint64_t *baseOut, uint32_t *strideOut,
                                     uint32_t *objOffOut) {
    typedef struct { uint64_t start, end; } UDRegion;
    UDRegion *regs = (UDRegion *)calloc(2048, sizeof(UDRegion));
    uint8_t *buf = (uint8_t *)malloc(0x4000);
    if (!regs || !buf) { free(regs); free(buf); return false; }

    const uint64_t imgLo = gBase, imgHi = gBase + 0x12000000ULL;
    __block int nR = 0;
    vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (nR >= 2048) { *stop = YES; return; }
        if (start < 0x100000000ULL || start >= 0x80000000000ULL) return;
        // 256KB..256MB：更大的区域是 dyld 共享缓存（第五轮真机实测：
        // [0x180000000,0x1fa000000) 1952MB 以 ~1MB/s 磨半小时也扫不完，
        // 且系统库里绝不会有 GUObjectArray）或显卡/文件大映射，直接跳过
        if (end - start < 0x40000ULL || end - start > 0x10000000ULL) {
            if (end - start > 0x10000000ULL) gUDSkippedBig++;
            return;
        }
        if (start < imgHi && end > imgLo) return; // 主映像自身不扫
        regs[nR].start = start; regs[nR].end = end; nR++;
    });
    // 按距堆锚点（GWorld 对象 / GNames 容器）距离升序：对象数组是引擎
    // 早期分配，通常与二者同处低地址堆区
    for (int i = 1; i < nR; i++) {
        UDRegion key = regs[i];
        uint64_t ka = (key.start > gworld) ? (key.start - gworld) : (gworld - key.start);
        uint64_t kb = (key.start > gGNames) ? (key.start - gGNames) : (gGNames - key.start);
        uint64_t kd = (ka < kb) ? ka : kb;
        int j = i - 1;
        while (j >= 0) {
            uint64_t a2 = (regs[j].start > gworld) ? (regs[j].start - gworld) : (gworld - regs[j].start);
            uint64_t b2 = (regs[j].start > gGNames) ? (regs[j].start - gGNames) : (gGNames - regs[j].start);
            uint64_t d2 = (a2 < b2) ? a2 : b2;
            if (d2 <= kd) break;
            regs[j + 1] = regs[j];
            j--;
        }
        regs[j + 1] = key;
    }
    UD_LOG("值扫描：%d 个大块区域（按距堆锚点距离排序，另跳过 %ld 个超大区域）",
           nR, gUDSkippedBig);

    bool ok = false;
    for (int r = 0; r < nR && !ok; r++) {
        UD_LOG("值扫描 [0x%llx, 0x%llx)（%llu MB）…",
               (unsigned long long)regs[r].start, (unsigned long long)regs[r].end,
               (unsigned long long)((regs[r].end - regs[r].start) >> 20));
        for (uint64_t page = regs[r].start & ~0x3FFFULL; page < regs[r].end && !ok; page += 0x4000ULL) {
            if (((page - regs[r].start) & 0x7FFFFULL) == 0 && page > regs[r].start) {
                UD_LOG("…值扫描进度 %llu MB", (unsigned long long)((page - regs[r].start) >> 20));
            }
            ud_kread_best_effort(page, buf, 0x4000);
            for (uint64_t o = 0; o + 8 <= 0x4000ULL && !ok; o += 8) {
                uint64_t v;
                memcpy(&v, buf + o, 8);
                if (v != gworld) continue;
                uint64_t hit = page + o;
                for (size_t d = 0; d < UD_ARR_LEN(gUDStride) && !ok; d++) {
                    uint32_t s = gUDStride[d];
                    for (size_t e = 0; e < UD_ARR_LEN(gUDObjOff) && !ok; e++) {
                        uint32_t off = gUDObjOff[e];
                        if (off >= s) continue;           // 8 字节数组只有 +0
                        // 注意：不做 (hit-off)%s 整除检查——数组基址只保证
                        // 16 字节对齐，stride 非 2 的幂（0x18/0x28）时基址
                        // %s ≠ 0，整除检查会误杀真实命中（第五轮已踩坑）
                        uint64_t base = hit - off - (uint64_t)gworldIdx * s;
                        if (base > hit || base < 0x100000000ULL) continue; // 回绕
                        if (base & 0xF) continue;         // malloc 16 字节对齐
                        // 验证：头 6 项 ≥4 个合法 UObject，且 idx+1 邻居合法
                        int good = 0;
                        for (int k = 0; k < 6; k++) {
                            if (ud_is_named_uobject(ud_kread64(base + (uint64_t)k * s + off)))
                                good++;
                        }
                        uint64_t nb = ud_kread64(base + (uint64_t)(gworldIdx + 1) * s + off);
                        if (good >= 4 && ud_is_named_uobject(nb)) {
                            *baseOut = base; *strideOut = s; *objOffOut = off;
                            ok = true;
                        }
                    }
                }
            }
        }
    }
    free(regs); free(buf);
    return ok;
}

// 值扫描第二步：在主映像 __DATA 各 section 搜指向对象数组的指针
static bool ud_find_gobjects_by_value(uint32_t gworldIdx, uint64_t gworld,
                                      uint64_t *foundOut) {
    uint64_t base = 0; uint32_t s = 0, o = 0;
    if (!ud_value_scan_find_array(gworldIdx, gworld, &base, &s, &o)) {
        UD_LOG("值扫描未找到对象数组（分块容器此法无效），转 section 扫描");
        return false;
    }
    UD_LOG("值扫描命中数组 base=0x%llx（stride=0x%x obj@+0x%x），反查全局指针…",
           (unsigned long long)base, s, o);

    UDSect sects[UD_MAX_SECTS];
    int nSects = ud_collect_data_sections(sects, UD_MAX_SECTS);
    uint8_t *buf = (uint8_t *)malloc(0x4000);
    uint64_t *hits = (uint64_t *)calloc(8, sizeof(uint64_t));
    if (!buf || !hits || nSects <= 0) { free(buf); free(hits); return false; }

    __block int nHits = 0;
    for (int i = 0; i < nSects && nHits < 8; i++) {
        const uint64_t lo = sects[i].addr, hi = sects[i].addr + sects[i].size;
        vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
            if (nHits >= 8 || end <= lo || start >= hi) return;
            uint64_t page = start & ~0x3FFFULL;
            if (page < lo) page = lo & ~0x3FFFULL;
            for (; page < end && page < hi && nHits < 8; page += 0x4000ULL) {
                ud_kread_best_effort(page, buf, 0x4000);
                for (uint64_t o2 = 0; o2 + 8 <= 0x4000ULL; o2 += 8) {
                    uint64_t v;
                    memcpy(&v, buf + o2, 8);
                    if (v == base) {
                        hits[nHits++] = page + o2;
                        if (nHits >= 8) { *stop = YES; return; }
                    }
                }
            }
        });
    }
    free(buf);
    if (nHits == 0) {
        UD_LOG("全局指针反查未命中（可能为分块容器），转 section 扫描");
        free(hits);
        return false;
    }

    for (int h = 0; h < nHits; h++) {
        UD_LOG("全局指针候选 0x%llx（base+0x%llx）",
               (unsigned long long)hits[h], (unsigned long long)(hits[h] - gBase));
        for (size_t ai = 0; ai < UD_ARR_LEN(gUDInner); ai++) {
            uint64_t V = hits[h] - gUDInner[ai]; // 使 V + inner == 命中地址
            if (ud_gobjects_confirms(V, gworldIdx, gworld)) {
                *foundOut = V;
                free(hits);
                return true;
            }
            // Num 槽位未知时的兜底：V..V+0x40 找「Num>gworldIdx 且后邻 ≥ Num」
            // 的相邻对，配合值扫描实证的 (flat, s, o) 做弱锁定
            for (uint32_t noff = gUDInner[ai]; noff <= 0x38; noff += 4) {
                int32_t numE = (int32_t)ud_kread32(V + noff);
                int32_t maxE = (int32_t)ud_kread32(V + noff + 4);
                if (numE > (int32_t)gworldIdx && numE <= 0x1000000 &&
                    maxE >= numE && maxE <= 0x1000000) {
                    if (ud_oa_item_at(ud_kread64(V + gUDInner[ai]), gworldIdx, 0, s, o) == gworld) {
                        gOA.innerOff = gUDInner[ai];
                        gOA.numOff = noff - gUDInner[ai];
                        gOA.chunkShift = 0;
                        gOA.itemStride = s;
                        gOA.itemObjOff = o;
                        gOA.weakAnchor = true;
                        *foundOut = V;
                        UD_LOG("值扫描弱锁定（Num 启发式 @+0x%x：Num=%d）", noff, numE);
                        free(hits);
                        return true;
                    }
                }
            }
        }
    }
    free(hits);
    return false;
}

static bool ud_find_gobjects(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (UE.offGObjects == 0) {
        NSInteger saved = [d integerForKey:kUDGObjectsOffKey];
        if (saved > 0) UE.offGObjects = (uint32_t)saved;
    }

    uint32_t gworldIdx = ud_kread32(gGWorld + UE.uobjIndex);
    if (gworldIdx == 0 || gworldIdx > 0x2000000) {
        ud_fail([NSString stringWithFormat:@"GWorld InternalIndex 异常（0x%x）", gworldIdx]);
        return false;
    }
    UD_LOG("GWorld InternalIndex=%u，开始定位 GUObjectArray", gworldIdx);
    gUDNearMiss = 0;

    if (UE.offGObjects != 0) {
        if (ud_gobjects_confirms(gBase + UE.offGObjects, gworldIdx, gGWorld)) {
            gGObjects = gBase + UE.offGObjects;
            UD_LOG("GUObjectArray 命中记忆偏移 0x%x（ObjObjects@+0x%x Num@+0x%x %s）",
                   UE.offGObjects, gOA.innerOff, gOA.numOff, ud_oa_desc());
            return true;
        }
        UD_LOG("记忆偏移 0x%x 校验失败，重新扫描", UE.offGObjects);
    }

    // ---- 定位 ----
    // 第 0 优先：值扫描——堆里直接搜 GWorld 指针所在的数组槽位，反推数组
    // 基址后回 __DATA 反查全局指针。不依赖 Num/Max 槽位猜测（第四轮主攻）。
    uint64_t found = 0;
    if (!ud_find_gobjects_by_value(gworldIdx, gGWorld, &found)) {
        // 第 1 优先：GWorld 全局附近 ±1MB（GUObjectArray/GEngine 通常与其
        // 链接相邻；配合 memo 化确认，2MB 窗口秒级）
        const uint64_t gwAbs = gBase + UE.offGWorld;
        UD_LOG("优先扫描 GWorld 全局附近 [0x%llx, 0x%llx)…",
               (unsigned long long)(gwAbs - 0x100000), (unsigned long long)(gwAbs + 0x100000));
        ud_scan_range_for_gobjects(gwAbs - 0x100000, gwAbs + 0x100000,
                                   gworldIdx, gGWorld, &found);

        // 第 2 优先：远程解析主映像 Mach-O，逐 section 扫描全部 __DATA* 段
        // （含 __bss/__common），按「距 GNames / GWorld 全局的最小距离」从近
        // 到远扫；解析失败回退窗口。
        UDSect sects[UD_MAX_SECTS];
        int nSects = ud_collect_data_sections(sects, UD_MAX_SECTS);
        if (nSects > 0) {
            UD_LOG("主映像解析到 %d 个 __DATA* section（按距 GNames/GWorld 距离近 → 远）", nSects);
            for (int i = 0; i < nSects && !found; i++) {
                UD_LOG("扫描 %s [0x%llx, 0x%llx)（%llu MB）…",
                       sects[i].name,
                       (unsigned long long)sects[i].addr,
                       (unsigned long long)(sects[i].addr + sects[i].size),
                       (unsigned long long)(sects[i].size >> 20));
                ud_scan_range_for_gobjects(sects[i].addr, sects[i].addr + sects[i].size,
                                           gworldIdx, gGWorld, &found);
            }
        } else if (!found) {
            UD_LOG("Mach-O section 解析失败，回退 GNames 附近窗口扫描");
            const uint64_t scanLoOff = (UE.offGNames > 0x4000000) ? (UE.offGNames - 0x4000000) : 0;
            const uint64_t scanHiOff = (uint64_t)UE.offGNames + 0x2000000;
            UD_LOG("扫描 [0x%llx, 0x%llx)（约 %llu MB）…",
                   (unsigned long long)(gBase + scanLoOff), (unsigned long long)(gBase + scanHiOff),
                   (unsigned long long)((scanHiOff - scanLoOff) >> 20));
            ud_scan_range_for_gobjects(gBase + scanLoOff, gBase + scanHiOff,
                                       gworldIdx, gGWorld, &found);
        }
    }
    ud_page_cache_flush(); // 扫描产生大量一次性映射，回收
    if (gUDMapFail > 0) {
        UD_LOG("页映射失败 %ld 次（内核通道不稳时读到全零，可能漏掉真身——建议重跑）",
               gUDMapFail);
    }
    if (gUDNearMissJunk > 0) {
        UD_LOG("另有 %ld 个低价值近失（Num 形似字节花纹，已忽略）", gUDNearMissJunk);
    }

    if (!found) {
        ud_fail(@"GUObjectArray 自动扫描未命中（值扫描 + 全部 __DATA section 均未命中）——把控制台日志发回分析，或手动填 UE.offGObjects");
        return false;
    }
    gGObjects = found;
    UE.offGObjects = (uint32_t)(found - gBase);
    [d setInteger:UE.offGObjects forKey:kUDGObjectsOffKey];
    UD_LOG("GUObjectArray=0x%llx（base+0x%x，ObjObjects@+0x%x Num@+0x%x，%s，已记忆）",
           (unsigned long long)found, UE.offGObjects, gOA.innerOff, gOA.numOff, ud_oa_desc());
    return true;
}

// ============================================================
// UStruct 布局代际校准（锚点：World 的 SuperStruct 类名必须是 "Object"）
// ============================================================
// iOS_UEDumper 的 PUBG 画像 = UE4.18/19：SuperStruct@+0x30、无 FField、
// 旧式 UProperty 挂 Children；UE4.23+ = SuperStruct@+0x40、FField 链。
// 运行时锚点判定，命中旧式则切换整套字段偏移，避免 SDK 全盘错位。
static void ud_calibrate_struct_layout(void) {
    uint64_t worldCls = ud_kread64(gGWorld + UE.uobjClass);
    if (!ud_userland(worldCls)) return;

    for (int gen = 0; gen < 2; gen++) {
        uint32_t superOff = (gen == 0) ? UE.ustructSuper : 0x30; // 先验证当前默认，再试 4.18
        if (superOff != 0x30 && superOff != 0x40) continue;
        uint64_t super = ud_kread64(worldCls + superOff);
        if (!ud_userland(super)) continue;
        const char *n = ud_obj_name(super);
        if (!n || strcmp(n, "Object") != 0) continue;

        if (superOff == 0x30) {
            // UE4.18/19 旧式布局（iOS_UEDumper PUBG 画像公式）
            UE.ustructSuper = 0x30;
            UE.ustructChildren = 0x38;
            UE.ustructChildProps = 0;   // 无 FField，属性挂 Children
            UE.ustructSize = 0x40;
            UE.fpropArrayDim = 0x30;    // 旧式 UProperty::ArrayDim
            UE.fpropOffset = 0x44;      // 旧式 UProperty::Offset_Internal
            UE.ufuncExec = 0xB0;        // 旧式 UFunction::Func
            UD_LOG("UStruct 布局 = UE4.18/19 旧式（SuperStruct@+0x30 ✓，无 FField）");
            return;
        }

        // SuperStruct@+0x40：区分 4.20-22（旧式 UProperty 挂 Children）与 4.23+（FField）
        UD_LOG("UStruct 布局 = UE4.23+（SuperStruct@+0x40 ✓）");
        uint64_t ch = ud_kread64(worldCls + UE.ustructChildren);
        int nProp = 0, nChild = 0;
        while (ud_userland(ch) && nChild < 16) {
            uint64_t c = ud_kread64(ch + UE.uobjClass);
            const char *cn = ud_userland(c) ? ud_obj_name(c) : NULL;
            if (cn) {
                if (nChild < 6) {
                    const char *chName = ud_obj_name(ch);
                    UD_LOG("World 类 Child[%d] = %s（%s）", nChild,
                           chName ? chName : "?", cn);
                }
                if (strstr(cn, "Property")) nProp++;
            }
            ch = ud_kread64(ch + UE.ufieldNext);
            nChild++;
        }
        if (nProp > 0) {
            // UE4.20-22：SuperStruct 同 4.23 位置，但属性仍是旧式 UProperty
            UE.ustructChildProps = 0;
            UE.ustructSize = 0x50;
            UE.fpropArrayDim = 0x30;
            UE.fpropOffset = 0x44;
            UE.ufuncExec = 0xC0;
            UD_LOG("UStruct 布局修正 = UE4.20-22（Children 上发现旧式 UProperty）");
        }
        return;
    }
    UD_LOG("UStruct SuperStruct 锚点未命中 Object（保持 4.25 公式，SDK 字段可能不准）");
}

// ============================================================
// 类型映射（属性类名 → C++ 类型，用于 SDK.hpp）
// ============================================================
static void ud_type_for_prop_class(const char *cls, char *out, size_t cap) {
    if (!strcmp(cls, "FloatProperty")) snprintf(out, cap, "float");
    else if (!strcmp(cls, "DoubleProperty")) snprintf(out, cap, "double");
    else if (!strcmp(cls, "IntProperty")) snprintf(out, cap, "int32_t");
    else if (!strcmp(cls, "Int64Property")) snprintf(out, cap, "int64_t");
    else if (!strcmp(cls, "UInt32Property")) snprintf(out, cap, "uint32_t");
    else if (!strcmp(cls, "UInt64Property")) snprintf(out, cap, "uint64_t");
    else if (!strcmp(cls, "UInt16Property")) snprintf(out, cap, "uint16_t");
    else if (!strcmp(cls, "Int16Property")) snprintf(out, cap, "int16_t");
    else if (!strcmp(cls, "UInt8Property")) snprintf(out, cap, "uint8_t");
    else if (!strcmp(cls, "Int8Property")) snprintf(out, cap, "int8_t");
    else if (!strcmp(cls, "ByteProperty")) snprintf(out, cap, "uint8_t");
    else if (!strcmp(cls, "BoolProperty")) snprintf(out, cap, "uint8_t");
    else if (!strcmp(cls, "ObjectProperty") || !strcmp(cls, "ClassProperty") ||
             !strcmp(cls, "WeakObjectProperty") || !strcmp(cls, "LazyObjectProperty") ||
             !strcmp(cls, "SoftObjectProperty") || !strcmp(cls, "SoftClassProperty") ||
             !strcmp(cls, "InterfaceProperty") || !strcmp(cls, "AssetObjectProperty"))
        snprintf(out, cap, "class UObject*");
    else if (!strcmp(cls, "NameProperty")) snprintf(out, cap, "struct FName");
    else if (!strcmp(cls, "StrProperty")) snprintf(out, cap, "struct FString");
    else if (!strcmp(cls, "TextProperty")) snprintf(out, cap, "struct FText");
    else if (!strcmp(cls, "ArrayProperty")) snprintf(out, cap, "struct TArray");
    else if (!strcmp(cls, "MapProperty")) snprintf(out, cap, "struct TMap");
    else if (!strcmp(cls, "SetProperty")) snprintf(out, cap, "struct TSet");
    else if (!strcmp(cls, "StructProperty")) snprintf(out, cap, "struct FStruct");
    else if (!strcmp(cls, "EnumProperty")) snprintf(out, cap, "int32_t");
    else if (!strcmp(cls, "DelegateProperty") || !strcmp(cls, "MulticastDelegateProperty") ||
             !strcmp(cls, "MulticastInlineDelegateProperty") ||
             !strcmp(cls, "MulticastSparseDelegateProperty"))
        snprintf(out, cap, "struct FDelegate");
    else snprintf(out, cap, "uint8_t");
}

// ============================================================
// Dump 主体
// ============================================================

typedef struct {
    uint64_t addr;
    char path[512];
} UDObjRef; // 类/枚举二次遍历素材

#define UD_MAX_CLASSES 65536
#define UD_MAX_ENUMS   32768

static void ud_dump_property(FILE *sdk, uint64_t prop, bool isFField) {
    // FProperty：name@+0x28；旧式 UProperty：name@+0x18（UObject 布局）
    uint32_t nameIdx = isFField
        ? ud_kread32(prop + UE.ffieldName)
        : ud_kread32(prop + UE.uobjName);
    const char *nameBuf = ud_name_cached(nameIdx);
    if (!nameBuf) return;

    // 属性类名（FProperty 的 FFieldClass* 名字 / 旧式 UProperty 的类对象名字）
    char clsName[128];
    if (isFField) {
        uint64_t fcls = ud_kread64(prop + UE.ffieldClass);
        if (!ud_userland(fcls)) return;
        const char *cn = ud_obj_name(fcls);
        if (!cn) return;
        snprintf(clsName, sizeof(clsName), "%s", cn);
    } else {
        uint64_t c = ud_kread64(prop + UE.uobjClass);
        if (!ud_userland(c)) return;
        const char *cn = ud_obj_name(c);
        if (!cn) return;
        snprintf(clsName, sizeof(clsName), "%s", cn);
    }

    uint32_t off = ud_kread32(prop + UE.fpropOffset);
    uint32_t dim = ud_kread32(prop + UE.fpropArrayDim);
    if (dim == 0 || dim > 0x10000) dim = 1;
    char type[64];
    ud_type_for_prop_class(clsName, type, sizeof(type));

    if (!strcmp(clsName, "BoolProperty")) {
        fprintf(sdk, "    uint8_t %s; // BoolProperty 位域 @0x%04X\n", nameBuf, off);
        return;
    }
    fprintf(sdk, "    %s %s%s; // 0x%04X\n", type, nameBuf, dim > 1 ? "[]" : "", off);
}

// 生成一个函数签名注释行
static void ud_dump_function(FILE *sdk, uint64_t func) {
    const char *fname = ud_name_cached(ud_kread32(func + UE.uobjName));
    if (!fname) return;

    // 参数 = 函数的 ChildProperties（FProperty 链）；
    // UE4.22- 旧式无 FField，参数挂 Children 链（UProperty）
    char params[1024];
    params[0] = 0;
    size_t used = 0;
    if (UE.ustructChildProps == 0) {
        uint64_t lp = ud_kread64(func + UE.ustructChildren);
        while (ud_userland(lp) && used + 2 < sizeof(params)) {
            uint64_t pc = ud_kread64(lp + UE.uobjClass);
            const char *pcn = ud_userland(pc) ? ud_obj_name(pc) : NULL;
            if (!pcn || !strstr(pcn, "Property")) {
                lp = ud_kread64(lp + UE.ufieldNext); // 非属性子项（不应出现）跳过
                continue;
            }
            char pname[128] = "", pcls[64] = "";
            const char *pn = ud_name_cached(ud_kread32(lp + UE.uobjName));
            if (pn) snprintf(pname, sizeof(pname), "%s", pn);
            ud_type_for_prop_class(pcn, pcls, sizeof(pcls));
            int w = snprintf(params + used, sizeof(params) - used, "%s%s %s, ",
                             used ? "; " : "", pcls[0] ? pcls : "uint8_t", pname);
            if (w <= 0) break;
            used += (size_t)w;
            lp = ud_kread64(lp + UE.ufieldNext);
        }
    }
    uint64_t p = UE.ustructChildProps ? ud_kread64(func + UE.ustructChildProps) : 0;
    while (ud_userland(p) && used + 2 < sizeof(params)) {
        char pname[128] = "", pcls[64] = "";
        const char *pn = ud_name_cached(ud_kread32(p + UE.ffieldName));
        if (pn) snprintf(pname, sizeof(pname), "%s", pn);
        uint64_t pc = ud_kread64(p + UE.ffieldClass);
        if (ud_userland(pc)) {
            const char *pcn = ud_obj_name(pc);
            if (pcn) ud_type_for_prop_class(pcn, pcls, sizeof(pcls));
        }
        int w = snprintf(params + used, sizeof(params) - used, "%s%s %s, ",
                         used ? "; " : "", pcls[0] ? pcls : "uint8_t", pname);
        if (w <= 0) break;
        used += (size_t)w;
        p = ud_kread64(p + UE.ffieldNext);
    }
    size_t pl = strlen(params);
    while (pl > 0 && (params[pl - 1] == ' ' || params[pl - 1] == ',')) params[--pl] = 0;

    fprintf(sdk, "    // void %s(%s)\n", fname, params);
}

static void ud_dump_class(FILE *sdk, uint64_t klass) {
    char path[512];
    ud_full_path(klass, path, sizeof(path));
    uint64_t super = ud_kread64(klass + UE.ustructSuper);
    char superLeaf[256] = "UObject";
    if (ud_userland(super)) {
        char superPath[512];
        ud_full_path(super, superPath, sizeof(superPath));
        if (superPath[0]) {
            const char *leaf = strrchr(superPath, '.');
            snprintf(superLeaf, sizeof(superLeaf), "%s", leaf ? leaf + 1 : superPath);
        }
    }
    uint32_t size = ud_kread32(klass + UE.ustructSize);
    const char *leaf = strrchr(path, '.');
    leaf = leaf ? leaf + 1 : path;

    fprintf(sdk, "\n// %s\n", path);
    fprintf(sdk, "class U%s : public U%s { // Size: 0x%X\n", leaf, superLeaf, size);

    // 字段（FField 链，UE4.23+；UE4.22- 旧式无 FField，走下方 Children 的 UProperty 分支）
    uint64_t childProps = UE.ustructChildProps ? ud_kread64(klass + UE.ustructChildProps) : 0;
    int propCount = 0;
    while (ud_userland(childProps) && propCount < 0x800) {
        ud_dump_property(sdk, childProps, true);
        childProps = ud_kread64(childProps + UE.ffieldNext);
        propCount++;
    }
    // 旧式 UProperty（挂在 Children 链上，类名以 Property 结尾）
    uint64_t child = ud_kread64(klass + UE.ustructChildren);
    int legacy = 0;
    while (ud_userland(child) && legacy < 0x800) {
        uint64_t c = ud_kread64(child + UE.uobjClass);
        if (ud_userland(c)) {
            const char *cn = ud_obj_name(c);
            if (cn && strstr(cn, "Property")) ud_dump_property(sdk, child, false);
        }
        child = ud_kread64(child + UE.ufieldNext);
        legacy++;
    }
    if (propCount == 0 && legacy == 0) fprintf(sdk, "    //（无字段或字段布局待校准）\n");

    // 成员函数（Children 链上类名为 Function 的对象）
    child = ud_kread64(klass + UE.ustructChildren);
    int funcCount = 0;
    while (ud_userland(child) && funcCount < 0x800) {
        uint64_t c = ud_kread64(child + UE.uobjClass);
        if (ud_userland(c)) {
            const char *cn = ud_obj_name(c);
            if (cn && !strcmp(cn, "Function")) {
                ud_dump_function(sdk, child);
            }
        }
        child = ud_kread64(child + UE.ufieldNext);
        funcCount++;
    }
    fprintf(sdk, "};\n");
}

static void ud_dump_enum(FILE *sdk, uint64_t en) {
    char path[512];
    ud_full_path(en, path, sizeof(path));
    uint64_t arr = ud_kread64(en + UE.uenumNames);
    int32_t num = (int32_t)ud_kread32(en + UE.uenumNames + 8);
    if (!ud_userland(arr) || num <= 0 || num > 2048) {
        fprintf(sdk, "\n// %s（枚举值读取失败/布局不符）\n", path);
        return;
    }
    const char *leaf = strrchr(path, '.');
    leaf = leaf ? leaf + 1 : path;
    fprintf(sdk, "\n// %s\nenum class E%s : int64_t {\n", path, leaf);
    for (int32_t i = 0; i < num; i++) {
        uint64_t pair = arr + (uint64_t)i * 16; // TPair<FName, int64>
        const char *nbuf = ud_name_cached(ud_kread32(pair));
        if (!nbuf) continue;
        int64_t v = 0;
        ud_kreadbuf(pair + 8, &v, sizeof(v));
        fprintf(sdk, "    %s = %lld,\n", nbuf, (long long)v);
    }
    fprintf(sdk, "};\n");
}

static bool ud_dump_all(NSString *outDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *objectsPath = [outDir stringByAppendingPathComponent:@"Objects.txt"];
    NSString *offsetsPath = [outDir stringByAppendingPathComponent:@"Offsets.txt"];
    NSString *sdkPath = [outDir stringByAppendingPathComponent:@"SDK.hpp"];
    NSString *scriptPath = [outDir stringByAppendingPathComponent:@"script.json"];

    // ---- GUObjectArray 概要（复核并锁定布局）----
    uint32_t gworldIdx = ud_kread32(gGWorld + UE.uobjIndex);
    if (!ud_gobjects_confirms(gGObjects, gworldIdx, gGWorld)) {
        ud_fail(@"GUObjectArray 复核失败（状态变化）");
        return false;
    }
    ud_calibrate_struct_layout(); // UStruct 代际校准（4.18 / 4.20-22 / 4.23+）
    int32_t numE = ud_uobject_count();
    if (numE <= 0 || numE > 0x1000000) { ud_fail(@"GUObjectArray Num 异常"); return false; }
    UD_LOG("开始遍历 %d 个对象…", numE);

    // 类/枚举收集（堆分配；函数直接流式写 script.json，不驻留内存）
    UDObjRef *classes = (UDObjRef *)calloc(UD_MAX_CLASSES, sizeof(UDObjRef));
    UDObjRef *enums = (UDObjRef *)calloc(UD_MAX_ENUMS, sizeof(UDObjRef));
    int nClasses = 0, nEnums = 0;

    FILE *objs = fopen(objectsPath.fileSystemRepresentation, "w");
    FILE *script = fopen(scriptPath.fileSystemRepresentation, "w");
    if (!objs || !classes || !enums) {
        if (objs) fclose(objs);
        if (script) fclose(script);
        free(classes); free(enums);
        ud_fail(@"无法写输出文件或内存不足");
        return false;
    }
    fprintf(script, "[\n");
    int firstFunc = 1;
    int dumped = 0, nFuncs = 0;

    for (int32_t i = 0; i < numE; i++) {
        uint64_t item = ud_uobject_at((uint32_t)i);
        if (!ud_userland(item)) continue;

        // 类名先拷贝到本地缓冲：ud_obj_name 返回循环缓冲，
        // 后面 ud_full_path 会再次调用它（链上最多 10 次）导致覆盖串名
        uint64_t cls = ud_kread64(item + UE.uobjClass);
        char cnBuf[352] = "";
        const char *cnRaw = ud_userland(cls) ? ud_obj_name(cls) : NULL;
        if (cnRaw) snprintf(cnBuf, sizeof(cnBuf), "%s", cnRaw);
        const char *cn = cnBuf[0] ? cnBuf : NULL;

        char path[512];
        ud_full_path(item, path, sizeof(path));
        if (!path[0]) continue;

        fprintf(objs, "0x%llx [%s] %s\n", (unsigned long long)item, cn ? cn : "?", path);
        dumped++;

        if (cn) {
            if (!strcmp(cn, "Class") || !strcmp(cn, "BlueprintGeneratedClass")) {
                if (nClasses < UD_MAX_CLASSES) {
                    classes[nClasses].addr = item;
                    snprintf(classes[nClasses].path, sizeof(classes[0].path), "%s", path);
                    nClasses++;
                }
            } else if (!strcmp(cn, "Function")) {
                uint64_t fn = ud_kread64(item + UE.ufuncExec);
                if (ud_userland(fn)) {
                    fprintf(script, "%s{\"Name\":\"%s\",\"Address\":\"0x%llx\"}",
                            firstFunc ? "" : ",", path, (unsigned long long)fn);
                    firstFunc = 0;
                    nFuncs++;
                }
            } else if (!strcmp(cn, "Enum")) {
                if (nEnums < UD_MAX_ENUMS) {
                    enums[nEnums].addr = item;
                    snprintf(enums[nEnums].path, sizeof(enums[0].path), "%s", path);
                    nEnums++;
                }
            }
        }

        if ((i & 0xFFFF) == 0) UD_LOG("遍历进度 %d / %d", i, numE);
    }
    fclose(objs);
    fprintf(script, "\n]\n");
    fclose(script);

    UD_LOG("对象 %d 个；类 %d，函数 %d，枚举 %d", dumped, nClasses, nFuncs, nEnums);

    // ---- Offsets.txt ----
    FILE *offs = fopen(offsetsPath.fileSystemRepresentation, "w");
    if (!offs) {
        free(classes); free(enums);
        ud_fail(@"无法写 Offsets.txt");
        return false;
    }
    fprintf(offs, "DumpTime: %s\n", [[NSDate date] description].UTF8String ? [[NSDate date] description].UTF8String : "");
    fprintf(offs, "ImageBase: 0x%llx\n", (unsigned long long)gBase);
    fprintf(offs, "GWorld: 0x%llx (base + 0x%x)\n", (unsigned long long)gGWorld, UE.offGWorld);
    fprintf(offs, "GNames: 0x%llx (base + 0x%x, 定制 TNameEntryArray, indexMode=%d)\n",
            (unsigned long long)gGNames, UE.offGNames, gNameIndexMode);
    fprintf(offs, "GUObjectArray: 0x%llx (base + 0x%x, ObjObjects@+0x%x Num@+0x%x %s)\n",
            (unsigned long long)gGObjects, UE.offGObjects, gOA.innerOff, gOA.numOff, ud_oa_desc());
    fprintf(offs, "ObjectCount: %d\n", numE);
    fclose(offs);

    // ---- SDK.hpp ----
    FILE *sdk = fopen(sdkPath.fileSystemRepresentation, "w");
    if (!sdk) {
        free(classes); free(enums);
        ud_fail(@"无法写 SDK.hpp");
        return false;
    }
    fprintf(sdk, "// Generated by Rein UESDumper @ %s\n", [[NSDate date] description].UTF8String);
    fprintf(sdk, "// 类 %d / 函数 %d / 枚举 %d\n", nClasses, nFuncs, nEnums);
    fprintf(sdk, "#pragma once\n#include <cstdint>\n");

    UD_LOG("生成 SDK.hpp（类定义）…");
    for (int i = 0; i < nClasses; i++) {
        ud_dump_class(sdk, classes[i].addr);
        if ((i & 0x3FF) == 0) UD_LOG("SDK 进度 %d / %d", i, nClasses);
    }
    UD_LOG("生成 SDK.hpp（枚举）…");
    for (int i = 0; i < nEnums; i++) {
        ud_dump_enum(sdk, enums[i].addr);
    }
    fclose(sdk);

    free(classes);
    free(enums);
    gUDOutput = outDir;
    return true;
}

// ============================================================
// 公共入口
// ============================================================
void UESDumperStart(void) {
    if (gUDRunning) return;

    gUDRunning = true;
    gUDError = @"";
    gUDOutput = @"";
    gBase = 0; gGWorld = 0; gGObjects = 0; gGNames = 0;
    gNameIndexMode = 1;
    gOA.innerOff = 0x10; gOA.numOff = 0x14; gOA.chunkShift = 16;
    gOA.itemStride = 0x18; gOA.itemObjOff = 0; gOA.weakAnchor = false;
    gUDNearMiss = 0; gUDNearMissLastV = 0; gUDMapFail = 0; gUDNearMissJunk = 0;
    gUDSkippedBig = 0;
    gOAMemo.V = 0;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UD_LOG("=== UE4 SDK dump 开始（内核读，无需注入/RemoteCall）===");

            BOOL ok = NO;
            NSString *outDir = @"";
            @try {
                if (!ReinKernelIsReady()) {
                    ud_fail(@"请先在「内核」页初始化 DarkSword 内核");
                } else if (ud_attach_game() && ud_find_gobjects()) {
                    outDir = [NSHomeDirectory()
                        stringByAppendingPathComponent:@"Documents/SDK"];
                    ok = ud_dump_all(outDir);
                }
            } @catch (NSException *exception) {
                // 顶层兜底：内核层任何未预期的异常都不允许崩掉 App
                ud_fail([NSString stringWithFormat:@"Dump 异常：%@（%@）",
                         exception.name, exception.reason]);
            }

            ud_page_cache_flush();
            ud_name_cache_free();
            gVMMap = 0;

            if (ok) {
                UD_LOG("=== dump 完成：%@（通过 Files app 的 Rein 目录查看）===", outDir);
            }
            gUDRunning = false;
        }
    });
}
