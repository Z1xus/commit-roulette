const std = @import("std");
const hash = @import("hash.zig");
const ui = @import("ui.zig").ui;
extern fn roulette_stopped() c_int;
extern fn roulette_signals() void;

pub const position = enum { prefix, suffix, contains };
pub const pattern = struct {
    digits: [64]u8 = undefined,
    len: usize,
    where: position,
    pub fn init(text: []const u8, where: position, length: usize) !pattern {
        if (text.len == 0 or text.len > length) return error.InvalidTargetLength;
        var parsed: pattern = .{ .len = text.len, .where = where };
        for (text, 0..) |c, i| parsed.digits[i] = std.fmt.charToDigit(c, 16) catch return error.InvalidTarget;
        return parsed;
    }
    pub fn matches(self: pattern, digest: []const u8) bool {
        const last = digest.len * 2 - self.len;
        const begin: usize = if (self.where == .suffix) last else 0;
        const end: usize = if (self.where == .contains) last else begin;
        var offset = begin;
        while (offset <= end) : (offset += 1) {
            var match = true;
            for (self.digits[0..self.len], 0..) |digit, i| {
                const at = offset + i;
                const found = if (at % 2 == 0) digest[at / 2] >> 4 else digest[at / 2] & 15;
                if (found != digit) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }
};

pub const result = struct { bytes: []u8, tries: u64, seconds: f64, engine: hash.backend };
const shared = struct {
    stop: std.atomic.Value(bool) = .init(false),
    found: std.atomic.Value(bool) = .init(false),
    tries: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(usize) = .init(0),
    finished: std.Io.Timestamp = .zero,
    io: std.Io,
    winner: []u8,
    target: pattern,
};
const worker = struct {
    common: *shared,
    bytes: []u8,
    offset: usize,
    signed: bool,
    start: u64,
    stride: u64,
    prefix: hash.context,
    fn run(self: *worker) void {
        defer _ = self.common.active.fetchSub(1, .release);
        var counter = self.start;
        var batch: u64 = 0;
        while (!self.common.stop.load(.monotonic)) {
            encode(self.bytes[self.offset..], counter, self.signed);
            var h = self.prefix;
            h.update(self.bytes[self.offset..]);
            const digest = h.final();
            batch += 1;
            if (self.common.target.matches(digest[0..if (h.kind == .sha1) @as(usize, 20) else 32])) {
                if (!self.common.found.swap(true, .acq_rel)) {
                    @memcpy(self.common.winner, self.bytes);
                    self.common.finished = std.Io.Clock.awake.now(self.common.io);
                }
                self.common.stop.store(true, .release);
                break;
            }
            if (batch == 2048) {
                _ = self.common.tries.fetchAdd(batch, .monotonic);
                batch = 0;
            }
            const next = @addWithOverflow(counter, self.stride);
            if (next[1] != 0) break;
            counter = next[0];
        }
        _ = self.common.tries.fetchAdd(batch, .monotonic);
    }
};

pub fn encode(bytes: []u8, value: u64, signed: bool) void {
    if (signed) {
        for (0..64) |i| bytes[i] = if ((value >> @as(u6, @intCast(i))) & 1 == 0) ' ' else '\t';
    } else {
        const digits = "0123456789abcdef";
        for (0..16) |i| bytes[i] = digits[(value >> @as(u6, @intCast((15 - i) * 4))) & 15];
    }
}

pub fn mine(allocator: std.mem.Allocator, io: std.Io, display: *ui, raw: []const u8, offset: usize, signed: bool, kind: hash.algorithm, target: pattern, threads: usize, engine: hash.backend) !result {
    var base = hash.context.init(kind, engine);
    var header: [40]u8 = undefined;
    base.update(try std.fmt.bufPrint(&header, "commit {d}\x00", .{raw.len}));
    base.update(raw[0..offset]);
    const winner = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(winner);
    var common: shared = .{ .winner = winner, .target = target, .io = io };
    const workers = try allocator.alloc(worker, threads);
    defer allocator.free(workers);
    const handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);
    var started: usize = 0;
    defer {
        common.stop.store(true, .release);
        for (handles[0..started]) |handle| handle.join();
        for (workers[0..started]) |w| allocator.free(w.bytes);
        display.clear();
    }
    roulette_signals();
    const begin = std.Io.Clock.awake.now(io);
    for (workers, 0..) |*w, i| {
        w.* = .{ .common = &common, .bytes = try allocator.dupe(u8, raw), .offset = offset, .signed = signed, .start = @intCast(i), .stride = @intCast(threads), .prefix = base };
        _ = common.active.fetchAdd(1, .monotonic);
        handles[i] = std.Thread.spawn(.{}, worker.run, .{w}) catch |err| {
            _ = common.active.fetchSub(1, .monotonic);
            allocator.free(w.bytes);
            return err;
        };
        started += 1;
    }
    var last_frame: f64 = -1;
    while (common.active.load(.acquire) != 0) {
        if (roulette_stopped() != 0) common.stop.store(true, .release);
        const elapsed = @as(f64, @floatFromInt(begin.untilNow(io, .awake).toNanoseconds())) / 1e9;
        const tries = common.tries.load(.monotonic);
        if (elapsed - last_frame >= 0.1) {
            display.progress(tries, elapsed, tries ^ @as(u64, @intFromFloat(elapsed * 1000)), target.len);
            last_frame = elapsed;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    if (roulette_stopped() != 0) return error.Canceled;
    if (!common.found.load(.acquire)) return error.SearchExhausted;
    return .{ .bytes = winner, .tries = common.tries.load(.monotonic), .seconds = @as(f64, @floatFromInt(begin.durationTo(common.finished).toNanoseconds())) / 1e9, .engine = engine };
}
