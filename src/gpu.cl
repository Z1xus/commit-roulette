constant uint constants[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};
uint rr(uint x, uint n) { return rotate(x, 32u - n); }
kernel void mine(global const uchar *tail, global const uint *initial,
                 global const uchar *digits, uint blocks, uint nonce_at,
                 uint signed_nonce, uint sha256, uint length, uint position,
                 ulong start, global uint *winner) {
    uint id = (uint)get_global_id(0);
    ulong counter = start + (ulong)id;
    uint s[8];
    for (uint i = 0; i < 8; ++i) s[i] = initial[i];
    for (uint block = 0; block < blocks; ++block) {
        uint w[16];
        for (uint i = 0; i < 16; ++i) {
            uint word = 0;
            for (uint j = 0; j < 4; ++j) {
                uint at = block * 64 + i * 4 + j;
                uint v = tail[at];
                if (at >= nonce_at && at - nonce_at < (signed_nonce ? 64u : 16u)) {
                    uint n = at - nonce_at;
                    if (signed_nonce) v = ((counter >> n) & 1) ? 9 : 32;
                    else {
                        v = (uint)((counter >> ((15 - n) * 4)) & 15);
                        v += v < 10 ? 48 : 87;
                    }
                }
                word = (word << 8) | v;
            }
            w[i] = word;
        }
        uint a=s[0], b=s[1], c=s[2], d=s[3], e=s[4], f=s[5], g=s[6], h=s[7];
        for (uint t = 0; t < (sha256 ? 64u : 80u); ++t) {
            uint k = t & 15;
            if (t >= 16) {
                if (sha256) {
                    uint x=w[(t-15)&15], y=w[(t-2)&15];
                    w[k] += (rr(x,7)^rr(x,18)^(x>>3)) + w[(t-7)&15] + (rr(y,17)^rr(y,19)^(y>>10));
                } else w[k] = rotate(w[(t-3)&15]^w[(t-8)&15]^w[(t-14)&15]^w[k],1u);
            }
            if (sha256) {
                uint t1 = h + (rr(e,6)^rr(e,11)^rr(e,25)) + ((e&f)^(~e&g)) + constants[t] + w[k];
                uint t2 = (rr(a,2)^rr(a,13)^rr(a,22)) + ((a&b)^(a&c)^(b&c));
                h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
            } else {
                uint fun = t<20 ? ((b&c)|(~b&d)) : t<40 ? (b^c^d) : t<60 ? ((b&c)|(b&d)|(c&d)) : (b^c^d);
                uint round_constant = t<20 ? 0x5a827999u : t<40 ? 0x6ed9eba1u : t<60 ? 0x8f1bbcdcu : 0xca62c1d6u;
                uint next = rotate(a,5u)+fun+e+round_constant+w[k];
                e=d; d=c; c=rotate(b,30u); b=a; a=next;
            }
        }
        s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e;
        if (sha256) { s[5]+=f; s[6]+=g; s[7]+=h; }
    }
    uint last = (sha256 ? 64u : 40u) - length;
    uint first = position == 1 ? last : 0;
    uint end = position == 2 ? last : first;
    for (uint at = first; at <= end; ++at) {
        uint i = 0;
        for (; i < length; ++i) {
            uint n = at+i;
            if (((s[n/8] >> ((7-n%8)*4)) & 15) != digits[i]) break;
        }
        if (i == length) { atomic_min(winner, id); return; }
    }
}
