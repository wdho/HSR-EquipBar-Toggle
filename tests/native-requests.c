/* Build as a standalone x64 Windows test; does not load a game DLL or patch any code. */
#include "../native/hook.c"
#include <assert.h>

static int loads;
static int calls;
static const char* want_prefix;

static int test_load(void* state, const char* script) {
    int* top = (int*)state;
    assert(strncmp(script, want_prefix, strlen(want_prefix)) == 0);
    assert(*top == 3);
    ++*top;
    ++loads;
    return 0;
}

static int test_pcall(void* state, int args, int results, int handler) {
    assert(args == 0 && results == 1 && handler == 0);
    assert(*(int*)state == 4);
    ++calls;
    return 0;
}

static int test_top(void* state) { return *(int*)state; }
static void test_restore(void* state, int top) { *(int*)state = top; }

static DWORD WINAPI deliver(LPVOID state) {
    run_pending(state);
    return 0;
}

int main(int argc, char** argv) {
    assert(argc == 2);
    p_ls = test_load;
    p_pcall = test_pcall;
    p_gettop = test_top;
    p_settop = test_restore;
    int top1 = 3, top2 = 3;
    size_t size1 = 0, size2 = 0;

    char* first = script_read(argv[1], &size1);
    assert(first && size1 > 8191 && g_revision == 0);
    LONG first_req = script_publish(first);
    assert(first_req != 0 && g_revision == 1);
    char* second = script_read(argv[1], &size2);
    assert(second && size2 == size1 && script_publish(second) == 0);
    assert(g_revision == 1 && g_script == first);

    want_prefix = "local __equipbar_revision = 1\n";
    assert(script_try_lock());
    run_pending(&top1);
    assert(loads == 0 && g_pending == first_req);
    script_unlock();

    HANDLE h[2] = {
        CreateThread(NULL, 0, deliver, &top1, 0, NULL),
        CreateThread(NULL, 0, deliver, &top2, 0, NULL)
    };
    assert(h[0] && h[1] && WaitForMultipleObjects(2, h, TRUE, 5000) == WAIT_OBJECT_0);
    CloseHandle(h[0]);
    CloseHandle(h[1]);
    assert(loads == 1 && calls == 1 && top1 == 3 && top2 == 3);
    assert(g_pending == 0 && completed_request() == first_req);
    run_pending(&top1); // Simulate a previously dequeued caller entering the callback late.
    assert(loads == 1 && completed_request() == first_req);
    puts("PASS: concurrent consumers complete a request only once and restore the Lua stack");

    request_periodic();
    LONG periodic_req = g_pending;
    assert(periodic_req != 0 && periodic_req != first_req && g_revision == 1);
    run_pending(&top1);
    assert(completed_request() == periodic_req && loads == 2);
    puts("PASS: periodic UI checks preserve the active script revision");

    LONG second_req = script_publish(second);
    assert(second_req != 0 && second_req != periodic_req && g_revision == 2);
    want_prefix = "local __equipbar_revision = 2\n";
    run_pending(&top1);
    assert(completed_request() == second_req && loads == 3 && calls == 3 && top1 == 3);
    free(g_script);
    puts("PASS: postponed reload binds a new request and revision, including files over 8191 bytes");
    return 0;
}
