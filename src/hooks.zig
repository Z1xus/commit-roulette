const std = @import("std");
const git = @import("git.zig").git;
const ui = @import("ui.zig").ui;
const pattern = @import("miner.zig").pattern;

const command_key = "hook.groll.command";
const event_key = "hook.groll.event";
const owner_key = "hook.groll.managedCommand";
const help =
    \\groll hooks | automatic rolls after commits
    \\
    \\  groll hooks install --global beef
    \\  groll hooks uninstall --global
    \\  groll hooks status
    \\  groll hooks run beef              for an existing hook manager
    \\
    \\global setup requires git 2.54+.
    \\disable in one repo: git config --local hook.groll.enabled false
    \\skip one commit: git -c hook.groll.enabled=false commit ...
    \\
;

pub fn execute(init: std.process.Init, display: *ui, args: []const [:0]const u8) !?[:0]const u8 {
    var g: git = .{ .allocator = init.arena.allocator(), .io = init.io, .display = display };
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "--help"))) {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return null;
    }
    if (std.mem.eql(u8, args[0], "run")) {
        if (args.len != 2) return error.InvalidArguments;
        _ = try pattern.init(args[1], .prefix, 64);
        const enabled = try g.call(&.{ "config", "--type=bool", "--get", "hook.groll.enabled" });
        if (git.okay(enabled.term)) {
            if (std.mem.eql(u8, std.mem.trim(u8, enabled.stdout, "\r\n"), "false")) return null;
        } else if (!missing(enabled.term)) return error.GitFailed;
        if (try g.branch() == null) return null;
        for ([_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }) |path| {
            if (try g.exists(path)) return null;
        }
        return args[1];
    }
    if (std.mem.eql(u8, args[0], "status")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--global"))) return error.InvalidArguments;
        const configured = try config(g, &.{ "--global", "--includes", "--get-regexp", "^hook\\.groll\\." });
        display.write("[*] global groll hook settings:\n{s}", .{configured orelse "    not installed\n"});
        try requireVersion(g);
        display.write("[*] effective post-commit hooks in this directory:\n{s}", .{try g.checked(&.{ "hook", "list", "--show-scope", "post-commit" })});
        return null;
    }
    const install = std.mem.eql(u8, args[0], "install");
    const uninstall = std.mem.eql(u8, args[0], "uninstall");
    if ((!install and !uninstall) or args.len != @as(usize, if (install) 3 else 2)) return error.InvalidArguments;
    var target: ?[:0]const u8 = null;
    if (install) {
        if (std.mem.eql(u8, args[1], "--global")) target = args[2] else if (std.mem.eql(u8, args[2], "--global")) target = args[1] else return error.InvalidArguments;
        _ = try pattern.init(target.?, .prefix, 64);
    } else if (!std.mem.eql(u8, args[1], "--global")) return error.InvalidArguments;
    if (install) {
        try requireVersion(g);
        for ([_][]const []const u8{
            &.{ "--includes", "--get-regexp", "^hook\\.groll\\." },
            &.{ "--global", "--includes", "--get-regexp", "^hook\\.groll\\." },
        }) |query| {
            if (try config(g, query) != null) return error.HookConfigExists;
        }
        const exe = try std.process.executablePathAlloc(init.io, g.allocator);
        const command = try std.fmt.allocPrint(g.allocator, "{s} hooks run {s}", .{ try shellQuote(g.allocator, exe), target.? });
        _ = try g.checked(&.{ "config", "--global", "--add", owner_key, command });
        errdefer remove(g, owner_key, command) catch {};
        _ = try g.checked(&.{ "config", "--global", "--add", command_key, command });
        errdefer remove(g, command_key, command) catch {};
        _ = try g.checked(&.{ "config", "--global", "--add", event_key, "post-commit" });
        display.write("[+] global hook installed for prefix {s}\n[*] executable: {s}\n", .{ target.?, exe });
    } else {
        const owner = try single(g, owner_key);
        const command = try single(g, command_key);
        const event = try single(g, event_key);
        if (owner == null and command == null and event == null) {
            display.write("[*] no managed hook in the global config. included settings are left intact.\n", .{});
            return null;
        }
        if (owner == null or command == null or event == null or !std.mem.eql(u8, owner.?, command.?) or !std.mem.eql(u8, event.?, "post-commit")) return error.HookConfigChanged;
        try remove(g, event_key, event.?);
        try remove(g, command_key, command.?);
        try remove(g, owner_key, owner.?);
        display.write("[+] global groll hook removed. other settings were preserved.\n", .{});
    }
    return null;
}

fn missing(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 1;
}

fn config(g: git, args: []const []const u8) !?[]const u8 {
    const argv = try g.allocator.alloc([]const u8, args.len + 1);
    argv[0] = "config";
    @memcpy(argv[1..], args);
    const result = try g.call(argv);
    if (git.okay(result.term)) return result.stdout;
    if (missing(result.term)) return null;
    g.display.write("{s}", .{result.stderr});
    return error.GitFailed;
}

fn single(g: git, key: []const u8) !?[]const u8 {
    const value = (try config(g, &.{ "--global", "--no-includes", "--null", "--get-all", key })) orelse return null;
    if (value.len == 0 or value[value.len - 1] != 0 or std.mem.indexOfScalar(u8, value[0 .. value.len - 1], 0) != null) return error.HookConfigChanged;
    return value[0 .. value.len - 1];
}

fn remove(g: git, key: []const u8, value: []const u8) !void {
    _ = try g.checked(&.{ "config", "--global", "--no-includes", "--fixed-value", "--unset-all", key, value });
}

fn requireVersion(g: git) !void {
    const version = try g.text(&.{"--version"});
    var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, version, "git version "), '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    if (major < 2 or (major == 2 and minor < 54)) return error.HookGitTooOld;
}

fn shellQuote(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '\'');
    for (path) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, if (@import("builtin").os.tag == .windows and c == '\\') '/' else c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}
