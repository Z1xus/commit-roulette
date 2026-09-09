const std = @import("std");
const git = @import("git.zig").git;
const commit = @import("commit.zig");
const miner = @import("miner.zig");
const hash = @import("hash.zig");
const ui = @import("ui.zig").ui;
const version = @import("build_options").version;
const help =
    \\groll | deal yourself a better hash
    \\
    \\  groll                     guided prompts
    \\  groll beef                roll the latest commit
    \\  groll commit beef [-m …]   commit staged files, then roll
    \\  groll undo                undo the last roll
    \\
    \\  --suffix / --contains     match end / anywhere, default: prefix
    \\  --sign / --no-sign        enable / disable signing
    \\  --threads <n>             worker count, default: all cpus
    \\  --no-animation / --quiet  plain logs / hash only
    \\  --help / --version
    \\
;
const options = struct {
    action: []const u8 = "",
    target: []const u8 = "",
    where: miner.position = .prefix,
    message: ?[]const u8 = null,
    sign: ?bool = null,
    threads: usize = 0,
    quiet: bool = false,
    no_animation: bool = false,
    help: bool = false,
    version: bool = false,
};

pub fn main(init: std.process.Init) void {
    var display: ui = .{ .io = init.io, .allocator = init.gpa };
    execute(init, &display) catch |err| {
        display.clear();
        const message: []const u8 = switch (err) {
            error.Canceled => "roll canceled. the branch was not changed by mining.",
            error.EndOfStream => "input ended. no roll started.",
            error.InvalidTarget => "use a hexadecimal target, such as beef or cafe.",
            error.InvalidTargetLength => "target length must fit the repository hash: 1-40 digits for sha-1, 1-64 for sha-256.",
            error.InvalidThreads => "use --threads with a whole number from 1 to 4096.",
            error.ConflictingOptions => "choose one match position and one signing option.",
            error.MissingValue => "an option needs a value. run groll --help.",
            error.InvalidArguments => "unknown command or option. run groll --help.",
            error.UnfinishedGitOperation => "finish or abort the current merge, rebase, or cherry-pick before rolling.",
            error.GitTooOld => "git 2.48 or newer is required for safe branch transactions.",
            error.GitFailed => "git stopped the operation. see its message above.",
            error.FileNotFound => "a required command or file is missing. check that git and your signing tool are available.",
            error.SignatureVerificationFailed => "signature verification failed. check git verify-commit and your signing trust settings. no winner was applied.",
            error.SigningKeyMissing => "no signing key is configured. set user.signingkey in git.",
            error.SignatureFormatUnsupported => "this build supports ssh and gpg signatures only.",
            error.MultipleSignaturesUnsupported => "commits with multiple signatures are not supported by this build.",
            error.InvalidNonceHeader => "the existing roulette header is not a valid mining counter.",
            error.BranchChanged => "the branch changed. no update was applied. run the command again on the intended branch.",
            error.NothingToUndo => "there is no winning roll to undo in this worktree.",
            error.SearchExhausted => "the counter range is exhausted. use a shorter target.",
            error.HashMismatch => "the candidate hash did not match git. no winner was applied.",
            else => "the operation could not finish.",
        };
        display.write("[{s}] {s}\n", .{ if (err == error.Canceled) "!" else "-", message });
        if (std.mem.eql(u8, message, "the operation could not finish.")) {
            const name = @errorName(err);
            var detail: [128]u8 = undefined;
            const n = @min(name.len, detail.len);
            for (name[0..n], 0..) |c, i| detail[i] = std.ascii.toLower(c);
            display.write("[-] detail: {s}\n", .{detail[0..n]});
        }
        std.process.exit(if (err == error.Canceled) 130 else 1);
    };
}

