const std = @import("std");
const ui = @import("ui.zig").ui;
extern fn roulette_stopped() c_int;
pub const git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    display: *ui,
    directory: []const u8 = ".",

    pub fn argv(self: git, args: []const []const u8) ![]const []const u8 {
        const out = try self.allocator.alloc([]const u8, args.len + 3);
        out[0] = "git";
        out[1] = "--no-replace-objects";
        out[2] = "--no-pager";
        @memcpy(out[3..], args);
        return out;
    }
    pub fn call(self: git, args: []const []const u8) !std.process.RunResult {
        return std.process.run(self.allocator, self.io, .{ .argv = try self.argv(args), .cwd = .{ .path = self.directory }, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    }
    pub fn okay(term: std.process.Child.Term) bool {
        return term == .exited and term.exited == 0;
    }
    pub fn checked(self: git, args: []const []const u8) ![]const u8 {
        const out = try self.call(args);
        if (!okay(out.term)) {
            self.display.clear();
            self.display.write("{s}", .{out.stderr});
            return error.GitFailed;
        }
        return out.stdout;
    }
    pub fn text(self: git, args: []const []const u8) ![]const u8 {
        return std.mem.trim(u8, try self.checked(args), "\r\n");
    }
    pub fn optional(self: git, args: []const []const u8) !?[]const u8 {
        const out = try self.call(args);
        return if (okay(out.term)) std.mem.trim(u8, out.stdout, "\r\n") else null;
    }
    pub fn exists(self: git, path: []const u8) !bool {
        const resolved = try self.text(&.{ "rev-parse", "--path-format=absolute", "--git-path", path });
        std.Io.Dir.cwd().access(self.io, resolved, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    pub fn preflight(self: *git) !void {
        self.directory = try self.text(&.{ "rev-parse", "--show-toplevel" });
        for ([_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }) |path| {
            if (try self.exists(path)) return error.UnfinishedGitOperation;
        }
        const version = try self.text(&.{"--version"});
        var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, version, "git version "), '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        if (major < 2 or (major == 2 and minor < 48)) return error.GitTooOld;
    }
    pub fn branch(self: git) !?[]const u8 {
        return self.optional(&.{ "symbolic-ref", "-q", "HEAD" });
    }
    pub fn head(self: git) ![]const u8 {
        return self.text(&.{ "rev-parse", "--verify", "HEAD" });
    }

    // stdin and stdout are files, so large commit bodies cannot deadlock on pipes.
    pub fn input(self: git, args: []const []const u8, bytes: []const u8) ![]const u8 {
        return self.inputTool(try self.argv(args), bytes);
    }
    pub fn inputTool(self: git, args: []const []const u8, bytes: []const u8) ![]const u8 {
        const path = try self.text(&.{ "rev-parse", "--path-format=absolute", "--git-path", "roulette-tmp" });
        try std.Io.Dir.cwd().createDirPath(self.io, path);
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, std.fmt.bytesToHex(random, .lower) });
        var file = try std.Io.Dir.cwd().createFile(self.io, name, .{ .read = true, .exclusive = true });
        defer file.close(self.io);
        defer std.Io.Dir.cwd().deleteFile(self.io, name) catch {};
        try file.writePositionalAll(self.io, bytes, 0);
        const error_path = try std.fmt.allocPrint(self.allocator, "{s}.stderr", .{name});
        var error_file: ?std.Io.File = if (self.display.quiet) try std.Io.Dir.cwd().createFile(self.io, error_path, .{ .exclusive = true }) else null;
        defer if (self.display.quiet) std.Io.Dir.cwd().deleteFile(self.io, error_path) catch {};
        defer if (error_file) |handle| handle.close(self.io);
        var child = try std.process.spawn(self.io, .{ .argv = args, .cwd = .{ .path = self.directory }, .stdin = .{ .file = file }, .stdout = .pipe, .stderr = if (error_file) |handle| .{ .file = handle } else .inherit });
        errdefer child.kill(self.io);
        var reader_buffer: [8192]u8 = undefined;
        var reader = child.stdout.?.reader(self.io, &reader_buffer);
        const out = try reader.interface.allocRemaining(self.allocator, .limited(64 * 1024 * 1024));
        const term = try child.wait(self.io);
        if (error_file) |handle| {
            handle.close(self.io);
            error_file = null;
        }
        if (!okay(term)) {
            if (self.display.quiet) {
                const detail = try std.Io.Dir.cwd().readFileAlloc(self.io, error_path, self.allocator, .limited(1024 * 1024));
                self.display.write("{s}", .{detail});
            }
            return error.GitFailed;
        }
        return std.mem.trim(u8, out, "\r\n");
    }

    pub fn commit(self: git, message: ?[]const u8, sign: ?bool) !void {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.allocator, &.{ "-c", "hook.groll.enabled=false", "commit" });
        if (self.display.quiet) try args.append(self.allocator, "--quiet");
        if (message) |m| try args.appendSlice(self.allocator, &.{ "-m", m });
        if (sign) |value| try args.append(self.allocator, if (value) "--gpg-sign" else "--no-gpg-sign");
        var child = try std.process.spawn(self.io, .{ .argv = try self.argv(args.items), .cwd = .{ .path = self.directory }, .stdout = .{ .file = std.Io.File.stderr() } });
        if (!okay(try child.wait(self.io))) return error.GitFailed;
    }

    pub fn verify(self: git, oid: []const u8) !void {
        const check = try self.call(&.{ "verify-commit", oid });
        if (!okay(check.term)) {
            self.display.write("{s}", .{check.stderr});
            return error.SignatureVerificationFailed;
        }
    }

    fn transaction(self: git, expected_branch: ?[]const u8, commands: []const u8, reason: []const u8) !void {
        var child = try std.process.spawn(self.io, .{ .argv = try self.argv(&.{ "update-ref", "--stdin", "-m", reason }), .cwd = .{ .path = self.directory }, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
        defer if (child.id != null) child.kill(self.io);
        try child.stdin.?.writeStreamingAll(self.io, try std.fmt.allocPrint(self.allocator, "start\n{s}prepare\n", .{commands}));
        try self.expectLine(child.stdout.?, "start: ok");
        try self.expectLine(child.stdout.?, "prepare: ok");
        // updating through head locks both head and its referent. check the
        // symbolic target while those locks are held, then commit or abort.
        const current_branch = try self.branch();
        if (!std.mem.eql(u8, current_branch orelse "HEAD", expected_branch orelse "HEAD")) return error.BranchChanged;
        if (roulette_stopped() != 0) return error.Canceled;
        try child.stdin.?.writeStreamingAll(self.io, "commit\n");
        try self.expectLine(child.stdout.?, "commit: ok");
        child.stdin.?.close(self.io);
        child.stdin = null;
        if (!okay(try child.wait(self.io))) return error.GitFailed;
    }

    fn expectLine(self: git, file: std.Io.File, expected: []const u8) !void {
        var buffer: [128]u8 = undefined;
        var n: usize = 0;
        while (n < buffer.len) {
            if (try file.readStreaming(self.io, &.{buffer[n..][0..1]}) == 0) return error.GitFailed;
            if (buffer[n] == '\n') {
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, buffer[0..n], "\r"), expected)) return error.GitFailed;
                return;
            }
            n += 1;
        }
        return error.GitFailed;
    }

    pub fn apply(self: git, branch_name: ?[]const u8, old: []const u8, new: []const u8) !void {
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const id = std.fmt.bytesToHex(random, .lower);
        const backup = try std.fmt.allocPrint(self.allocator, "refs/roulette/backups/{s}", .{id});
        const record_ref = "refs/worktree/roulette/undo";
        const previous = try self.optional(&.{ "rev-parse", "--verify", record_ref });
        const record = try std.fmt.allocPrint(self.allocator, "roulette-v1\n{s}\n{s}\n{s}\n{s}\n", .{ branch_name orelse "HEAD", old, new, previous orelse "-" });
        // store records as commit objects so the backup chain survives git gc.
        const tree = try self.text(&.{ "rev-parse", try std.fmt.allocPrint(self.allocator, "{s}^{{tree}}", .{old}) });
        const record_bytes = try std.fmt.allocPrint(self.allocator, "tree {s}\nparent {s}\nparent {s}\n{s}author roulette <roulette@localhost> 0 +0000\ncommitter roulette <roulette@localhost> 0 +0000\n\n{s}", .{ tree, old, new, if (previous) |p| try std.fmt.allocPrint(self.allocator, "parent {s}\n", .{p}) else "", record });
        const record_oid = try self.input(&.{ "hash-object", "-t", "commit", "-w", "--stdin" }, record_bytes);
        const guard = try std.fmt.allocPrint(self.allocator, "update HEAD {s} {s}\n", .{ new, old });
        const zero = try self.allocator.alloc(u8, old.len);
        @memset(zero, '0');
        const commands = try std.fmt.allocPrint(self.allocator, "{s}create {s} {s}\nupdate {s} {s} {s}\n", .{ guard, backup, old, record_ref, record_oid, previous orelse zero });
        try self.transaction(branch_name, commands, "roulette: jackpot");
    }

    pub fn undo(self: git) !void {
        const ref = "refs/worktree/roulette/undo";
        const record_oid = (try self.optional(&.{ "rev-parse", "--verify", ref })) orelse return error.NothingToUndo;
        const raw = try self.checked(&.{ "cat-file", "commit", record_oid });
        const separator = std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidUndoRecord;
        var lines = std.mem.splitScalar(u8, raw[separator + 2 ..], '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", "roulette-v1")) return error.InvalidUndoRecord;
        const recorded_branch = lines.next() orelse return error.InvalidUndoRecord;
        const old = lines.next() orelse return error.InvalidUndoRecord;
        const new = lines.next() orelse return error.InvalidUndoRecord;
        const previous = lines.next() orelse return error.InvalidUndoRecord;
        const current_branch = try self.branch();
        if (!std.mem.eql(u8, recorded_branch, current_branch orelse "HEAD") or !std.mem.eql(u8, try self.head(), new)) return error.BranchChanged;
        const guard = try std.fmt.allocPrint(self.allocator, "update HEAD {s} {s}\n", .{ old, new });
        const record_change = if (std.mem.eql(u8, previous, "-"))
            try std.fmt.allocPrint(self.allocator, "delete {s} {s}\n", .{ ref, record_oid })
        else
            try std.fmt.allocPrint(self.allocator, "update {s} {s} {s}\n", .{ ref, previous, record_oid });
        try self.transaction(current_branch, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ guard, record_change }), "roulette: undo");
        self.display.log("+", "restored {s}", .{old});
        try std.Io.File.stdout().writeStreamingAll(self.io, try std.fmt.allocPrint(self.allocator, "{s}\n", .{old}));
    }
};
