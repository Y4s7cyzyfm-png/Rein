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
//  - GUObjectArray 的 ObjObjects 内偏移 / Num 偏移 / 每 chunk 元素数
//    用组合候选自适应（GWorld 反查强校验）。
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
    struct vmshmem sh = vmmapremotepage(gVMMap, remotePage);
    if (!sh.used || !sh.localAddress) return 0;
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

static bool ud_userland(uint64_t p) { return p >= 0x100000000ULL && p < 0x800000000ULL; }

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
// 布局候选（iOS_UEDumper 公式 + 真机适配）：
//   ObjObjects 内偏移 ∈ {0x00, 0x10}；Num 偏移 ∈ {0x0C, 0x14}；
//   每 chunk 元素数 ∈ {64, 8192, 65536}；FUObjectItem = 0x18。
// 确认法（强校验）：用已知 GWorld 的 InternalIndex 反查数组，命中即真。
static struct {
    uint32_t innerOff;  // ObjObjects 在候选结构内的偏移
    uint32_t numOff;    // Num 在 TUObjectArray 内的偏移
    int chunkShift;     // 每 chunk 元素数 = 1 << chunkShift
} gOA = { 0x10, 0x14, 16 };

static bool ud_oa_try(uint64_t V, uint32_t gworldIdx, uint64_t gworld,
                       uint32_t innerOff, uint32_t numOff, int chunkShift) {
    uint64_t chunks = ud_kread64(V + innerOff);
    if (!ud_userland(chunks)) return false;
    int32_t numE = (int32_t)ud_kread32(V + innerOff + numOff);
    int32_t maxE = (int32_t)ud_kread32(V + innerOff + numOff - 4); // Max 紧邻 Num 之前
    if (numE <= 0 || numE > 0x10000000) return false;
    if (maxE < numE || maxE > 0x10000000) return false;
    if ((uint32_t)numE <= gworldIdx) return false;
    uint32_t mask = (1u << chunkShift) - 1;
    uint64_t chunk = ud_kread64(chunks + (uint64_t)(gworldIdx >> chunkShift) * 8);
    if (!ud_userland(chunk)) return false;
    uint64_t item = ud_kread64(chunk + (uint64_t)(gworldIdx & mask) * 0x18);
    return item == gworld;
}

static bool ud_gobjects_confirms(uint64_t V, uint32_t gworldIdx, uint64_t gworld) {
    static const uint32_t kInner[] = { 0x10, 0x00 };
    static const uint32_t kNum[] = { 0x14, 0x0C };
    static const int kShift[] = { 16, 13, 6 };
    for (size_t a = 0; a < sizeof(kInner) / sizeof(kInner[0]); a++) {
        for (size_t b = 0; b < sizeof(kNum) / sizeof(kNum[0]); b++) {
            for (size_t c = 0; c < sizeof(kShift) / sizeof(kShift[0]); c++) {
                if (ud_oa_try(V, gworldIdx, gworld, kInner[a], kNum[b], kShift[c])) {
                    gOA.innerOff = kInner[a];
                    gOA.numOff = kNum[b];
                    gOA.chunkShift = kShift[c];
                    return true;
                }
            }
        }
    }
    return false;
}

// 按已锁定的布局取第 idx 个 UObject
static uint64_t ud_uobject_at(uint32_t idx) {
    uint64_t chunks = ud_kread64(gGObjects + gOA.innerOff);
    if (!ud_userland(chunks)) return 0;
    uint32_t mask = (1u << gOA.chunkShift) - 1;
    uint64_t chunk = ud_kread64(chunks + (uint64_t)(idx >> gOA.chunkShift) * 8);
    if (!ud_userland(chunk)) return 0;
    return ud_kread64(chunk + (uint64_t)(idx & mask) * 0x18);
}

