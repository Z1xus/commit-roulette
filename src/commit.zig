const std = @import("std");
const git = @import("git.zig").git;
pub const template = struct { bytes: []u8, offset: usize, signed: bool };
const field = struct { start: usize, end: usize, name: []const u8 };

fn fields(allocator: std.mem.Allocator, raw: []const u8) ![]field {
    const end = std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidCommit;
    var out: std.ArrayList(field) = .empty;
    var start: usize = 0;
    while (start <= end) {
        const newline = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse return error.InvalidCommit;
        if (raw[start] == ' ') {
            if (out.items.len == 0) return error.InvalidCommit;
            out.items[out.items.len - 1].end = newline + 1;
        } else {
            const space = std.mem.indexOfScalar(u8, raw[start..newline], ' ') orelse return error.InvalidCommit;
            try out.append(allocator, .{ .start = start, .end = newline + 1, .name = raw[start .. start + space] });
        }
        start = newline + 1;
    }
    return out.toOwnedSlice(allocator);
}
fn signature(name: []const u8) bool {
    return std.mem.eql(u8, name, "gpgsig") or std.mem.eql(u8, name, "gpgsig-sha256");
}
pub fn isSigned(allocator: std.mem.Allocator, raw: []const u8) !bool {
    for (try fields(allocator, raw)) |f| if (signature(f.name)) return true;
    return false;
}
pub fn stripSignatures(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    for (try fields(allocator, raw)) |f| {
        if (signature(f.name)) {
            try out.appendSlice(allocator, raw[copied..f.start]);
            copied = f.end;
        }
    }
    try out.appendSlice(allocator, raw[copied..]);
    return out.toOwnedSlice(allocator);
}
pub fn prepare(allocator: std.mem.Allocator, raw: []const u8) !template {
    var sig: ?field = null;
    var nonce: ?field = null;
    for (try fields(allocator, raw)) |f| {
        if (signature(f.name)) {
            if (sig != null) return error.MultipleSignaturesUnsupported;
            sig = f;
        }
        if (std.mem.eql(u8, f.name, "roulette")) {
            if (nonce != null) return error.InvalidNonceHeader;
            nonce = f;
        }
    }
    if (sig) |f| {
        const block = raw[f.start..f.end];
        if (std.mem.indexOf(u8, block, "-----BEGIN SSH SIGNATURE-----") == null and std.mem.indexOf(u8, block, "-----BEGIN PGP SIGNATURE-----") == null) return error.SignatureFormatUnsupported;
        // mutate only trailing armor whitespace. binary signature bytes stay identical.
        var at = std.mem.indexOfScalar(u8, block, '\n') orelse return error.InvalidCommit;
        at += 1;
        while (at < block.len) {
            const end = std.mem.indexOfScalarPos(u8, block, at, '\n') orelse return error.InvalidCommit;
            const line = std.mem.trim(u8, block[at..end], " \t\r");
            if (line.len > 0 and line[0] != '-' and line[0] != '=' and std.mem.indexOfScalar(u8, line, ':') == null) {
                var tail = end;
                while (tail > at and (block[tail - 1] == ' ' or block[tail - 1] == '\t' or block[tail - 1] == '\r')) tail -= 1;
                const offset = f.start + tail;
                const bytes = try std.mem.concat(allocator, u8, &.{ raw[0..offset], &(@as([64]u8, @splat(' '))), raw[f.start + end ..] });
                return .{ .bytes = bytes, .offset = offset, .signed = true };
            }
            at = end + 1;
        }
        return error.InvalidCommit;
    }
    if (nonce) |f| {
        const value = std.mem.trimEnd(u8, raw[f.start + 9 .. f.end], "\n");
        if (value.len != 16) return error.InvalidNonceHeader;
        for (value) |c| _ = std.fmt.charToDigit(c, 16) catch return error.InvalidNonceHeader;
        return .{ .bytes = try allocator.dupe(u8, raw), .offset = f.start + 9, .signed = false };
    }
    const end = (std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidCommit) + 1;
    return .{ .bytes = try std.mem.concat(allocator, u8, &.{ raw[0..end], "roulette 0000000000000000\n", raw[end..] }), .offset = end + 9, .signed = false };
}

pub fn sign(g: git, raw: []const u8) ![]const u8 {
    const format = (try g.optional(&.{ "config", "--get", "gpg.format" })) orelse "openpgp";
    var key = try g.optional(&.{ "config", "--get", "user.signingkey" });
    var result: []const u8 = undefined;
    if (std.mem.eql(u8, format, "ssh")) {
        if (key == null) {
            const command = (try g.optional(&.{ "config", "--get", "gpg.ssh.defaultKeyCommand" })) orelse return error.SigningKeyMissing;
            const output = try g.text(&.{ "-c", try std.fmt.allocPrint(g.allocator, "alias.roulette-key=!{s}", .{command}), "roulette-key" });
            key = output[0 .. std.mem.indexOfScalar(u8, output, '\n') orelse output.len];
        }
        var key_path = key.?;
        var literal_path: ?[]const u8 = null;
        defer if (literal_path) |path| std.Io.Dir.cwd().deleteFile(g.io, path) catch {};
        const literal = if (std.mem.startsWith(u8, key_path, "key::")) key_path[5..] else if (std.mem.startsWith(u8, key_path, "ssh-")) key_path else null;
        if (literal) |public| {
            var random: [16]u8 = undefined;
            g.io.random(&random);
            const base = try g.text(&.{ "rev-parse", "--path-format=absolute", "--git-path", "roulette-tmp" });
            try std.Io.Dir.cwd().createDirPath(g.io, base);
            key_path = try std.fmt.allocPrint(g.allocator, "{s}/key-{s}.pub", .{ base, std.fmt.bytesToHex(random, .lower) });
            try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = key_path, .data = public, .flags = .{ .exclusive = true } });
            literal_path = key_path;
        } else key_path = (try g.optional(&.{ "config", "--path", "--get", "user.signingkey" })) orelse key_path;
        const program = (try g.optional(&.{ "config", "--get", "gpg.ssh.program" })) orelse "ssh-keygen";
        result = try g.inputTool(&.{ program, "-Y", "sign", "-n", "git", "-f", key_path }, raw);
    } else if (std.mem.eql(u8, format, "openpgp")) {
        const program = (try g.optional(&.{ "config", "--get", "gpg.openpgp.program" })) orelse (try g.optional(&.{ "config", "--get", "gpg.program" })) orelse "gpg";
        if (key == null) {
            const ident = try g.text(&.{ "var", "GIT_COMMITTER_IDENT" });
            const end = std.mem.lastIndexOfScalar(u8, ident, '>') orelse return error.SigningKeyMissing;
            key = ident[0 .. end + 1];
        }
        result = try g.inputTool(&.{ program, "--status-fd=2", "-bsau", key.? }, raw);
    } else return error.SignatureFormatUnsupported;
    var out: std.ArrayList(u8) = .empty;
    const end = (std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidCommit) + 1;
    try out.appendSlice(g.allocator, raw[0..end]);
    const object_format = try g.text(&.{ "rev-parse", "--show-object-format" });
    try out.appendSlice(g.allocator, if (std.mem.eql(u8, object_format, "sha256")) "gpgsig-sha256 " else "gpgsig ");
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(g.allocator, ' ');
        first = false;
        try out.appendSlice(g.allocator, std.mem.trimEnd(u8, line, "\r"));
        try out.append(g.allocator, '\n');
    }
    try out.appendSlice(g.allocator, raw[end..]);
    return out.toOwnedSlice(g.allocator);
}
