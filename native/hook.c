// xluau proxy + lua_pcall hook
// 本 DLL 顶替 xluau.dll，把 218 个 lua 导出转发给 xluau_real.dll（真身副本），
// 并对真身的 lua_pcall 下 5 字节 inline hook 以取得 lua_State*。
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <psapi.h>

#define TARGET_MODULE "xluau_real.dll"
#define TARGET_RVA    0xdf380    // lua_pcall 的预期 RVA，仅用于校验与日志
#define PATCH_LEN     5          // mov %rbx,0x8(%rsp)

/* Naked 汇编按符号名访问。trampoline 在入口跳转可见前发布。 */
void* volatile g_tramp = NULL;

static char   g_log[MAX_PATH];
static char   g_dir[MAX_PATH];
static volatile LONG g_request = 0;
static volatile LONG g_done = 0;

typedef int  (*fn_ls)(void* L, const char* s);
typedef int  (*fn_pcall)(void* L, int na, int nr, int eh);
typedef int  (*fn_gettop)(void* L);
typedef void (*fn_settop)(void* L, int i);
typedef const char* (*fn_tolstring)(void* L, int i, size_t* len);

static fn_ls        p_ls     = NULL;
static fn_pcall     p_pcall  = NULL;
static fn_gettop    p_gettop = NULL;
static fn_settop    p_settop = NULL;
static fn_tolstring p_tostr  = NULL;

