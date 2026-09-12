const std = @import("std");
const hash = @import("hash.zig");

const handle = opaque {};
extern fn roulette_gpu_open(source: [*:0]const u8, tail: [*]const u8, blocks: u32, state: [*]const u32, digits: [*]const u8, nonce_at: u32, signed_nonce: u32, sha256: u32, length: u32, position: u32) ?*handle;
extern fn roulette_gpu_close(g: *handle) void;
extern fn roulette_gpu_batch(g: *handle, start: u64, count: u32, winner: *u32) c_int;

pub const session = struct {
    device: *handle,

    pub fn init(allocator: std.mem.Allocator, base: hash.context, suffix: []const u8, signed: bool, digits: []const u8, position: u32) !session {
        const length = std.math.add(usize, base.used, suffix.len) catch return error.GpuUnavailable;
        if (length > 16 * 1024 * 1024) return error.GpuUnavailable;
        const padded = std.mem.alignForward(usize, length + 9, 64);
        const tail = try allocator.alloc(u8, padded);
        defer allocator.free(tail);
        @memset(tail, 0);
        @memcpy(tail[0..base.used], base.buffer[0..base.used]);
        @memcpy(tail[base.used..][0..suffix.len], suffix);
        tail[length] = 0x80;
        std.mem.writeInt(u64, tail[padded - 8 ..][0..8], (base.length + suffix.len) * 8, .big);
        return .{ .device = roulette_gpu_open(@embedFile("gpu.cl"), tail.ptr, @intCast(padded / 64), &base.state, digits.ptr, @intCast(base.used), @intFromBool(signed), @intFromBool(base.kind == .sha256), @intCast(digits.len), position) orelse return error.GpuUnavailable };
    }

    pub fn deinit(self: session) void {
        roulette_gpu_close(self.device);
    }

    pub fn batch(self: session, start: u64, count: u32) !?u64 {
        var winner: u32 = undefined;
        if (roulette_gpu_batch(self.device, start, count, &winner) == 0) return error.GpuFailed;
        if (winner == std.math.maxInt(u32)) return null;
        if (winner >= count) return error.GpuFailed;
        return start + winner;
    }
};
