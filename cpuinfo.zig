const std = @import("std");
const builtin = @import("builtin");
const win32 = @cImport({
    @cInclude("windows.h");
});

// TODO: handle asymmetrical topologies
const CpuInfo = struct {
    name: []const u8,
    count: usize,
    max_mhz: u64,

    pub fn deinit(self: CpuInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub fn format(self: CpuInfo, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} ({} threads; ", .{ self.name, self.count });
        if (self.max_mhz >= 1000) {
            try writer.print("{d}GHz)", .{@intToFloat(f64, self.max_mhz) * 0.001});
        } else {
            try writer.print("{d}MHz)", .{self.max_mhz});
        }
    }
};

pub const get = switch (builtin.os.tag) {
    .linux => getLinux,
    .windows => getWindows,
    else => @compileError("Unsupported OS"),
};

fn getLinux(allocator: std.mem.Allocator) !CpuInfo {
    const f = try std.fs.openFileAbsolute("/proc/cpuinfo", .{});
    defer f.close();
    const r = f.reader();

    var key_buf: [64]u8 = undefined;
    const name = while (r.readUntilDelimiter(&key_buf, ':')) |key_full| {
        const key = std.mem.trim(u8, key_full, " \t\n");
        if (' ' != try r.readByte()) { // Skip leading space
            return error.InvalidFormat;
        }

        if (std.mem.eql(u8, key, "model name")) {
            const value = try r.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
            break value orelse return error.InvalidFormat;
        } else {
            try r.skipUntilDelimiterOrEof('\n');
        }
    } else |err| switch (err) {
        error.EndOfStream, error.StreamTooLong => return error.InvalidFormat,
        else => |e| return e,
    };
    errdefer allocator.free(name);

    const max_khz_str = try std.fs.cwd().readFileAlloc(
        allocator,
        "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq",
        32,
    );
    defer allocator.free(max_khz_str);
    const max_khz = std.fmt.parseInt(
        u64,
        std.mem.trimRight(u8, max_khz_str, "\n"),
        10,
    ) catch return error.InvalidFormat;
    const max_mhz = (max_khz + 500) / 1000; // Rounded division to convert kHz to MHz

    return CpuInfo{
        .name = name,
        .count = try std.Thread.getCpuCount(),
        .max_mhz = max_mhz,
    };
}

fn getWindows(allocator: std.mem.Allocator) !CpuInfo {
    if (!builtin.link_libc) {
        // Nicer error than the cimport error they'll get otherwise
        @compileError("On Windows targets, cpuinfo requires libc to be linked");
    }

    const key =
        \\Hardware\Description\System\CentralProcessor\0
    ;
    const name = try regGetValueStr(
        allocator,
        HKEY_LOCAL_MACHINE,
        key,
        "ProcessorNameString",
        .{ .type = .sz },
    );
    errdefer allocator.free(name);

    const max_mhz = try regGetValueInt(
        allocator,
        HKEY_LOCAL_MACHINE,
        key,
        "~MHz",
        .{ .type = .dword },
    );

    return CpuInfo{
        .name = name,
        .count = try std.Thread.getCpuCount(),
        .max_mhz = max_mhz,
    };
}

const RegGetValueFlags = struct {
    type: ?Type = null,
    noexpand: bool = false,

    const Type = enum(win32.DWORD) {
        binary = win32.RRF_RT_REG_BINARY,
        dword = win32.RRF_RT_DWORD,
        expand_sz = win32.RRF_RT_REG_EXPAND_SZ,
        multi_sz = win32.RRF_RT_REG_MULTI_SZ,
        none = win32.RRF_RT_REG_NONE,
        qword = win32.RRF_RT_QWORD,
        sz = win32.RRF_RT_REG_SZ,
    };

    fn dword(flags: RegGetValueFlags) win32.DWORD {
        var flags_dword: win32.DWORD = 0;
        if (flags.type) |t| {
            flags_dword |= @enumToInt(t);
        }
        if (flags.noexpand) flags_dword |= win32.RRF_NOEXPAND;
        return flags_dword;
    }
};

fn regGetValueStr(allocator: std.mem.Allocator, hkey: usize, key: [:0]const u8, name: [:0]const u8, flags: RegGetValueFlags) ![]const u8 {
    const flags_dword = flags.dword();

    const key16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, key);
    defer allocator.free(key16);
    const name16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, name);
    defer allocator.free(name16);

    var value_type: win32.DWORD = undefined;
    var buf_len: win32.DWORD = 16;
    var buf: []u16 = try allocator.alloc(u16, buf_len / 2);
    defer allocator.free(buf);
    while (true) {
        const err = RegGetValueW(hkey, key16, name16, flags_dword, &value_type, buf.ptr, &buf_len);
        switch (err) {
            0 => break, // SUCCESS
            2 => return error.MissingKey, // FILE_NOT_FOUND
            161 => return error.InvalidKey, // BAD_PATHNAME

            234 => { // MORE_DATA
                buf_len += buf_len / 2 + 16;
                buf = try allocator.realloc(buf, buf_len / 2);
            },

            else => return error.Unexpected,
        }
    }

    switch (value_type) {
        win32.REG_EXPAND_SZ, win32.REG_MULTI_SZ, win32.REG_SZ => {},
        else => return error.WrongType,
    }

    return std.unicode.utf16leToUtf8Alloc(allocator, buf[0 .. buf_len / 2 - 1]);
}

fn regGetValueInt(allocator: std.mem.Allocator, hkey: usize, key: [:0]const u8, name: [:0]const u8, flags: RegGetValueFlags) !u64 {
    const flags_dword = flags.dword();

    const key16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, key);
    defer allocator.free(key16);
    const name16 = try std.unicode.utf8ToUtf16LeWithNull(allocator, name);
    defer allocator.free(name16);

    var value_type: win32.DWORD = undefined;
    var value: u64 = 0;
    var value_len: win32.DWORD = @sizeOf(@TypeOf(value));
    const err = RegGetValueW(hkey, key16, name16, flags_dword, &value_type, &value, &value_len);
    switch (err) {
        0 => {}, // SUCCESS
        2 => return error.MissingKey, // FILE_NOT_FOUND
        161 => return error.InvalidKey, // BAD_PATHNAME
        234 => return error.WrongType, // MORE_DATA
        else => return error.Unexpected,
    }

    switch (value_type) {
        win32.REG_DWORD, win32.REG_QWORD => {},
        else => return error.WrongType,
    }

    return value;
}

extern fn RegGetValueW(
    hkey: usize,
    subkey: [*:0]u16,
    value: ?[*:0]u16,
    flags: win32.DWORD,
    type: ?*win32.DWORD,
    data: ?*c_void,
    data_len: ?*win32.DWORD,
) win32.LSTATUS;

const HKEY_CLASSES_ROOT = 0x80000000;
const HKEY_CURRENT_USER = 0x80000001;
const HKEY_LOCAL_MACHINE = 0x80000002;
const HKEY_USERS = 0x80000003;
const HKEY_PERFORMANCE_DATA = 0x80000004;
const HKEY_PERFORMANCE_TEXT = 0x80000050;
const HKEY_PERFORMANCE_NLSTEXT = 0x80000060;
const HKEY_CURRENT_CONFIG = 0x80000005;
const HKEY_DYN_DATA = 0x80000006;
const HKEY_CURRENT_USER_LOCAL_SETTINGS = 0x80000007;

test {
    const info = try get(std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(info.name.len > 0);
    try std.testing.expect(info.count > 0);
    try std.testing.expect(info.max_mhz > 0);

    var buf: [512]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{}", .{info});
}
