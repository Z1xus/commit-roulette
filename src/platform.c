#include <stdint.h>
#include <signal.h>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <unistd.h>
#include <sys/ioctl.h>
#endif
#if defined(__x86_64__)
#include <cpuid.h>
#elif defined(__aarch64__) && defined(__linux__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#elif defined(__aarch64__) && defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

static volatile sig_atomic_t stopped = 0;
static void stop_signal(int value) { (void)value; stopped = 1; }
#if defined(_WIN32)
static BOOL WINAPI stop_console(DWORD value) {
    if (value == CTRL_C_EVENT || value == CTRL_BREAK_EVENT) { stopped = 1; return TRUE; }
    return FALSE;
}
#endif
void roulette_signals(void) {
    stopped = 0;
    signal(SIGINT, stop_signal);
    signal(SIGTERM, stop_signal);
#if defined(_WIN32)
    SetConsoleCtrlHandler(stop_console, TRUE);
#endif
}
int roulette_stopped(void) { return stopped != 0; }
int roulette_width(void) {
#if defined(_WIN32)
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_ERROR_HANDLE), &info)) return info.srWindow.Right - info.srWindow.Left + 1;
#else
    struct winsize size;
    if (ioctl(2, TIOCGWINSZ, &size) == 0 && size.ws_col) return size.ws_col;
#endif
    return 80;
}
int roulette_accelerated(void) {
#if defined(__x86_64__)
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d) || !(c & bit_SSSE3) || !(c & bit_SSE4_1)) return 0;
    if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) return 0;
    return (b & (1u << 29)) != 0;
#elif defined(__aarch64__) && defined(__linux__)
    unsigned long flags = getauxval(AT_HWCAP);
    return (flags & HWCAP_SHA1) && (flags & HWCAP_SHA2);
#elif defined(__aarch64__) && defined(__APPLE__)
    int value = 0; size_t size = sizeof(value);
    return sysctlbyname("hw.optional.arm.FEAT_SHA256", &value, &size, 0, 0) == 0 && value;
#elif defined(__aarch64__) && defined(_WIN32)
    return IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE);
#else
    return 0;
#endif
}