static void wlog(const char* s) {
    FILE* f = fopen(g_log, "a");
    if (f) { fprintf(f, "%s\n", s); fclose(f); }
}
static void wlogf(const char* fmt, ...) {
    char b[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    wlog(b);
}

// worker 与 Lua 回调共享一份脚本。所有权和请求在同一把非阻塞锁下移交。
#define SCRIPT_LIMIT (256u * 1024u)
#define REV_PREFIX_CAP 64u

volatile LONG g_pending = 0; // naked 汇编仅用于快速跳过无工作调用
static volatile LONG g_in_lua = 0;
static char* g_script = NULL;
static unsigned long long g_revision = 0; // 仅 worker 读写

static int script_try_lock(void) {
    return InterlockedCompareExchange(&g_in_lua, 1, 0) == 0;
}

static void script_unlock(void) {
    InterlockedExchange(&g_in_lua, 0);
}

static LONG request_locked(void) {
    LONG req = InterlockedIncrement(&g_request);
    if (!req) req = InterlockedIncrement(&g_request); // 0 保留为无请求
    InterlockedExchange(&g_pending, req);
    return req;
}

static LONG completed_request(void) {
    return InterlockedCompareExchange(&g_done, 0, 0);
}

// 成功时接管 staged，并将同一次发布与请求绑定；失败时调用方仍持有 staged。
static LONG script_publish(char* staged) {
    if (!script_try_lock()) return 0;
    if (InterlockedCompareExchange(&g_pending, 0, 0)) {
        script_unlock();
        return 0;
    }
    char* old = g_script;
    g_script = staged;
    ++g_revision;
    LONG req = request_locked();
    script_unlock();
    free(old);
    return req;
}

static void request_periodic(void) {
    if (!script_try_lock()) return;
    if (g_script && !InterlockedCompareExchange(&g_pending, 0, 0)) request_locked();
    script_unlock();
}

static char* script_read(const char* path, size_t* source_len) {
    FILE* f = fopen(path, "rb");
    if (!f) { wlog("script open failed, retry next tick"); return NULL; }
    char* staged = (char*)malloc(REV_PREFIX_CAP + SCRIPT_LIMIT + 1u);
    if (!staged) { fclose(f); wlog("script allocation failed"); return NULL; }

    int prefix = snprintf(staged, REV_PREFIX_CAP, "local __equipbar_revision = %llu\n",
                          g_revision + 1);
    if (prefix < 0 || (size_t)prefix >= REV_PREFIX_CAP) {
        fclose(f);
        free(staged);
        wlog("script revision header failed");
        return NULL;
    }
    size_t n = fread(staged + prefix, 1, SCRIPT_LIMIT + 1u, f);
    int read_error = ferror(f);
    fclose(f);
    if (read_error || n > SCRIPT_LIMIT || !n || memchr(staged + prefix, 0, n)) {
        wlogf("script read rejected: error=%d bytes=%llu limit=%u (empty/NUL not accepted)",
              read_error, (unsigned long long)n, SCRIPT_LIMIT);
        free(staged);
        return NULL;
    }
    staged[prefix + n] = 0;
    *source_len = n;
    return staged;
}

void run_pending(void* L);

__attribute__((naked, used)) void hk_loadstring(void) {
    __asm__ __volatile__(
        "cmpl $0, g_pending(%rip)\n\t"
        "je 1f\n\t"
        "pushq %rcx\n\t"
        "pushq %rdx\n\t"
        "pushq %r8\n\t"
        "pushq %r9\n\t"
        "pushq %r10\n\t"
        "pushq %r11\n\t"
        "subq $0x28, %rsp\n\t"
        "movq 0x50(%rsp), %rcx\n\t"
        "call run_pending\n\t"
        "addq $0x28, %rsp\n\t"
        "popq %r11\n\t"
        "popq %r10\n\t"
        "popq %r9\n\t"
        "popq %r8\n\t"
        "popq %rdx\n\t"
        "popq %rcx\n\t"
        "1:\n\t"
        "jmpq *g_tramp(%rip)\n\t"
    );
}

void run_pending(void* L) {
    if (!script_try_lock()) return;
    LONG req = InterlockedExchange(&g_pending, 0);
    // 另一个调用可能已消费请求；不能重复执行或把完成号清零。
    if (!req) { script_unlock(); return; }

    int saved_top = p_gettop(L);
    int r = p_ls(L, g_script);
    if (r != 0) {
        const char* e = p_tostr ? p_tostr(L, -1, NULL) : NULL;
        wlogf("load err %d (request=%ld): %s", r, req, e ? e : "?");
    } else {
        r = p_pcall(L, 0, 1, 0);
        const char* res = p_tostr ? p_tostr(L, -1, NULL) : NULL;
        if (r != 0) wlogf("pcall err %d (request=%ld): %s", r, req, res ? res : "?");
        else wlogf("lua => %s", res ? res : "nil");
    }
    p_settop(L, saved_top);
    InterlockedExchange(&g_done, req);
    script_unlock();
}

/* 在目标地址 ±2GB 内找一块可执行内存。
   E9 rel32 只有 32 位偏移，当本 DLL 与目标模块的加载地址相隔太远时
   （ASLR），直接跳转会溢出。这时需要一个就近的中转块：
     tgt: E9 rel32 -> relay: FF 25 [8字节绝对地址] -> hook */
static void* alloc_near(void* target, size_t size) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    ULONG_PTR gran = si.dwAllocationGranularity ? si.dwAllocationGranularity : 0x10000;
    ULONG_PTR t = (ULONG_PTR)target;
    const ULONG_PTR RANGE = 0x70000000ULL;   /* 留足余量，小于 2GB */

    ULONG_PTR low  = (t > RANGE) ? (t - RANGE) : gran;
    ULONG_PTR high = t + RANGE;

    /* 先向下找 */
    ULONG_PTR a = t & ~(gran - 1);
    while (a > low) {
        void* m = VirtualAlloc((void*)a, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (m) return m;
        if (a < gran * 2) break;
        a -= gran;
    }
    /* 再向上找 */
    a = (t & ~(gran - 1)) + gran;
    while (a < high) {
        void* m = VirtualAlloc((void*)a, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (m) return m;
        a += gran;
    }
    return NULL;
}

static void* make_tramp(BYTE* target, const BYTE* entry, size_t len) {
    BYTE* t = (BYTE*)VirtualAlloc(NULL, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    memcpy(t, entry, len);
    BYTE* p = t + len;
    p[0] = 0x48; p[1] = 0xB8;
    void* resume = target + len;
    memcpy(p + 2, &resume, sizeof(resume));
    p[10] = 0xFF; p[11] = 0xE0;
    /* 这是可执行内存里刚写进去的指令，必须刷 icache；
       漏掉这一步在部分 CPU 上会执行到未更新的旧内容。 */
    if (!FlushInstructionCache(GetCurrentProcess(), t, len + 12)) {
        VirtualFree(t, 0, MEM_RELEASE);
        return NULL;
    }
    return t;
}

static HMODULE g_self = NULL;

// 游戏会同时加载多个同名 xluau.dll —— 按导出与特征字节认出真正的实现
static HMODULE find_real_module(void) {
    /* need 可能大于缓冲区（模块数超过 4096 时 EnumProcessModules 返回 FALSE
       并把 need 设成所需大小）。这里用静态大缓冲 + 双重检查，避免越界读。 */
    static HMODULE mods[4096];
    DWORD need = 0;
    HANDLE me = GetCurrentProcess();
    if (!EnumProcessModules(me, mods, sizeof(mods), &need)) {
        wlogf("EnumProcessModules failed, need=%lu", (unsigned long)need);
        return NULL;
    }
    if (need > sizeof(mods)) {
        wlogf("module list truncated: need=%lu cap=%lu",
              (unsigned long)need, (unsigned long)sizeof(mods));
        return NULL;
    }
    int n = (int)(need / sizeof(HMODULE));
    for (int i = 0; i < n; i++) {
        if (mods[i] == g_self) continue;
        char name[MAX_PATH] = {0};
        GetModuleBaseNameA(me, mods[i], name, MAX_PATH);
        if (_stricmp(name, "xluau.dll") != 0) continue;

        /* 用导出表定位，而不是按固定 RVA 猜。导出地址才是真正会被调用的入口。 */
        FARPROC pa = GetProcAddress(mods[i], "lua_pcall");
        if (!pa) continue;
        BYTE* p = (BYTE*)pa;

        /* 确认这段地址确实在该模块映像内 */
        MODULEINFO mi;
        if (!GetModuleInformation(me, mods[i], &mi, sizeof(mi))) continue;
        if (p < (BYTE*)mods[i] || p + sizeof(LONG64) > (BYTE*)mods[i] + mi.SizeOfImage) continue;

        if (p[0]==0x48 && p[1]==0x89 && p[2]==0x5C && p[3]==0x24 && p[4]==0x08) {
            char full[MAX_PATH] = {0};
            GetModuleFileNameExA(me, mods[i], full, MAX_PATH);
            wlogf("candidate real module @%p  %s  lua_pcall=%p", mods[i], full, (void*)p);
            return mods[i];
        }
    }
    return NULL;
}

static HMODULE install(void) {
    HMODULE mod = find_real_module();
    if (!mod) { wlog("real module not found"); return NULL; }

    /* 以导出地址为准。固定 RVA 只是预期值：游戏更新后导出可能搬家，
       按 RVA 硬改会打到无关代码上。两者不一致时以导出为准并记录。 */
    FARPROC pa = GetProcAddress(mod, "lua_pcall");
    if (!pa) { wlog("export lua_pcall missing"); return NULL; }
    BYTE* tgt = (BYTE*)pa;

    MODULEINFO mi;
    HANDLE me = GetCurrentProcess();
    if (!GetModuleInformation(me, mod, &mi, sizeof(mi))) { wlog("GetModuleInformation failed"); return NULL; }
    if (tgt < (BYTE*)mod || tgt + sizeof(LONG64) > (BYTE*)mod + mi.SizeOfImage) {
        wlogf("lua_pcall export outside module image: %p", (void*)tgt);
        return NULL;
    }
    if ((ULONG_PTR)tgt % sizeof(LONG64) != 0) {
        wlogf("lua_pcall entry is not 8-byte aligned: %p", (void*)tgt);
        return NULL;
    }
    if (tgt != (BYTE*)mod + TARGET_RVA)
        wlogf("note: export=%p differs from expected RVA %p, using export",
              (void*)tgt, (void*)((BYTE*)mod + TARGET_RVA));

    // 跳板和 CAS 共享同一份入口快照，不在构造跳板时重新读取目标。
    BYTE entry[sizeof(LONG64)];
    memcpy(entry, tgt, sizeof(entry));
    const BYTE prologue[PATCH_LEN] = {0x48, 0x89, 0x5C, 0x24, 0x08};
    if (memcmp(entry, prologue, sizeof(prologue)) != 0) {
        wlogf("signature mismatch: %02X %02X %02X %02X %02X",
              entry[0], entry[1], entry[2], entry[3], entry[4]);
        return NULL;
    }

    // 必需 API 与跳板一起准备，避免已启用入口面对未初始化的调用表。
    p_ls = (fn_ls)GetProcAddress(mod, "luaL_loadstring");
    p_pcall = (fn_pcall)pa;
    p_gettop = (fn_gettop)GetProcAddress(mod, "lua_gettop");
    p_settop = (fn_settop)GetProcAddress(mod, "lua_settop");
    p_tostr = (fn_tolstring)GetProcAddress(mod, "lua_tolstring");
    if (!p_ls || !p_gettop || !p_settop) {
        wlog("critical Lua API missing, hook not installed");
        return NULL;
    }

    BYTE* relay = NULL;
    void* tramp = NULL;

    long long delta = (long long)(ULONG_PTR)hk_loadstring - (long long)(ULONG_PTR)tgt - PATCH_LEN;
    if (delta > 0x7FFFFFFFLL || delta < -0x80000000LL) {
        wlogf("hook direct jump out of range: %lld, building relay", delta);
        relay = (BYTE*)alloc_near(tgt, 16);
        if (!relay) { wlog("relay alloc failed"); return NULL; }
        /* FF 25 00000000 : jmp qword ptr [rip+0]  -> 8 字节绝对地址 */
        relay[0] = 0xFF;
        relay[1] = 0x25;
        memset(relay + 2, 0, 4);
        ULONG_PTR hook_address = (ULONG_PTR)hk_loadstring;
        memcpy(relay + 6, &hook_address, sizeof(hook_address));
        if (!FlushInstructionCache(me, relay, 16)) {
            VirtualFree(relay, 0, MEM_RELEASE);
            wlog("relay instruction cache flush failed");
            return NULL;
        }
        delta = (long long)(ULONG_PTR)relay - (long long)(ULONG_PTR)tgt - PATCH_LEN;
        if (delta > 0x7FFFFFFFLL || delta < -0x80000000LL) {
            wlogf("relay still out of range: %lld", delta);
            VirtualFree(relay, 0, MEM_RELEASE);
            return NULL;
        }
        wlogf("relay @%p, delta=%lld", relay, delta);
    }

    tramp = make_tramp(tgt, entry, PATCH_LEN);
    if (!tramp) {
        wlog("trampoline alloc failed");
        if (relay) VirtualFree(relay, 0, MEM_RELEASE);
        return NULL;
    }

    // 一次修改入口的 8 字节；保留末尾 3 字节，且不覆盖本轮预期之外的改动。
    LONG64 expected = 0, desired = 0;
    memcpy(&expected, entry, sizeof(expected));
    entry[0] = 0xE9;
    LONG rel = (LONG)delta;
    memcpy(entry + 1, &rel, sizeof(rel));
    memcpy(&desired, entry, sizeof(desired));

    DWORD old = 0;
    if (!VirtualProtect(tgt, sizeof(desired), PAGE_EXECUTE_READWRITE, &old)) {
        wlog("VirtualProtect failed");
        goto discard;
    }
    // 此时 trampoline/relay 已完成并刷新缓存。先发布指针，再使游戏能跳进 hook。
    InterlockedExchangePointer(&g_tramp, tramp);
    LONG64 previous = InterlockedCompareExchange64((volatile LONG64*)tgt, desired, expected);
    DWORD ignored;
    if (!VirtualProtect(tgt, sizeof(desired), old, &ignored))
        wlogf("restore target page protection failed: %lu", GetLastError());
    if (previous != expected) {
        InterlockedExchangePointer(&g_tramp, NULL);
        wlog("target changed at patch commit");
        goto discard;
    }
    if (!FlushInstructionCache(me, tgt, sizeof(desired)))
        wlogf("flush target instruction cache failed: %lu", GetLastError());

    wlogf("hook OK: %p -> hk %p, tramp %p", tgt, hk_loadstring, tramp);
    wlogf("api: ls=%p pcall=%p gettop=%p settop=%p tostr=%p",
          p_ls, p_pcall, p_gettop, p_settop, p_tostr);
    return mod;

discard:
    VirtualFree(tramp, 0, MEM_RELEASE);
    if (relay) VirtualFree(relay, 0, MEM_RELEASE);
    return NULL;
}

static DWORD WINAPI worker(LPVOID param) {
    (void)param;

    DWORD dir_len = GetModuleFileNameA(g_self, g_dir, MAX_PATH);
    if (!dir_len || dir_len >= MAX_PATH) return 1;
    char* base = strrchr(g_dir, '\\');
    if (!base) return 1;
    *base = 0;
    int log_len = snprintf(g_log, MAX_PATH, "%s\\EquipBarNative.log", g_dir);
    char script_path[MAX_PATH];
    int path_len = snprintf(script_path, MAX_PATH, "%s\\EquipBarScript.lua", g_dir);
    if (log_len < 0 || log_len >= MAX_PATH || path_len < 0 || path_len >= MAX_PATH) return 1;

    FILE* log = fopen(g_log, "w");
    if (log) {
        fprintf(log, "proxy dll loaded, pid=%lu\n", GetCurrentProcessId());
        fclose(log);
    }

    // 等真身模块出现并安装 hook（最多约 90 秒）。
    HMODULE mod = NULL;
    for (int i = 0; i < 900; i++) {
        mod = install();
        if (mod) break;
        Sleep(100);
    }
    if (!mod) { wlog("install failed"); return 1; }
    wlogf("real module handle = %p", mod);

    FILETIME last_write = {0, 0};
    for (;;) {
        WIN32_FILE_ATTRIBUTE_DATA fad;
        if (GetFileAttributesExA(script_path, GetFileExInfoStandard, &fad) &&
            CompareFileTime(&fad.ftLastWriteTime, &last_write) != 0) {
            size_t length = 0;
            char* staged = script_read(script_path, &length);
            if (staged) {
                LONG req = script_publish(staged);
                if (req) {
                    last_write = fad.ftLastWriteTime;
                    wlogf("script reloaded, %llu bytes, revision=%llu, request=%ld",
                          (unsigned long long)length, g_revision, req);
                } else {
                    free(staged);
                    wlog("script publish deferred (busy), retry next tick");
                }
            }
        }
        // 同一修订也需要重新检查当前页面；有新脚本在排队时不覆盖它。
        request_periodic();
        Sleep(2000);
    }
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = (HMODULE)hinst;
        DisableThreadLibraryCalls(hinst);

        // 无安全在线卸载路径。pin 失败就不启动 worker，保留正常导出转发。
        HMODULE pinned;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_PIN,
                                (LPCWSTR)(void*)&worker, &pinned)) {
            OutputDebugStringA("EquipBar: could not pin proxy; hook disabled");
            return TRUE;
        }
        HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (thread) CloseHandle(thread);
        else OutputDebugStringA("EquipBar: could not start worker");
    }
    // 仅在关闭进程时卸载；不在 loader lock 内等待线程或恢复其他模块的入口。
    return TRUE;
}

__declspec(dllexport) int EquipBarNative_probe(void) { return completed_request() != 0; }
