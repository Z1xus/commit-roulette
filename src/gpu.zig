const std = @import("std");
const hash = @import("hash.zig");

const handle = opaque {};
extern fn roulette_gpu_open(source: [*:0]const u8, tail: [*]const u8, blocks: u32, state: [*]const u32, digits: [*]const u8, nonce_at: u32, signed_nonce: u32, sha256: u32, length: u32, position: u32) ?*handle;
extern fn roulette_gpu_close(g: *handle) void;
extern fn roulette_gpu_batch(g: *handle, start: u64, count: u32, winner: *u32) c_int;
extern fn roulette_gpu_batch_limit(g: *handle) u32;

pub const session = struct {
    device: *handle,

    pub fn init(allocator: std.mem.Allocator, base: hash.context, suffix: []const u8, signed: bool, digits: []const u8, position: u32) !session {
        if (suffix.len > 16 * 1024 * 1024) return error.GpuUnavailable;
        const tail = try base.padded(allocator, suffix);
        defer allocator.free(tail);
        return .{ .device = roulette_gpu_open(@embedFile("gpu.cl"), tail.ptr, @intCast(tail.len / 64), &base.state, digits.ptr, @intCast(base.used), @intFromBool(signed), @intFromBool(base.kind == .sha256), @intCast(digits.len), position) orelse return error.GpuUnavailable };
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

    pub fn batchLimit(self: session) u32 {
        return roulette_gpu_batch_limit(self.device);
    }
};
