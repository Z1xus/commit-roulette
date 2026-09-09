const std = @import("std");
const builtin = @import("builtin");
extern fn roulette_width() c_int;

pub const ui = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    quiet: bool = false,
    animate: bool = false,
    color: bool = false,
    live: bool = false,
    live_rows: usize = 1,

    pub fn write(self: *ui, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, format, args) catch return;
        defer self.allocator.free(text);
        std.Io.File.stderr().writeStreamingAll(self.io, text) catch {};
    }
    pub fn clear(self: *ui) void {
        if (self.live) {
            self.write("\r\x1b[2K", .{});
            for (1..self.live_rows) |_| self.write("\x1b[1A\r\x1b[2K", .{});
        }
        self.live = false;
        self.live_rows = 1;
    }
    pub fn log(self: *ui, marker: []const u8, comptime format: []const u8, args: anytype) void {
        if (self.quiet) return;
        self.clear();
        self.write("[{s}] ", .{marker});
        self.write(format ++ "\n", args);
    }
    pub fn progress(self: *ui, tries: u64, elapsed: f64, reel: u64, symbols: usize) void {
        if (!self.animate or self.quiet) return;
        self.clear();
        const width: usize = @intCast(@max(roulette_width(), 1));
        var text: [240]u8 = undefined;
        const digits = "0123456789abcdef";
        if (width >= 54) {
            var spinning: [64]u8 = undefined;
            var state = reel ^ 0x9e3779b97f4a7c15;
            for (spinning[0..symbols]) |*digit| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                digit.* = digits[state & 15];
            }
            self.live_rows = self.frame(spinning[0..symbols], false) + 1;
        }
        const line = if (width >= 54)
            std.fmt.bufPrint(&text, "[*] {d} tries  |  {d:.2} mh/s  |  {d:.1}s", .{ tries, @as(f64, @floatFromInt(tries)) / @max(elapsed, 0.000001) / 1e6, elapsed }) catch return
        else
            std.fmt.bufPrint(&text, "[*] rolling  {d} tries  |  {d:.1}s", .{ tries, elapsed }) catch return;
        self.write("{s}", .{line[0..@min(line.len, width -| 1)]});
        self.live = true;
    }

    fn frame(self: *ui, digits: []const u8, won: bool) usize {
        const width: usize = @intCast(@max(roulette_width(), 1));
        const columns = @min(digits.len, (width -| 10) / 3);
        if (columns == 0) return 0;
        const inner_width = columns * 3 + 3;
        const top_left = if (builtin.os.tag == .windows) "+" else "┌";
        const top_right = if (builtin.os.tag == .windows) "+" else "┐";
        const bottom_left = if (builtin.os.tag == .windows) "+" else "└";
        const bottom_right = if (builtin.os.tag == .windows) "+" else "┘";
        const horizontal = if (builtin.os.tag == .windows) "-" else "─";
        const side = if (builtin.os.tag == .windows) "|" else "│";
        const color = if (!self.color) "" else if (won) "\x1b[32m" else "\x1b[33m";
        const reset = if (self.color) "\x1b[0m" else "";
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{s}    {s}", .{ color, top_left }) catch return 0;
        for (0..inner_width) |_| writer.writeAll(horizontal) catch return 0;
        writer.print("{s}\n", .{top_right}) catch return 0;
        var start: usize = 0;
        var rows: usize = 2;
        while (start < digits.len) : (start += columns) {
            const row = digits[start..@min(start + columns, digits.len)];
            writer.print("    {s}  ", .{side}) catch return 0;
            for (row) |digit| writer.print("{c}  ", .{digit}) catch return 0;
            writer.splatByteAll(' ', (columns - row.len) * 3 + 1) catch return 0;
            writer.print("{s}\n", .{side}) catch return 0;
            rows += 1;
        }
        writer.print("    {s}", .{bottom_left}) catch return 0;
        for (0..inner_width) |_| writer.writeAll(horizontal) catch return 0;
        writer.print("{s}\n{s}", .{ bottom_right, reset }) catch return 0;
        self.write("{s}", .{writer.buffered()});
        return rows;
    }

    pub fn finish(self: *ui, digits: []const u8) void {
        self.clear();
        if (!self.animate or self.quiet or roulette_width() < 54) return;
        _ = self.frame(digits, true);
    }
    pub fn prompt(self: *ui, allocator: std.mem.Allocator, question: []const u8, default: []const u8) ![]const u8 {
        self.write("[?] {s} [{s}]: ", .{ question, default });
        var buffer: [4096]u8 = undefined;
        var n: usize = 0;
        while (n < buffer.len) {
            const read = try std.Io.File.stdin().readStreaming(self.io, &.{buffer[n..][0..1]});
            if (read == 0) return error.EndOfStream;
            if (buffer[n] == '\n') break;
            n += 1;
        }
        if (n == buffer.len) return error.InputTooLong;
        const value = std.mem.trim(u8, buffer[0..n], " \t\r");
        return allocator.dupe(u8, if (value.len == 0) default else value);
    }
};
