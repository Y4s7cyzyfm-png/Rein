//
//  UESDumper.mm
//  Rein
//
//  UE4 SDK Dumper（内核远程读版）
//
//  移植自 MJx0/iOS_UEDumper（MIT）的思路：通过 GNames(FNamePool) +
//  GUObjectArray(TUObjectArray) 遍历 UE4 反射系统，生成 SDK。
//  区别：iOS_UEDumper 是注入游戏的 tweak（本地读内存）；本模块用
//  DarkSword 内核的 vmmapremotepage 远程页映射读取游戏内存，
//  只需游戏正在运行，不动游戏进程，也不依赖 RemoteCall。
//
//  所有 UE 结构偏移集中在下方「UE 偏移配置」区——随游戏版本更新
//  改那里即可（对照 Objects.txt / IDA）。
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
// 主映像全局默认值取自 PeaceESP.mm 已验证的 O_GWORLD / O_GNAME；
// 结构偏移取 stock UE4.25 布局。ShadowTrackerExtra 是深度定制引擎，
// 结构偏移可能不符——不符时 Objects.txt / Offsets.txt 仍然可靠，
// SDK.hpp 的字段以这里的配置修正为准。
static struct {
    // ---- 主映像内全局（base + offset 处存放指针）----
    uint32_t offGWorld;      // GWorld 全局
    uint32_t offGNames;      // GNames / FNamePool 全局
    uint32_t offGObjects;    // GUObjectArray 全局；0 = 自动扫描（找到后自动记忆）

    // ---- UObject ----
    uint32_t uobjName;       // FName（comparison index，int32）
    uint32_t uobjClass;      // ClassPrivate 指针
    uint32_t uobjOuter;      // OuterPrivate 指针
    uint32_t uobjIndex;      // InternalIndex（int32）

    // ---- UStruct / UField（UE4.23+）----
    uint32_t ufieldNext;     // UField::Next
    uint32_t ustructSuper;   // UStruct::SuperStruct
    uint32_t ustructChildren;// UStruct::Children
    uint32_t ustructChildProps; // UStruct::ChildProperties（FField 链）
    uint32_t ustructSize;    // UStruct::PropertiesSize

    // ---- FProperty（UE4.23+ FField）----
    uint32_t ffieldClass;    // FField::ClassPrivate（FFieldClass*）
    uint32_t ffieldName;    // FField::NamePrivate（FName index）
    uint32_t ffieldNext;    // FField::Next
    uint32_t fpropArrayDim;
    uint32_t fpropOffset;    // FProperty::Offset_Internal

    // ---- UEnum / UFunction ----
    uint32_t uenumNames;     // UEnum::Names（TArray）
    uint32_t ufuncExec;      // UFunction::Func（native 函数指针）
} UE = {
    0x1148B608,  // offGWorld
    0x11FBA198,  // offGNames
    0,           // offGObjects：自动扫描

    0x08, 0x10, 0x18, 0x04, // UObject（NamePrivate@0x08 Class@0x10 Outer@0x18 InternalIndex@0x04）

    0x20, 0x28, 0x30, 0x38, 0x40, // UStruct

    0x00, 0x08, 0x18, 0x20, 0x4C, // FField/FProperty

    0x30, 0xB8, // UEnum / UFunction
};

static NSString * const kUDGObjectsOffKey = @"rein.uesdumper.gobjectsOff";

// ============================================================
// 远程读层（vm_object 页映射 + 开放寻址页缓存；独立于 PeaceESP，
// 两者各自维护缓存互不干扰——同页会被各映射一份，只影响少量内存）
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
static uint16_t ud_kread16(uint64_t va) { uint16_t v = 0; ud_kreadbuf(va, &v, 2); return v; }

static bool ud_userland(uint64_t p) { return p >= 0x100000000ULL && p < 0x800000000ULL; }

// ============================================================
// FName 名字池（UE4.23+ FNamePool）
// ============================================================
// FNamePool { Lock(8) CurrentBlock(4) CurrentByteCursor(4) Blocks[8192] }
// Block 大小 0x10000；Entry { uint16 头(低1位wide, 高15位长度) char 数据[] }
static uint64_t gGNames = 0;
static uint32_t gBlocksOff = 0x10; // FNamePool 内 Blocks 数组偏移（诊断可自适应修正）

