#include <stdint.h>
__attribute__((target("sha,ssse3,sse4.1")))
void sha1_process_x86(uint32_t state[5], const uint8_t data[], uint32_t length);
__attribute__((target("sha,ssse3,sse4.1")))
void sha256_process_x86(uint32_t state[8], const uint8_t data[], uint32_t length);
#include "../vendor/sha/sha1-x86.c"
#include "../vendor/sha/sha256-x86.c"