static int32_t ud_uobject_count(void) {
    return (int32_t)ud_kread32(gGObjects + gOA.innerOff + gOA.numOff);
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

    if (UE.offGObjects != 0) {
        if (ud_gobjects_confirms(gBase + UE.offGObjects, gworldIdx, gGWorld)) {
            gGObjects = gBase + UE.offGObjects;
            UD_LOG("GUObjectArray 命中记忆偏移 0x%x（ObjObjects@+0x%x Num@+0x%x chunk=1<<%d）",
                   UE.offGObjects, gOA.innerOff, gOA.numOff, gOA.chunkShift);
            return true;
        }
        UD_LOG("记忆偏移 0x%x 校验失败，重新扫描", UE.offGObjects);
    }

    // 扫描范围：GNames 全局附近 ±（两者同处链接数据段，通常相距不远）
    const uint64_t scanLoOff = (UE.offGNames > 0x4000000) ? (UE.offGNames - 0x4000000) : 0;
    const uint64_t scanHiOff = (uint64_t)UE.offGNames + 0x1000000;
    const uint64_t scanLo = gBase + scanLoOff, scanHi = gBase + scanHiOff;
    UD_LOG("扫描 [0x%llx, 0x%llx)（约 %llu MB）…",
           (unsigned long long)scanLo, (unsigned long long)scanHi,
           (unsigned long long)((scanHi - scanLo) >> 20));

    __block uint64_t found = 0;
    vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (found || end <= scanLo || start >= scanHi) return;
        uint64_t page = start & ~0x3FFFULL;
        for (; page < end && page < scanHi; page += 0x4000ULL) {
            uint64_t local = ud_map_remote_page(page);
            if (!local) continue;
            for (uint64_t o = 0; o < 0x4000ULL; o += 8) {
                uint64_t V = page + o; // 候选 GUObjectArray（须在映像内）
                if (!ud_userland(V)) continue;
                if (ud_gobjects_confirms(V, gworldIdx, gGWorld)) {
                    found = V;
                    *stop = YES;
                    return;
                }
            }
        }
    });
    ud_page_cache_flush(); // 扫描产生大量一次性映射，回收

    if (!found) {
        ud_fail(@"GUObjectArray 自动扫描未命中——把控制台日志发回分析，或手动填 UE.offGObjects");
        return false;
    }
    gGObjects = found;
    UE.offGObjects = (uint32_t)(found - gBase);
    [d setInteger:UE.offGObjects forKey:kUDGObjectsOffKey];
    UD_LOG("GUObjectArray=0x%llx（base+0x%x，ObjObjects@+0x%x Num@+0x%x chunk=1<<%d，已记忆）",
           (unsigned long long)found, UE.offGObjects, gOA.innerOff, gOA.numOff, gOA.chunkShift);
    return true;
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

    // 参数 = 函数的 ChildProperties（FProperty 链）
    char params[1024];
    params[0] = 0;
    size_t used = 0;
    uint64_t p = ud_kread64(func + UE.ustructChildProps);
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

    // 字段（FField 链，UE4.23+）
    uint64_t childProps = ud_kread64(klass + UE.ustructChildProps);
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
    int32_t numE = ud_uobject_count();
    if (numE <= 0 || numE > 0x10000000) { ud_fail(@"GUObjectArray Num 异常"); return false; }
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

        uint64_t cls = ud_kread64(item + UE.uobjClass);
        const char *cn = ud_userland(cls) ? ud_obj_name(cls) : NULL;
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
    fprintf(offs, "GUObjectArray: 0x%llx (base + 0x%x, ObjObjects@+0x%x Num@+0x%x chunk=1<<%d)\n",
            (unsigned long long)gGObjects, UE.offGObjects, gOA.innerOff, gOA.numOff, gOA.chunkShift);
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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UD_LOG("=== UE4 SDK dump 开始（内核读，无需注入/RemoteCall）===");

            if (!ReinKernelIsReady()) {
                ud_fail(@"请先在「内核」页初始化 DarkSword 内核");
                gUDRunning = false;
                return;
            }
            if (!ud_attach_game()) { gUDRunning = false; return; }
            if (!ud_find_gobjects()) { gUDRunning = false; return; }

            NSString *outDir = [NSHomeDirectory()
                stringByAppendingPathComponent:@"Documents/SDK"];
            BOOL ok = ud_dump_all(outDir);

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