fn parse(args: []const [:0]const u8) !options {
    var opt: options = .{};
    var match_set = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opt.help = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--version")) {
            opt.version = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--quiet")) {
            opt.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-animation")) {
            opt.no_animation = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--suffix") or std.mem.eql(u8, a, "--contains")) {
            if (match_set) return error.ConflictingOptions;
            match_set = true;
            opt.where = if (std.mem.eql(u8, a, "--suffix")) .suffix else .contains;
            continue;
        }
        if (std.mem.eql(u8, a, "--sign") or std.mem.eql(u8, a, "--no-sign")) {
            if (opt.sign != null) return error.ConflictingOptions;
            opt.sign = std.mem.eql(u8, a, "--sign");
            continue;
        }
        if (std.mem.eql(u8, a, "--threads") or std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            if (std.mem.eql(u8, a, "-m")) {
                if (opt.message != null) return error.InvalidArguments;
                opt.message = args[i];
            } else {
                opt.threads = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidThreads;
                if (opt.threads == 0 or opt.threads > 4096) return error.InvalidThreads;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) return error.InvalidArguments;
        if (opt.action.len == 0) {
            if (std.mem.eql(u8, a, "roll") or std.mem.eql(u8, a, "commit") or std.mem.eql(u8, a, "undo")) {
                opt.action = a;
            } else {
                opt.action = "roll";
                opt.target = a;
            }
        } else if (opt.target.len == 0) opt.target = a else return error.InvalidArguments;
    }
    if (opt.help or opt.version) return opt;
    if (opt.action.len > 0 and !std.mem.eql(u8, opt.action, "roll") and !std.mem.eql(u8, opt.action, "commit") and !std.mem.eql(u8, opt.action, "undo")) return error.InvalidArguments;
    if (std.mem.eql(u8, opt.action, "undo") and (opt.target.len > 0 or opt.sign != null or opt.message != null or match_set or opt.threads != 0)) return error.InvalidArguments;
    if (!std.mem.eql(u8, opt.action, "commit") and opt.message != null) return error.InvalidArguments;
    return opt;
}

