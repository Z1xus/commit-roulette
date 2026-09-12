static const uint32_t constants[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static uint32_t rr(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

static void expand(uint32_t w[80], unsigned sha256) {
    for (unsigned t = 16; t < (sha256 ? 64u : 80u); ++t) {
        if (sha256) {
            uint32_t x = w[t - 15], y = w[t - 2];
            w[t] = w[t - 16] + (rr(x, 7) ^ rr(x, 18) ^ (x >> 3)) + w[t - 7] + (rr(y, 17) ^ rr(y, 19) ^ (y >> 10));
        } else w[t] = rr(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 31);
    }
}

static void rounds(uint32_t s[8], const uint32_t w[80], unsigned end, unsigned sha256) {
    uint32_t a=s[0], b=s[1], c=s[2], d=s[3], e=s[4], f=s[5], g=s[6], h=s[7];
    for (unsigned t = 0; t < end; ++t) {
        if (sha256) {
            uint32_t t1 = h + (rr(e,6)^rr(e,11)^rr(e,25)) + ((e&f)^(~e&g)) + constants[t] + w[t];
            uint32_t t2 = (rr(a,2)^rr(a,13)^rr(a,22)) + ((a&b)^(a&c)^(b&c));
            h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        } else {
            uint32_t fun = t<20 ? ((b&c)|(~b&d)) : t<40 ? (b^c^d) : t<60 ? ((b&c)|(b&d)|(c&d)) : (b^c^d);
            uint32_t k = t<20 ? 0x5a827999u : t<40 ? 0x6ed9eba1u : t<60 ? 0x8f1bbcdcu : 0xca62c1d6u;
            uint32_t next = rr(a,27)+fun+e+k+w[t];
            e=d; d=c; c=rr(b,2); b=a; a=next;
        }
    }
    s[0]=a; s[1]=b; s[2]=c; s[3]=d; s[4]=e; s[5]=f; s[6]=g; s[7]=h;
}

static uint32_t *schedules(const uint8_t *tail, unsigned blocks, unsigned sha256) {
    uint32_t *words = calloc((size_t)blocks, 80 * sizeof(uint32_t));
    if (!words) return NULL;
    for (unsigned block = 0; block < blocks; ++block) {
        uint32_t *w = words + (size_t)block * 80;
        for (unsigned i = 0; i < 16; ++i) {
            const uint8_t *p = tail + (size_t)block * 64 + i * 4;
            w[i] = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
        }
        expand(w, sha256);
    }
    return words;
}
