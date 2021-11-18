# cpuinfo

This is a small Zig library for getting CPU information on Linux and Windows machines.
It can report the CPU's name, number of logical cores (aka CPU threads), and approximate maximum clock speed.

## Usage

```zig
const cpuinfo = @import("cpuinfo");

// Get CPU information
const info = try cpuinfo.get(allocator);
defer info.deinit(allocator);

// Print out in a human-readable format
std.debug.print("{}\n", .{info});

// Print out in a custom format
std.debug.print("{s}; {d} threads @ {d}MHz\n", .{info.name, info.count, info.max_mhz});
```

## Known issues

- Does not properly handle asymmetrical CPU topologies
