#include <stdint.h>
__attribute__((target("sha2")))
void sha1_process_arm(uint32_t state[5], const uint8_t data[], uint32_t length);
__attribute__((target("sha2")))
void sha256_process_arm(uint32_t state[8], const uint8_t data[], uint32_t length);
#include "../vendor/sha/sha1-arm.c"
#include "../vendor/sha/sha256-arm.c"
