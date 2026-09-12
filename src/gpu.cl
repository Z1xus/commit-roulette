kernel void KERNEL(global const uint *schedule, global const uint *initial,
                   ulong start, uint count, global uint *winner) {
    size_t first = get_global_id(0) * LANES;
    if (first >= count) return;
    uint s[LANES][8];
    #pragma unroll
    for (uint lane = 0; lane < LANES; ++lane) {
        #pragma unroll
        for (uint i = 0; i < 8; ++i) s[lane][i] = initial[i];
    }
    #if BLOCKS <= 8
    #pragma unroll
    #endif
    for (uint block = 0; block < BLOCKS; ++block) {
        uint w[LANES][16], work[LANES][8];
        #pragma unroll
        for (uint lane = 0; lane < LANES; ++lane) {
            uint counter = (uint)start + (uint)first + lane;
            #pragma unroll
            for (uint i = 0; i < 16; ++i) {
                uint word = input_word(schedule, block, i);
                #pragma unroll
                for (uint j = 0; j < 4; ++j) {
                    uint at = block * 64 + i * 4 + j;
                    if (at >= NONCE_AT && at - NONCE_AT < (SIGNED_NONCE ? 32u : 8u)) {
                        uint n = at - NONCE_AT;
                        uint v;
                        if (SIGNED_NONCE) v = ((counter >> (31 - n)) & 1) ? 9 : 32;
                        else {
                            v = (counter >> ((7 - n) * 4)) & 15;
                            v += v < 10 ? 48 : 87;
                        }
                        uint shift = (3 - j) * 8;
                        word = (word & ~(255u << shift)) | (v << shift);
                    }
                }
                w[lane][i] = word;
            }
            #pragma unroll
            for (uint i = 0; i < 8; ++i) work[lane][i] = block == 0 ? initial[8 + i] : s[lane][i];
        }
        ROUND_LOOP
        for (uint t = 0; t < (SHA256 ? 64u : 80u); ++t) {
            if (block == 0 && t < NONCE_AT / 4) continue;
            #pragma unroll
            for (uint lane = 0; lane < LANES; ++lane) {
                uint k = t & 15;
                if (block * 64 >= NONCE_AT + (SIGNED_NONCE ? 32u : 8u)) {
                    w[lane][k] = FIXED_WORD(block,t);
                } else if (t >= 16) {
                    if (SHA256) {
                        uint x=w[lane][(t-15)&15], y=w[lane][(t-2)&15];
                        w[lane][k] += (rr(x,7)^rr(x,18)^(x>>3)) + w[lane][(t-7)&15] + (rr(y,17)^rr(y,19)^(y>>10));
                    } else w[lane][k] = rotate(w[lane][(t-3)&15]^w[lane][(t-8)&15]^w[lane][(t-14)&15]^w[lane][k],1u);
                }
                uint a=work[lane][0], b=work[lane][1], c=work[lane][2], d=work[lane][3];
                uint e=work[lane][4], f=work[lane][5], g=work[lane][6], h=work[lane][7];
                if (SHA256) {
                    uint t1 = h + (rr(e,6)^rr(e,11)^rr(e,25)) + bitselect(g,f,e) + constants[t] + w[lane][k];
                    uint t2 = (rr(a,2)^rr(a,13)^rr(a,22)) + bitselect(a,b,a^c);
                    work[lane][7]=g; work[lane][6]=f; work[lane][5]=e; work[lane][4]=d+t1;
                    work[lane][3]=c; work[lane][2]=b; work[lane][1]=a; work[lane][0]=t1+t2;
                } else {
                    uint fun = t<20 ? bitselect(d,c,b) : t<40 ? (b^c^d) : t<60 ? bitselect(b,c,b^d) : (b^c^d);
                    uint round_constant = t<20 ? 0x5a827999u : t<40 ? 0x6ed9eba1u : t<60 ? 0x8f1bbcdcu : 0xca62c1d6u;
                    uint next = rotate(a,5u)+fun+e+round_constant+w[lane][k];
                    work[lane][4]=d; work[lane][3]=c; work[lane][2]=rotate(b,30u); work[lane][1]=a; work[lane][0]=next;
                }
            }
        }
        #pragma unroll
        for (uint lane = 0; lane < LANES; ++lane) {
            #pragma unroll
            for (uint i = 0; i < (SHA256 ? 8u : 5u); ++i) s[lane][i] += work[lane][i];
        }
    }
    #pragma unroll
    for (uint lane = 0; lane < LANES; ++lane)
        if (first + lane < count && matches(s[lane])) atomic_min(winner, (uint)first + lane);
}