// 按指定 Blocks 内偏移尝试解析名字（诊断/自适应用）
static bool ud_name_try_inner(uint32_t inner, uint32_t idx, char *out, size_t cap) {
    if (!gGNames || !out || cap == 0) return false;
    uint32_t block = idx >> 16;
    uint32_t off = idx & 0xFFFF;
    if (block >= 8192) return false;
    uint64_t blockPtr = ud_kread64(gGNames + inner + (uint64_t)block * 8);
    if (!ud_userland(blockPtr)) return false;
    uint16_t header = ud_kread16(blockPtr + off);
    size_t len = header >> 1;
    bool wide = header & 1;
    if (len == 0 || len >= 1024 || len + 1 > cap) return false;
    if (wide) {
        // 宽字符名（游戏里几乎都是窄的）：降级取低字节
        uint16_t w[512];
        if (len > 511) return false;
        if (!ud_kreadbuf(blockPtr + off + 2, w, len * 2)) return false;
        for (size_t i = 0; i < len; i++) {
            out[i] = (w[i] < 128 && w[i] >= 32) ? (char)w[i] : '?';
        }
        out[len] = 0;
    } else {
        if (!ud_kreadbuf(blockPtr + off + 2, out, len)) return false;
        out[len] = 0;
    }
    // 可打印性校验（防偏移错位读到垃圾）
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)out[i];
        if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
}

