const std = @import("std");
const builtin = @import("builtin");
extern fn roulette_accelerated() c_int;
extern fn sha1_process_x86(state: [*]u32, data: [*]const u8, len: u32) void;
extern fn sha256_process_x86(state: [*]u32, data: [*]const u8, len: u32) void;
extern fn sha1_process_arm(state: [*]u32, data: [*]const u8, len: u32) void;
extern fn sha256_process_arm(state: [*]u32, data: [*]const u8, len: u32) void;

pub const algorithm = enum { sha1, sha256 };
pub const backend = enum { portable, accelerated };
pub fn detect() backend {
    return if (roulette_accelerated() != 0) .accelerated else .portable;
}

pub fn compress(kind: algorithm, engine: backend, state: *[8]u32, data: []const u8) void {
    if (engine == .accelerated) {
        switch (builtin.cpu.arch) {
            .x86_64 => switch (kind) {
                .sha1 => sha1_process_x86(state, data.ptr, @intCast(data.len)),
                .sha256 => sha256_process_x86(state, data.ptr, @intCast(data.len)),
            },
            .aarch64 => switch (kind) {
                .sha1 => sha1_process_arm(state, data.ptr, @intCast(data.len)),
                .sha256 => sha256_process_arm(state, data.ptr, @intCast(data.len)),
            },
            else => unreachable,
        }
    } else switch (kind) {
        .sha1 => {
            var h = std.crypto.hash.Sha1.init(.{});
            h.s = state[0..5].*;
            h.update(data);
            state[0..5].* = h.s;
        },
        .sha256 => {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.s = state.*;
            h.update(data);
            state.* = h.s;
        },
    }
}

pub const context = struct {
    state: [8]u32,
    buffer: [64]u8 = undefined,
    used: usize = 0,
    length: u64 = 0,
    kind: algorithm,
    engine: backend,

    pub fn init(kind: algorithm, engine: backend) context {
        return .{ .state = switch (kind) {
            .sha1 => .{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0, 0, 0, 0 },
            .sha256 => .{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
        }, .kind = kind, .engine = engine };
    }

    fn blocks(self: *context, data: []const u8) void {
        compress(self.kind, self.engine, &self.state, data);
    }

    pub fn update(self: *context, bytes: []const u8) void {
        self.length += bytes.len;
        var data = bytes;
        if (self.used > 0) {
            const n = @min(64 - self.used, data.len);
            @memcpy(self.buffer[self.used..][0..n], data[0..n]);
            self.used += n;
            data = data[n..];
            if (self.used == 64) {
                self.blocks(&self.buffer);
                self.used = 0;
            }
        }
        const n = data.len / 64 * 64;
        if (n > 0) self.blocks(data[0..n]);
        if (data.len > n) {
            @memcpy(self.buffer[0 .. data.len - n], data[n..]);
            self.used = data.len - n;
        }
    }

    // buffered bytes, suffix, and padding as whole blocks. hashing them from state gives the final state.
    pub fn padded(self: context, allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
        const length = self.used + suffix.len;
        const size = std.mem.alignForward(usize, length + 9, 64);
        const tail = try allocator.alloc(u8, size);
        @memset(tail, 0);
        @memcpy(tail[0..self.used], self.buffer[0..self.used]);
        @memcpy(tail[self.used..][0..suffix.len], suffix);
        tail[length] = 0x80;
        std.mem.writeInt(u64, tail[size - 8 ..][0..8], (self.length + suffix.len) * 8, .big);
        return tail;
    }

    pub fn final(self: *context) [32]u8 {
        var padding: [128]u8 = @splat(0);
        padding[0] = 0x80;
        const n = if (self.used < 56) 64 - self.used else 128 - self.used;
        std.mem.writeInt(u64, padding[n - 8 ..][0..8], self.length * 8, .big);
        self.update(padding[0..n]);
        var out: [32]u8 = @splat(0);
        for (self.state[0..if (self.kind == .sha1) @as(usize, 5) else 8], 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .big);
        return out;
    }
};