fn execute(init: std.process.Init, display: *ui) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var opt = try parse(args);
    if (opt.help) return std.Io.File.stdout().writeStreamingAll(init.io, help);
    if (opt.version) return std.Io.File.stdout().writeStreamingAll(init.io, "groll " ++ version ++ "\n");
    const input_tty = try std.Io.File.stdin().isTty(init.io);
    const output_tty = try std.Io.File.stderr().isTty(init.io);
    display.quiet = opt.quiet;
    const ansi = if (output_tty) available: {
        std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch break :available false;
        break :available true;
    } else false;
    display.animate = ansi and !opt.no_animation;
    display.color = ansi and init.environ_map.get("NO_COLOR") == null and init.environ_map.get("no_color") == null;
    if (opt.action.len == 0) {
        if (!input_tty or !output_tty or opt.quiet) return std.Io.File.stdout().writeStreamingAll(init.io, help);
        display.log("*", "take a seat. choose your next hash.", .{});
        while (true) {
            opt.action = try display.prompt(allocator, "roll the latest commit, or commit staged files?", "roll");
            if (std.mem.eql(u8, opt.action, "roll") or std.mem.eql(u8, opt.action, "commit")) break;
            display.log("!", "enter roll or commit.", .{});
        }
    }
    if (!std.mem.eql(u8, opt.action, "undo") and opt.target.len == 0) {
        if (!input_tty or !output_tty or opt.quiet) return error.MissingValue;
        while (true) {
            opt.target = try display.prompt(allocator, "winning hex digits", "beef");
            _ = miner.pattern.init(opt.target, .prefix, 64) catch {
                display.log("!", "use 1-64 hexadecimal digits.", .{});
                continue;
            };
            break;
        }
        while (true) {
            const where = try display.prompt(allocator, "match prefix, suffix, or contains?", "prefix");
            opt.where = std.meta.stringToEnum(miner.position, where) orelse {
                display.log("!", "enter prefix, suffix, or contains.", .{});
                continue;
            };
            break;
        }
    }
    var g: git = .{ .allocator = allocator, .io = init.io, .display = display };
    try g.preflight();
    if (std.mem.eql(u8, opt.action, "undo")) return g.undo();
    const format = try g.text(&.{ "rev-parse", "--show-object-format" });
    const kind: hash.algorithm = if (std.mem.eql(u8, format, "sha1")) .sha1 else if (std.mem.eql(u8, format, "sha256")) .sha256 else return error.UnsupportedHashFormat;
    const pattern = try miner.pattern.init(opt.target, opt.where, if (kind == .sha1) 40 else 64);
    if (opt.threads == 0) opt.threads = @min(std.Thread.getCpuCount() catch 1, 4096);
    const branch = try g.branch();
    if (std.mem.eql(u8, opt.action, "commit")) {
        try g.commit(opt.message, opt.sign);
        display.log("*", "normal commit created. canceling now keeps it.", .{});
    }
    const old = try g.head();
    var raw = try g.checked(&.{ "cat-file", "commit", old });
    const original_raw = raw;
    const originally_signed = try commit.isSigned(allocator, raw);
    if (opt.sign == false) {
        raw = try commit.stripSignatures(allocator, raw);
    } else if (originally_signed) {
        try g.verify(old);
    } else if (opt.sign == true) {
        raw = try commit.sign(g, raw);
        const signed_oid = try g.input(&.{ "hash-object", "-t", "commit", "-w", "--stdin" }, raw);
        try g.verify(signed_oid);
    }
    var old_digest: [32]u8 = undefined;
    if (std.mem.eql(u8, raw, original_raw) and pattern.matches(try std.fmt.hexToBytes(&old_digest, old))) {
        display.log("+", "already a winner  {s}", .{old});
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(allocator, "{s}\n", .{old}));
        return;
    }
    const prepared = try commit.prepare(allocator, raw);
    // check the formatting before spending time mining it.
    if (prepared.signed) {
        const check_oid = try g.input(&.{ "hash-object", "-t", "commit", "-w", "--stdin" }, prepared.bytes);
        try g.verify(check_oid);
    }
    const target = try std.ascii.allocLowerString(allocator, opt.target);
    const engine = if (init.environ_map.get("ROULETTE_HASH_BACKEND")) |value| if (std.mem.eql(u8, value, "portable")) hash.backend.portable else hash.detect() else hash.detect();
    display.log("*", "target  {s}  |  {s}  |  {s}", .{ target, @tagName(opt.where), if (prepared.signed) "signed" else "unsigned" });
    display.log("*", "{d} workers  |  {s} cpu  |  ctrl-c to stop", .{ opt.threads, @tagName(engine) });
    if (branch == null) display.log("*", "detached head. the winning commit will stay detached.", .{});
    const result = try miner.mine(init.gpa, init.io, display, prepared.bytes, prepared.offset, prepared.signed, kind, pattern, opt.threads, engine);
    defer init.gpa.free(result.bytes);
    const winner = try g.input(&.{ "hash-object", "-t", "commit", "-w", "--stdin" }, result.bytes);
    var digest: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&digest, winner) catch return error.HashMismatch;
    if (!pattern.matches(decoded)) return error.HashMismatch;
    if (prepared.signed) try g.verify(winner);
    if (!std.mem.eql(u8, old, try g.head())) return error.BranchChanged;
    const now_branch = try g.branch();
    if (!std.mem.eql(u8, branch orelse "HEAD", now_branch orelse "HEAD")) return error.BranchChanged;
    if (!std.mem.eql(u8, old, winner)) try g.apply(branch, old, winner);
    const match_at = switch (opt.where) {
        .prefix => @as(usize, 0),
        .suffix => winner.len - target.len,
        .contains => std.mem.indexOf(u8, winner, target).?,
    };
    display.finish(winner[match_at..][0..target.len]);
    if (display.color) {
        const at = match_at;
        display.log("+", "jackpot  {s}\x1b[32m{s}\x1b[0m{s}", .{ winner[0..at], winner[at..][0..target.len], winner[at + target.len ..] });
    } else display.log("+", "jackpot  {s}", .{winner});
    display.log("*", "{d} tries  |  {d:.2} mh/s  |  {d:.3}s", .{ result.tries, @as(f64, @floatFromInt(result.tries)) / @max(result.seconds, 0.000001) / 1e6, result.seconds });
    const branch_label = if (branch) |name| if (std.mem.startsWith(u8, name, "refs/heads/")) name[11..] else name else "detached head";
    display.log("+", "updated {s}", .{branch_label});
    display.log("*", "undo: groll undo", .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(allocator, "{s}\n", .{winner}));
}