static bool ud_name_from_index(uint32_t idx, char *out, size_t cap) {
    return ud_name_try_inner(gBlocksOff, idx, out, cap);
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
    char buf[1024];
    if (!ud_name_from_index(idx, buf, sizeof(buf))) return NULL; // 不缓存失败，直接返回
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

// 对象名（UObject）
static const char *ud_obj_name(uint64_t obj) {
    return ud_name_cached(ud_kread32(obj + UE.uobjName));
}

// 完整路径（沿 Outer 链向上拼；深度限 10 防环）
static void ud_full_path(uint64_t obj, char *out, size_t cap) {
    out[0] = 0;
    if (!ud_userland(obj)) return;
    char parts[12][256];
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

// 指定地址起 16 字节的十六进制串（诊断用）
static NSString *ud_hex16(uint64_t addr) {
    uint8_t b[16];
    if (!ud_kreadbuf(addr, b, sizeof(b))) return @"<读取失败>";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

/// GNames 自检失败时的诊断 + 自适应：
/// 1) 打印名字池头部原始内存——离线区分「offGNames 错 / 布局不符 / 名字加密」：
///    - pool 头部本身像随机值        → offGNames 有误
///    - blocks[0] 指向的 16 字节乱码 → 名字数据被加密（需要专门解密）
///    - 某个候选内偏移能对上         → FNamePool 布局与 stock 不同
/// 2) 依次尝试常见 Blocks 内偏移，GWorld 名与 entry0 都能解码则采纳并继续 dump。
///    返回 YES 表示已自适应成功（调用方可继续）。
static bool ud_gnames_diagnose(void) {
    UD_LOG_ERROR("── GNames 诊断开始 ──");
    UD_LOG("pool=0x%llx GWorld: NameIdx=0x%x Number=0x%x InternalIndex=0x%x",
           (unsigned long long)gGNames,
           ud_kread32(gGWorld + UE.uobjName), ud_kread32(gGWorld + UE.uobjName + 4),
           ud_kread32(gGWorld + UE.uobjIndex));
    for (int i = 0; i < 6; i++) {
        UD_LOG("pool+0x%02x = 0x%016llx", i * 8,
               (unsigned long long)ud_kread64(gGNames + (uint64_t)i * 8));
    }

    static const uint32_t kInners[] = {0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x50, 0x60, 0x80, 0xC0};
    uint32_t widx = ud_kread32(gGWorld + UE.uobjName);
    for (size_t k = 0; k < sizeof(kInners) / sizeof(kInners[0]); k++) {
        uint32_t inner = kInners[k];
        uint64_t b0 = ud_kread64(gGNames + inner);
        if (!ud_userland(b0)) continue;
        UD_LOG("候选 Blocks@+0x%02x：blocks[0]=0x%llx 首16字节：%@",
               inner, (unsigned long long)b0, ud_hex16(b0));

        // 双重校验：GWorld 的名字与 entry0（stock UE 里第一个名字是 "None"）
        char n1[256], n2[256];
        if (ud_name_try_inner(inner, widx, n1, sizeof(n1)) &&
            ud_name_try_inner(inner, 0, n2, sizeof(n2))) {
            gBlocksOff = inner;
            UD_LOG("→ 该候选可解码：GWorld 名=%s，entry0=%s（采用 Blocks@+0x%02x，继续 dump）",
                   n1, n2, inner);
            UD_LOG_ERROR("── GNames 诊断结束：布局已自适应 ──");
            return true;
        }
    }
    UD_LOG_ERROR("── GNames 诊断结束：所有候选均失败——把上面整段日志发回分析 ──");
    return false;
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

    gGNames = ud_kread64(gBase + UE.offGNames);
    if (!ud_userland(gGNames)) { ud_fail(@"GNames 无效（offGNames 可能过期）"); return false; }
    // 名字池自检：解析 GWorld 对象自身的名字
    char nameBuf[256];
    uint32_t wnameIdx = ud_kread32(gGWorld + UE.uobjName);
    if (!ud_name_from_index(wnameIdx, nameBuf, sizeof(nameBuf))) {
        // stock 布局解析失败：先诊断（可能自动适配成功），不行才报错
        if (!ud_gnames_diagnose()) {
            ud_fail(@"GNames 名字解析失败（详见上方诊断日志：offGNames 有误 / 布局不符 / 名字加密）");
            return false;
        }
    } else {
        UD_LOG("GNames OK（GWorld 对象名 = %s）", nameBuf);
    }
    return true;
}

// ============================================================
// GUObjectArray 定位（自动扫描，找到后记忆到 NSUserDefaults）
// ============================================================
// TUObjectArray { FUObjectItem** Objects; int32 Max; int32 Num; int32 MaxChunks; int32 NumChunks; }
// FUObjectItem = 0x18；每 chunk 64 项。
// FUObjectArray 全局里 ObjObjects 成员不一定在 0 偏移——对每个候选值
// 依次尝试 {0, 0x10, ..., 0x60} 作为 ObjObjects 在候选内的偏移。
// 确认法（强校验）：用已知 GWorld 的 InternalIndex 反查数组，命中即真。
static bool ud_gobjects_confirms(uint64_t V, uint32_t gworldIdx, uint64_t gworld,
                                 uint32_t *outInnerOff) {
    static const uint32_t kInnerOffs[] = {0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60};
    for (size_t k = 0; k < sizeof(kInnerOffs) / sizeof(kInnerOffs[0]); k++) {
        uint32_t d = kInnerOffs[k];
        uint64_t chunks = ud_kread64(V + d);
        if (!ud_userland(chunks)) continue;
        int32_t maxE = (int32_t)ud_kread32(V + d + 0x8);
        int32_t numE = (int32_t)ud_kread32(V + d + 0xC);
        if (maxE <= 0 || numE < 0x100 || numE > maxE || maxE > 0x8000000) continue;
        if ((uint32_t)numE <= gworldIdx) continue;
        uint64_t chunk = ud_kread64(chunks + (uint64_t)(gworldIdx >> 6) * 8);
        if (!ud_userland(chunk)) continue;
        uint64_t item = ud_kread64(chunk + (uint64_t)(gworldIdx & 63) * 0x18);
        if (item == gworld) {
            if (outInnerOff) *outInnerOff = d;
            return true;
        }
    }
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
        ud_fail([NSString stringWithFormat:@"GWorld InternalIndex 异常（0x%x），UObject 布局可能不符", gworldIdx]);
        return false;
    }
    UD_LOG("GWorld InternalIndex=%u，开始定位 GUObjectArray", gworldIdx);

    if (UE.offGObjects != 0) {
        uint32_t inner = 0;
        if (ud_gobjects_confirms(gBase + UE.offGObjects, gworldIdx, gGWorld, &inner)) {
            gGObjects = gBase + UE.offGObjects;
            UD_LOG("GUObjectArray 命中记忆偏移 0x%x（ObjObjects 在 +0x%x）", UE.offGObjects, inner);
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
    __block uint32_t foundInner = 0;
    vmmapiterateentries(gVMMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (found || end <= scanLo || start >= scanHi) return;
        uint64_t page = start & ~0x3FFFULL;
        for (; page < end && page < scanHi; page += 0x4000ULL) {
            uint64_t local = ud_map_remote_page(page);
            if (!local) continue;
            for (uint64_t o = 0; o < 0x4000ULL; o += 8) {
                uint64_t V = page + o; // V 必须本身是全局地址（候选 GUObjectArray）
                if (!ud_userland(V + 0x60)) continue; // 便宜的预过滤
                uint32_t inner = 0;
                if (ud_gobjects_confirms(V, gworldIdx, gGWorld, &inner)) {
                    found = V; foundInner = inner;
                    *stop = YES;
                    return;
                }
            }
        }
    });
    ud_page_cache_flush(); // 扫描产生大量一次性映射，回收

    if (!found) {
        ud_fail(@"GUObjectArray 自动扫描未命中——把控制台日志（GNames 附近条目布局）发回分析，或手动填 UE.offGObjects");
        return false;
    }
    gGObjects = found;
    UE.offGObjects = (uint32_t)(found - gBase);
    [d setInteger:UE.offGObjects forKey:kUDGObjectsOffKey];
    UD_LOG("GUObjectArray=0x%llx（base+0x%x，ObjObjects 在 +0x%x，已记忆）",
           (unsigned long long)found, UE.offGObjects, foundInner);
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
    uint32_t nameIdx = isFField
        ? ud_kread32(prop + UE.ffieldName)
        : ud_kread32(prop + UE.uobjName);
    char nameBuf[256];
    if (!ud_name_from_index(nameIdx, nameBuf, sizeof(nameBuf))) return;

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

// 生成一个函数签名注释行；fn 有效时返回 true（供 script.json 收集）
static bool ud_dump_function(FILE *sdk, uint64_t func) {
    char fname[256];
    if (!ud_name_from_index(ud_kread32(func + UE.uobjName), fname, sizeof(fname))) return false;

    // 参数 = 函数的 ChildProperties（FProperty 链）
    char params[1024];
    params[0] = 0;
    size_t used = 0;
    uint64_t p = ud_kread64(func + UE.ustructChildProps);
    while (ud_userland(p) && used + 2 < sizeof(params)) {
        char pname[128] = "", pcls[64] = "";
        ud_name_from_index(ud_kread32(p + UE.ffieldName), pname, sizeof(pname));
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
    return true;
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
        char nbuf[256];
        if (!ud_name_from_index(ud_kread32(pair), nbuf, sizeof(nbuf))) continue;
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

    // ---- GUObjectArray 概要（innerOff 复用确认逻辑）----
    uint32_t innerOff = 0;
    uint32_t gworldIdx = ud_kread32(gGWorld + UE.uobjIndex);
    if (!ud_gobjects_confirms(gGObjects, gworldIdx, gGWorld, &innerOff)) {
        ud_fail(@"GUObjectArray 复核失败（状态变化）");
        return false;
    }
    uint64_t chunksBase = ud_kread64(gGObjects + innerOff);
    if (!ud_userland(chunksBase)) { ud_fail(@"chunks 数组指针无效"); return false; }
    int32_t numE = (int32_t)ud_kread32(gGObjects + innerOff + 0xC);
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
        uint64_t chunk = ud_kread64(chunksBase + (uint64_t)(i >> 6) * 8);
        if (!ud_userland(chunk)) continue;
        uint64_t item = ud_kread64(chunk + (uint64_t)(i & 63) * 0x18);
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
    fprintf(offs, "DumpTime: %s\n", [[NSDate date] description].UTF8String);
    fprintf(offs, "ImageBase: 0x%llx\n", (unsigned long long)gBase);
    fprintf(offs, "GWorld: 0x%llx (base + 0x%x)\n", (unsigned long long)gGWorld, UE.offGWorld);
    fprintf(offs, "GNames/FNamePool: 0x%llx (base + 0x%x)\n", (unsigned long long)gGNames, UE.offGNames);
    fprintf(offs, "GUObjectArray: 0x%llx (base + 0x%x, ObjObjects 内偏移 0x%x)\n",
            (unsigned long long)gGObjects, UE.offGObjects, innerOff);
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
    fprintf(sdk, "// 注意：字段/函数布局基于 stock UE4.25 默认偏移，若与游戏不符请修 UESDumper.mm 的 UE 配置区\n");
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
