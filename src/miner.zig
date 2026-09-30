const std = @import("std");
const hash = @import("hash.zig");
const gpu = @import("gpu.zig");
const ui = @import("ui.zig").ui;
extern fn roulette_stopped() c_int;
extern fn roulette_signals() void;

pub const position = enum { prefix, suffix, contains };
pub const device = enum { auto, cpu, gpu };
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

// masks and values over big-endian state words, one entry per match offset.
const matcher = struct {
    masks: [64][8]u32 = undefined,
    values: [64][8]u32 = undefined,
    first: [64]u8 = undefined,
    last: [64]u8 = undefined,
    count: usize,
    fn init(target: pattern, kind: hash.algorithm) matcher {
        const nibbles: usize = if (kind == .sha1) 40 else 64;
        const end = nibbles - target.len;
        const begin: usize = if (target.where == .suffix) end else 0;
        const stop: usize = if (target.where == .contains) end else begin;
        var out: matcher = .{ .count = stop - begin + 1 };
        for (0..out.count) |k| {
            out.masks[k] = @splat(0);
            out.values[k] = @splat(0);
            for (target.digits[0..target.len], 0..) |digit, i| {
                const n = begin + k + i;
                const shift: u5 = @intCast((7 - n % 8) * 4);
                out.masks[k][n / 8] |= @as(u32, 15) << shift;
                out.values[k][n / 8] |= @as(u32, digit) << shift;
            }
            out.first[k] = @intCast((begin + k) / 8);
            out.last[k] = @intCast((begin + k + target.len - 1) / 8);
        }
        return out;
    }
    inline fn check(self: *const matcher, state: *const [8]u32) bool {
        for (0..self.count) |k| {
            var match = true;
            for (self.first[k]..@as(usize, self.last[k]) + 1) |i| {
                if (state[i] & self.masks[k][i] != self.values[k][i]) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }
};

const shared = struct {
    stop: std.atomic.Value(bool) = .init(false),
    found: std.atomic.Value(bool) = .init(false),
    tries: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(usize) = .init(0),
    finished: std.Io.Timestamp = .zero,
    io: std.Io,
    winner: []u8,
    raw: []const u8,
    offset: usize,
    signed: bool,
    match: matcher,
    state: [8]u32,
    kind: hash.algorithm,
    engine: hash.backend,
};
const worker = struct {
    common: *shared,
    // padded blocks from the block that holds the nonce to the end of the object.
    tail: []u8,
    at: usize,
    start: u64,
    end: u64,
    fn run(self: *worker) void {
        defer _ = self.common.active.fetchSub(1, .release);
        const c = self.common;
        const nonce = self.tail[self.at..];
        var counter = self.start;
        while (counter < self.end and !c.stop.load(.monotonic)) {
            const stop = counter + @min(self.end - counter, 4096);
            const first = counter;
            while (counter < stop) : (counter += 1) {
                encode(nonce, counter, c.signed);
                var state = c.state;
                hash.compress(c.kind, c.engine, &state, self.tail);
                if (c.match.check(&state)) {
                    if (!c.found.swap(true, .acq_rel)) {
                        @memcpy(c.winner, c.raw);
                        encode(c.winner[c.offset..], counter, c.signed);
                        c.finished = std.Io.Clock.awake.now(c.io);
                    }
                    c.stop.store(true, .release);
                    _ = c.tries.fetchAdd(counter - first + 1, .monotonic);
                    return;
                }
            }
            _ = c.tries.fetchAdd(counter - first, .monotonic);
        }
    }
};

const hex_pairs = pairs: {
    const digits = "0123456789abcdef";
    var table: [256][2]u8 = undefined;
    for (&table, 0..) |*pair, i| pair.* = .{ digits[i >> 4], digits[i & 15] };
    break :pairs table;
};
const blank_bytes = blanks: {
    @setEvalBranchQuota(4096);
    var table: [256][8]u8 = undefined;
    for (&table, 0..) |*row, i| {
        for (row, 0..) |*c, bit| c.* = if ((i >> (7 - bit)) & 1 == 0) ' ' else '\t';
    }
    break :blanks table;
};

pub fn encode(bytes: []u8, value: u64, signed: bool) void {
    for (0..8) |i| {
        const byte: u8 = @truncate(value >> @as(u6, @intCast((7 - i) * 8)));
        if (signed) bytes[i * 8 ..][0..8].* = blank_bytes[byte] else bytes[i * 2 ..][0..2].* = hex_pairs[byte];
    }
}

pub fn mine(allocator: std.mem.Allocator, io: std.Io, display: *ui, raw: []const u8, offset: usize, signed: bool, kind: hash.algorithm, target: pattern, threads: usize, engine: hash.backend, selected: device) !result {
    if (selected == .auto and quick(kind, target, threads, engine)) return mineCpu(allocator, io, display, raw, offset, signed, kind, target, threads, engine);
    if (selected != .cpu) {
        return mineGpu(allocator, io, display, raw, offset, signed, kind, target, engine) catch |err| {
            if (selected == .gpu or (err != error.GpuUnavailable and err != error.GpuFailed)) return err;
            display.log("*", "gpu unavailable or failed. using cpu workers.", .{});
            return mineCpu(allocator, io, display, raw, offset, signed, kind, target, threads, engine);
        };
    }
    return mineCpu(allocator, io, display, raw, offset, signed, kind, target, threads, engine);
}

// gpu setup costs about 0.4 s. use cpu workers when they should finish in about 0.25 s.
fn quick(kind: hash.algorithm, target: pattern, threads: usize, engine: hash.backend) bool {
    if (target.len > 12) return false;
    const nibbles: u64 = if (kind == .sha1) 40 else 64;
    const positions: u64 = if (target.where == .contains) nibbles - target.len + 1 else 1;
    const expected = (@as(u64, 1) << @intCast(target.len * 4)) / positions;
    const rate: u64 = if (engine == .accelerated) 20_000_000 else 6_000_000;
    return expected <= threads * rate / 4;
}

fn mineGpu(allocator: std.mem.Allocator, io: std.Io, display: *ui, raw: []const u8, offset: usize, signed: bool, kind: hash.algorithm, target: pattern, engine: hash.backend) !result {
    roulette_signals();
    defer display.clear();
    var base = hash.context.init(kind, engine);
    var header: [40]u8 = undefined;
    base.update(try std.fmt.bufPrint(&header, "commit {d}\x00", .{raw.len}));
    base.update(raw[0..offset]);
    display.log("*", "starting opencl gpu  |  ctrl-c to stop", .{});
    const session = gpu.session.init(allocator, base, raw[offset..], signed, target.digits[0..target.len], @intCast(@intFromEnum(target.where))) catch |err| {
        if (roulette_stopped() != 0) return error.Canceled;
        return err;
    };
    defer session.deinit();
    const winner = try allocator.dupe(u8, raw);
    errdefer allocator.free(winner);
    const begin = std.Io.Clock.awake.now(io);
    var start: u64 = 0;
    var tries: u64 = 0;
    var batch_size: u32 = 4096;
    var last_frame: f64 = -1;
    while (true) {
        if (roulette_stopped() != 0) return error.Canceled;
        const count: u32 = @intCast(@min(@as(u64, batch_size), std.math.maxInt(u64) - start));
        const actual = @max(count, 1);
        const batch_begin = std.Io.Clock.awake.now(io);
        const found = session.batch(start, actual) catch |err| {
            if (roulette_stopped() != 0) return error.Canceled;
            return err;
        };
        tries +|= actual;
        if (roulette_stopped() != 0) return error.Canceled;
        const elapsed = @as(f64, @floatFromInt(begin.untilNow(io, .awake).toNanoseconds())) / 1e9;
        if (found) |counter| {
            encode(winner[offset..], counter, signed);
            var check = base;
            check.update(winner[offset..]);
            const digest = check.final();
            if (!target.matches(digest[0..if (kind == .sha1) @as(usize, 20) else 32])) return error.GpuFailed;
            return .{ .bytes = winner, .tries = tries, .seconds = elapsed, .engine = engine };
        }
        if (elapsed - last_frame >= 0.1) {
            display.progress(tries, elapsed, tries, target.len);
            last_frame = elapsed;
        }
        if (count == 0) return error.SearchExhausted;
        start += actual;
        const duration = batch_begin.untilNow(io, .awake).toNanoseconds();
        if (duration < 25_000_000) batch_size = @min(batch_size * 2, session.batchLimit());
        if (duration > 100_000_000) batch_size = @max(batch_size / 2, 256);
    }
}

fn mineCpu(allocator: std.mem.Allocator, io: std.Io, display: *ui, raw: []const u8, offset: usize, signed: bool, kind: hash.algorithm, target: pattern, threads: usize, engine: hash.backend) !result {
    display.log("*", "{d} workers  |  {s} cpu  |  ctrl-c to stop", .{ threads, @tagName(engine) });
    var base = hash.context.init(kind, engine);
    var header: [40]u8 = undefined;
    base.update(try std.fmt.bufPrint(&header, "commit {d}\x00", .{raw.len}));
    base.update(raw[0..offset]);
    const winner = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(winner);
    var common: shared = .{ .winner = winner, .raw = raw, .offset = offset, .signed = signed, .match = .init(target, kind), .state = base.state, .kind = kind, .engine = engine, .io = io };
    const workers = try allocator.alloc(worker, threads);
    defer allocator.free(workers);
    const handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);
    var started: usize = 0;
    defer {
        common.stop.store(true, .release);
        for (handles[0..started]) |handle| handle.join();
        for (workers[0..started]) |w| allocator.free(w.tail);
        display.clear();
    }
    roulette_signals();
    const begin = std.Io.Clock.awake.now(io);
    const chunk = std.math.maxInt(u64) / threads;
    for (workers, 0..) |*w, i| {
        const start = chunk * i;
        w.* = .{ .common = &common, .tail = try base.padded(allocator, raw[offset..]), .at = base.used, .start = start, .end = if (i + 1 == threads) std.math.maxInt(u64) else start + chunk };
        _ = common.active.fetchAdd(1, .monotonic);
        handles[i] = std.Thread.spawn(.{}, worker.run, .{w}) catch |err| {
            _ = common.active.fetchSub(1, .monotonic);
            allocator.free(w.tail);
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
