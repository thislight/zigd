// This file is part of zigd
// SPDX: GPL-3.0-or-later
const std = @import("std");
const clap = @import("clap");

const Toolchain = struct {
    root: []const u8,
    cc: []const u8,
    cxx: []const u8,
    @"asm": []const u8,
    zig: []const u8,

    const CACHED_KEYS = &.{ "cc", "c++", "ccache cc", "ccache c++", "/", "zig" };

    fn isToolExists(allocator: std.mem.Allocator, name: []const u8) bool {
        const child = std.process.Child.run(.{ .allocator = allocator, .argv = &.{name} }) catch |err| switch (err) {
            error.StderrStreamTooLong, error.StdoutStreamTooLong => return true,
            else => return false,
        };
        allocator.free(child.stderr);
        allocator.free(child.stdout);
        return true;
    }

    fn fromGlobal(allocator: std.mem.Allocator) !Toolchain {
        var envmap = try std.process.getEnvMap(allocator);
        defer envmap.deinit();

        const has_ccache = isToolExists(allocator, "ccache");

        const cc = if (envmap.get("CC")) |v| try allocator.dupe(u8, v) else if (has_ccache) CACHED_KEYS[2] else CACHED_KEYS[0];
        const cxx = if (envmap.get("CXX")) |v| try allocator.dupe(u8, v) else if (has_ccache) CACHED_KEYS[3] else CACHED_KEYS[1];
        const @"asm" = if (envmap.get("ASM")) |v| try allocator.dupe(u8, v) else if (has_ccache) CACHED_KEYS[2] else CACHED_KEYS[0];

        return .{
            .cc = cc,
            .cxx = cxx,
            .@"asm" = @"asm",
            .root = CACHED_KEYS[4],
            .zig = CACHED_KEYS[5],
        };
    }

    fn deinit(self: *Toolchain, allocator: std.mem.Allocator) void {
        eachName: for ([_][]const u8{ self.root, self.cc, self.cxx, self.@"asm", self.zig }) |name| {
            inline for (CACHED_KEYS) |cache| {
                if (cache.ptr == name.ptr) {
                    continue :eachName;
                }
            }
            allocator.free(name);
        }
        self.* = undefined;
    }

    fn apply(self: Toolchain, envmap: *std.process.EnvMap) !void {
        if (self.cc.ptr != CACHED_KEYS[0].ptr or self.cc.len != CACHED_KEYS[0].len) {
            try envmap.put("CC", self.cc);
        }
        if (self.cxx.ptr != CACHED_KEYS[1].ptr or self.cxx.len != CACHED_KEYS[1].len) {
            try envmap.put("CXX", self.cxx);
        }
        if (self.@"asm".ptr != CACHED_KEYS[0].ptr or self.@"asm".len != CACHED_KEYS[0].len) {
            try envmap.put("ASM", self.@"asm");
        }
    }
};

const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    /// [0] = the zig-bootstrap name,
    /// [1]...[3] = the stage1...stage3 name.
    staged_names: [4][]u8,

    fn fromGlobal(allocator: std.mem.Allocator) error{ TreeEnvVarNotFound, OutOfMemory }!Tree {
        var arena = std.heap.ArenaAllocator.init(allocator);

        if (std.posix.getenvZ("ZIGD_TREE")) |treeRootName| {
            const rootName = if (std.fs.path.isAbsolute(treeRootName))
                try arena.allocator().dupe(u8, treeRootName)
            else
                try std.fs.path.resolve(arena.allocator(), &.{ ".", treeRootName });

            var stageds: [4][]u8 = undefined;

            stageds[0] = try std.fs.path.resolve(arena.allocator(), &.{ rootName, "build", "zig-bootstrap" });

            inline for (1..4) |i| {
                stageds[i] = try std.fs.path.resolve(
                    arena.allocator(),
                    &.{ rootName, "build", std.fmt.comptimePrint("stage{}", .{i}) },
                );
            }

            return .{
                .root = rootName,
                .arena = arena,
                .staged_names = stageds,
            };
        } else {
            return error.TreeEnvVarNotFound;
        }
    }

    fn deinit(self: *Tree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn bootstrapToolsTargetHost(self: Tree, allocator: std.mem.Allocator) !Toolchain {
        const base = self.staged_names[0];
        const zig = try std.fs.path.resolve(
            allocator,
            &.{
                base,
                "out",
                "zig-" ++ BOOTSTRAP_TARGET_TEXT ++ "-" ++ BOOTSTRAP_CPU_TEXT,
                "zig",
            },
        );
        errdefer allocator.free(zig);
        const root = try std.fs.path.resolve(allocator, &.{
            base, "out", BOOTSTRAP_TARGET_TEXT ++ "-" ++ BOOTSTRAP_CPU_TEXT,
        });
        errdefer allocator.free(root);

        return try toolsFromZigTargetHost(allocator, root, zig);
    }

    fn stage1ToolsTargetHost(self: Tree, allocator: std.mem.Allocator) !Toolchain {
        const zig = try std.fs.path.resolve(allocator, &.{ self.staged_names[1], "stage3", "bin", "zig" });
        errdefer allocator.free(zig);

        const root = try std.fs.path.resolve(allocator, &.{ self.staged_names[0], "out", BOOTSTRAP_TARGET_TEXT ++ "-" ++ BOOTSTRAP_CPU_TEXT });
        errdefer allocator.free(root);

        return try toolsFromZigTargetHost(allocator, root, zig);
    }

    fn stage2ToolsTargetHost(self: Tree, allocator: std.mem.Allocator) !Toolchain {
        const zig = try std.fs.path.resolve(allocator, &.{ self.staged_names[2], "bin", "zig" });
        errdefer allocator.free(zig);

        const root = try std.fs.path.resolve(allocator, &.{ self.staged_names[0], "out", BOOTSTRAP_TARGET_TEXT ++ "-" ++ BOOTSTRAP_CPU_TEXT });
        errdefer allocator.free(root);

        return try toolsFromZigTargetHost(allocator, root, zig);
    }

    fn stage3ToolsTargetHost(self: Tree, allocator: std.mem.Allocator) !Toolchain {
        const zig = try std.fs.path.resolve(allocator, &.{ self.staged_names[3], "bin", "zig" });
        errdefer allocator.free(zig);

        const root = try std.fs.path.resolve(allocator, &.{ self.staged_names[0], "out", BOOTSTRAP_TARGET_TEXT ++ "-" ++ BOOTSTRAP_CPU_TEXT });
        errdefer allocator.free(root);

        return try toolsFromZigTargetHost(allocator, root, zig);
    }

    fn toolsFromZigTargetHost(allocator: std.mem.Allocator, root: []const u8, zig: []const u8) !Toolchain {
        const print = std.fmt.allocPrintZ;
        const cc = try print(
            allocator,
            "{s} cc -target {s} -mcpu={s}",
            .{ zig, BOOTSTRAP_TARGET_TEXT, BOOTSTRAP_CPU_TEXT },
        );
        errdefer allocator.free(cc);
        const cxx = try print(
            allocator,
            "{s} c++ -target {s} -mcpu={s}",
            .{ zig, BOOTSTRAP_TARGET_TEXT, BOOTSTRAP_CPU_TEXT },
        );
        errdefer allocator.free(cxx);
        const @"asm" = try print(
            allocator,
            "{s} cc -target {s} -mcpu={s}",
            .{ zig, BOOTSTRAP_TARGET_TEXT, BOOTSTRAP_CPU_TEXT },
        );
        errdefer allocator.free(@"asm");

        return Toolchain{
            .cc = cc,
            .cxx = cxx,
            .@"asm" = @"asm",
            .root = root,
            .zig = zig,
        };
    }
};

const HELP_BUILD =
    \\zigd build [...stage]
    \\
    \\Available Stages:
    \\bootstrap - LLVM and Zig from zig-bootstrap.
    \\            The cmake, ninja and stage 0 compiler must be available.
    \\stage1 - Zig from source with cmake.
    \\         The cmake and ninja must be available.
    \\         (This step is required because the old build runner may not be
    \\          able to run new build.zig)
    \\stage2 - Zig from source with zig build.
    \\stage3 - Zig with -Doptimize=Debug.
    \\
    \\The order of stages won't affect the build order.
    \\
    \\Environment Variables:
    \\CC, CXX, ASM - See "zigd stage0 -h". Available for bootstrap and stage1.
    \\
    \\Options:
    \\-h/--help - Print the message and exit.
    \\
;

fn build(allocator: std.mem.Allocator, arg_it: *std.process.ArgIterator) !void {
    const Flags = struct {
        bootstrap: bool = false,
        stage1: bool = false,
        stage2: bool = false,
        stage3: bool = false,
        help: bool = false,
    };

    var flags: Flags = .{};

    while (arg_it.next()) |arg| {
        const eql = std.mem.eql;
        if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            flags.help = true;
        } else if (eql(u8, arg, "bootstrap")) {
            flags.bootstrap = true;
        } else if (eql(u8, arg, "stage1")) {
            flags.stage1 = true;
        } else if (eql(u8, arg, "stage2")) {
            flags.stage2 = true;
        } else if (eql(u8, arg, "stage3")) {
            flags.stage3 = true;
        } else {
            try std.fmt.format(std.io.getStdErr().writer(), "Unknown argument \"{s}\".\n", .{arg});
            return error.UnknownArgument;
        }
    }

    if (flags.help) {
        try std.io.getStdOut().writeAll(HELP_BUILD);
        return;
    }

    var tree = try Tree.fromGlobal(allocator);
    defer tree.deinit();

    const node = std.Progress.start(.{ .root_name = "zigd build" });
    defer node.end();
    for ([_]bool{ flags.bootstrap, flags.stage1, flags.stage2, flags.stage3 }) |b| {
        if (b) {
            node.increaseEstimatedTotalItems(1);
        }
    }

    if (flags.bootstrap) {
        var tools = try Toolchain.fromGlobal(allocator);
        defer tools.deinit(allocator);

        const pnode = node.start("bootstrap", 0);
        defer pnode.end();
        try buildBootstrap(allocator, pnode, tree, tools);
    }

    if (flags.stage1) {
        var tools = try tree.bootstrapToolsTargetHost(allocator);
        defer tools.deinit(allocator);

        const pnode = node.start("stage1", 0);
        defer pnode.end();
        try buildStage1(allocator, pnode, tree, tools);
    }

    if (flags.stage2) {
        var tools = try tree.stage1ToolsTargetHost(allocator);
        defer tools.deinit(allocator);

        const pnode = node.start("stage2", 0);
        defer pnode.end();
        try buildStage2(allocator, pnode, tree, tools);
    }

    if (flags.stage3) {
        var tools = try tree.stage2ToolsTargetHost(allocator);
        defer tools.deinit(allocator);

        const pnode = node.start("stage3", 0);
        defer pnode.end();
        try buildStage3(allocator, pnode, tree, tools);
    }
}

const TARGET_OS_TEXT = @tagName(@import("builtin").target.os.tag);
const BOOTSTRAP_TARGET_TEXT = "native-" ++ TARGET_OS_TEXT ++ "-musl";
const BOOTSTRAP_CPU_TEXT = "baseline";

fn buildBootstrap(allocator: std.mem.Allocator, progress: std.Progress.Node, tree: Tree, tools: Toolchain) !void {
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();
    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    var dir = std.fs.openDirAbsolute(tree.staged_names[0], .{}) catch clone_bootstrap: {
        progress.increaseEstimatedTotalItems(1);

        var clone_process = std.process.Child.init(
            &.{ "git", "clone", "https://github.com/ziglang/zig-bootstrap.git", tree.staged_names[0] },
            allocator,
        );
        clone_process.stdout_behavior = .Pipe;
        clone_process.stderr_behavior = .Pipe;
        try clone_process.spawn();
        errdefer _ = clone_process.kill() catch {};

        const clone_node = progress.start(
            "git clone https://github.com/ziglang/zig-bootstrap.git",
            0,
        );
        try clone_process.collectOutput(&stdout, &stderr, 1024 * 64);
        const result = try clone_process.wait();
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    try std.io.getStdErr().writeAll(stdout.items);
                    std.debug.print("git clone returns {}.\n", .{code});
                    return error.ExternalError;
                }
            },
            else => {
                std.debug.print("git clone stopped with {}.\n", .{result});
                return error.ExternalError;
            },
        }
        clone_node.end();
        progress.completeOne();

        break :clone_bootstrap try std.fs.openDirAbsolute(tree.staged_names[0], .{});
    };
    defer dir.close();

    try dir.deleteTree("./out");

    const isGitManaged: bool = if (dir.access(".git", .{})) |_| true else |_| false;

    if (!isGitManaged) {
        std.debug.print("TODO: support not git managed zig-bootstrap.\n", .{});
        return error.NotGitManaged;
    }

    progress.increaseEstimatedTotalItems(2);

    {
        defer progress.completeOne();

        const pull_progress = progress.start("git pull", 0);
        defer pull_progress.end();

        var pull_process = std.process.Child.init(&.{ "git", "pull" }, allocator);
        pull_process.cwd_dir = dir;
        pull_process.stdout_behavior = .Pipe;
        pull_process.stderr_behavior = .Pipe;

        try pull_process.spawn();
        errdefer _ = pull_process.kill() catch {};
        try pull_process.collectOutput(&stdout, &stderr, 1024 * 64);

        const result = try pull_process.wait();
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("git pull returns {}.\n", .{code});
                    return error.ExternalError;
                }
            },
            else => {
                std.debug.print("git pull stopped with {}.\n", .{result});
                return error.ExternalError;
            },
        }
    }

    {
        defer progress.completeOne();

        const name = switch (@import("builtin").target.os.tag) {
            .windows => "./build.bat",
            else => "./build",
        };

        const build_progress = progress.start(name, 0);
        defer build_progress.end();

        var envmap = try std.process.getEnvMap(allocator);
        defer envmap.deinit();
        try envmap.put("NINJA_STATUS", "[%f/%t] ");
        try envmap.put("CMAKE_GENERATOR", "Ninja");
        try tools.apply(&envmap);

        var build_process = std.process.Child.init(
            &.{ name, BOOTSTRAP_TARGET_TEXT, BOOTSTRAP_CPU_TEXT },
            allocator,
        );
        build_process.env_map = &envmap;
        build_process.cwd_dir = dir;
        build_process.stderr_behavior = .Pipe;
        build_process.stdout_behavior = .Pipe;
        build_process.progress_node = build_progress;

        var stderr_buf = std.fifo.LinearFifo(u8, .Dynamic).init(allocator);
        defer stderr_buf.deinit();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try build_process.spawn();
        errdefer _ = build_process.kill() catch {};

        var poller = std.io.poll(allocator, enum { stderr, stdout }, .{
            .stderr = build_process.stdout.?,
            .stdout = build_process.stderr.?,
        });
        defer poller.deinit();

        while (try poller.poll()) {
            buffer.clearRetainingCapacity();

            if (poller.fifo(.stdout).readableLength() > 0) {
                poller.fifo(.stdout).reader().readUntilDelimiterArrayList(
                    &buffer,
                    '\n',
                    1024 * 16,
                ) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.StreamTooLong => continue,
                    else => return err,
                };

                if (buffer.items.len > 0) {
                    const start_idx = std.mem.indexOfScalar(u8, buffer.items, '[') orelse continue;
                    const sep_idx = std.mem.indexOfScalarPos(u8, buffer.items, start_idx, '/') orelse continue;
                    const end_idx = std.mem.indexOfScalarPos(u8, buffer.items, sep_idx, ']') orelse continue;
                    const finished_count_text = buffer.items[start_idx + 1 .. sep_idx];
                    const total_count_text = buffer.items[sep_idx + 1 .. end_idx];

                    const total_count = std.fmt.parseUnsigned(usize, total_count_text, 10) catch continue;
                    build_progress.setEstimatedTotalItems(total_count);
                    const finished_count = std.fmt.parseUnsigned(usize, finished_count_text, 10) catch continue;
                    build_progress.setCompletedItems(finished_count);
                }
            }

            if (poller.fifo(.stderr).readableLength() > 0) {
                const fifo = poller.fifo(.stderr);
                const chunk = fifo.readableSlice(0);
                if (stderr_buf.count > 1024 * 16) {
                    stderr_buf.discard(stderr_buf.count - 1024 * 16);
                }
                try stderr_buf.write(chunk);
                fifo.discard(chunk.len);
            }
        }

        const result = try build_process.wait();
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    // TODO: print stderr log
                    std.debug.print("\"{s}\" exited with {}.\n", .{ name, code });
                    return error.ExternalError;
                }
            },
            else => {
                std.debug.print("\"{s}\" exited with {}.", .{ name, result });
                return error.ExternalError;
            },
        }
    }
}

fn deleteTreeAbsolute(name: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(name, .{});
    defer dir.close();
    var parent = try dir.openDir("..", .{});
    defer parent.close();
    try parent.deleteTree(std.fs.path.basename(name));
}

fn buildStage1(allocator: std.mem.Allocator, progress: std.Progress.Node, tree: Tree, tools: Toolchain) !void {
    progress.setEstimatedTotalItems(3);

    {
        // Refresh build tree
        defer progress.completeOne();
        const subprogress = progress.start("rm -rf", 2);
        defer subprogress.end();

        deleteTreeAbsolute(tree.staged_names[1]) catch {};
        subprogress.completeOne();

        std.fs.makeDirAbsolute(tree.staged_names[1]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        subprogress.completeOne();
    }

    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();
    try envmap.put("NINJA_STATUS", "[%f/%t] ");
    try tools.apply(&envmap);

    {
        defer progress.completeOne();
        const subprogress = progress.start("cmake", 0);
        defer subprogress.end();

        const def_camke_prefix = try std.fmt.allocPrint(
            allocator,
            "-DCMAKE_PREFIX_PATH={s}",
            .{
                tools.root,
            },
        );
        defer allocator.free(def_camke_prefix);

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "cmake",
                tree.root,
                def_camke_prefix,
                "-DCMAKE_BUILD_TYPE=Release",
                "-DZIG_TARGET_TRIPLE=" ++ BOOTSTRAP_TARGET_TEXT,
                "-DZIG_TARGET_MCPU=" ++ BOOTSTRAP_CPU_TEXT,
                "-DZIG_STATIC=ON",
                "-GNinja",
            },
            .cwd = tree.staged_names[1],
            .env_map = &envmap,
        });
        defer {
            allocator.free(result.stderr);
            allocator.free(result.stdout);
        }
        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.lockStdErr();
                    std.io.getStdErr().writeAll(result.stderr) catch {};
                    std.debug.unlockStdErr();
                    std.debug.print("cmake exit with {}.\n", .{code});
                    return error.ExternalError;
                }
            },
            else => {
                std.debug.print("cmake exit with {}.\n", .{result.term});
                return error.ExternalError;
            },
        }
    }

    {
        defer progress.completeOne();
        const subprogress = progress.start("ninja install", 0);
        defer subprogress.end();

        var child = std.process.Child.init(&.{ "ninja", "install" }, allocator);
        child.cwd = tree.staged_names[1];
        child.env_map = &envmap;
        child.stderr_behavior = .Ignore;
        child.progress_node = subprogress;

        try child.spawn();

        const result = try child.wait();
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    // std.io.getStdErr().writeAll(result.stderr) catch {};
                    // TODO: print stderr
                    std.debug.print("ninja exit with {}.\n", .{code});
                    return error.ExternalError;
                }
            },
            else => {
                std.debug.print("ninja exit with {}.\n", .{result});
                return error.ExternalError;
            },
        }
    }
}

fn buildStage2(allocator: std.mem.Allocator, progress: std.Progress.Node, tree: Tree, tools: Toolchain) !void {
    progress.setEstimatedTotalItems(2);
    defer progress.completeOne();
    {
        defer progress.completeOne();
        const rm_progress = progress.start("rm -rf", 0);
        defer rm_progress.end();
        deleteTreeAbsolute(tree.staged_names[2]) catch {};
    }

    const zig_lib_dir = try std.fs.path.resolve(allocator, &.{
        tree.root,
        "lib",
    });
    defer allocator.free(zig_lib_dir);

    var child = std.process.Child.init(&.{
        tools.zig,
        "build",
        "-Doptimize=ReleaseFast",
        "-Dtarget=" ++ BOOTSTRAP_CPU_TEXT ++ "-" ++ TARGET_OS_TEXT ++ "-musl",
        "-Dstatic-llvm",
        "--search-prefix",
        tools.root,
        "-p",
        tree.staged_names[2],
        "--zig-lib-dir",
        zig_lib_dir,
        "-freference-trace",
    }, allocator);
    child.progress_node = progress.start("zig build -Ooptimize=ReleaseFast", 0);
    child.cwd = tree.root;

    const result = try child.spawnAndWait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("zig exit with {}.\n", .{code});
                return error.ExternalError;
            }
        },
        else => {
            std.debug.print("zig exit with {}.\n", .{result});
            return error.ExternalError;
        },
    }
}

fn buildStage3(allocator: std.mem.Allocator, progress: std.Progress.Node, tree: Tree, tools: Toolchain) !void {
    progress.setEstimatedTotalItems(2);
    defer progress.completeOne();
    {
        defer progress.completeOne();
        const rm_progress = progress.start("rm -rf", 0);
        defer rm_progress.end();
        deleteTreeAbsolute(tree.staged_names[3]) catch {};
    }

    const zig_lib_dir = try std.fs.path.resolve(allocator, &.{
        tree.root,
        "lib",
    });
    defer allocator.free(zig_lib_dir);

    var child = std.process.Child.init(&.{
        tools.zig,
        "build",
        "-Doptimize=Debug",
        "-Dtarget=" ++ BOOTSTRAP_CPU_TEXT ++ "-" ++ TARGET_OS_TEXT ++ "-musl",
        "-Dno-langref",
        "-Dno-lib",
        "-Dstatic-llvm",
        "--search-prefix",
        tools.root,
        "-p",
        tree.staged_names[3],
        "--zig-lib-dir",
        zig_lib_dir,
        "-freference-trace",
    }, allocator);
    child.progress_node = progress.start("zig build -Ooptimize=Debug", 0);
    child.cwd = tree.root;

    const result = try child.spawnAndWait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("zig exit with {}.\n", .{code});
                return error.ExternalError;
            }
        },
        else => {
            std.debug.print("zig exit with {}.\n", .{result});
            return error.ExternalError;
        },
    }
}

const HELP_STAGE0 =
    \\zigd stage0 <command> [...options]
    \\
    \\Invoke stage 0 compilers, which is usually shipped by the host system.
    \\
    \\Available Commands:
    \\cc, clang, gcc - Invoke the C compiler (default: cc).
    \\c++, clang++, g++ - Invoke the C++ compiler (default: c++).
    \\asm - Invoke the assembler (default: cc).
    \\
    \\If ccache is available in $PATH, "ccache" is prepend to the
    \\default values.
    \\
    \\Environment Variables:
    \\CC - Change the default C compiler.
    \\CXX - Change the default C++ compiler.
    \\ASM - Change the default assmbler.
    \\
    \\Options:
    \\
    \\-h/--help - If no command specified, print this message and exit.
    \\
;

fn stage0(allocator: std.mem.Allocator, arg_it: *std.process.ArgIterator) !void {
    const eql = std.mem.eql;
    if (arg_it.next()) |command| {
        if (eql(u8, command, "-h") or eql(u8, command, "--help")) {
            try std.io.getStdOut().writeAll(HELP_STAGE0);
            return;
        }

        var toolchain = try Toolchain.fromGlobal(allocator);
        defer toolchain.deinit(allocator);

        var list = std.ArrayList([]const u8).init(allocator);
        defer list.deinit();

        if (eql(u8, command, "cc") or eql(u8, command, "clang") or eql(u8, command, "gcc")) {
            try list.append(toolchain.cc);
        } else if (eql(u8, command, "c++") or eql(u8, command, "clang++") or eql(u8, command, "g++")) {
            try list.append(toolchain.cxx);
        } else if (eql(u8, command, "asm")) {
            try list.append(toolchain.@"asm");
        } else {
            return error.UnknownCommand;
        }

        while (arg_it.next()) |a| {
            try list.append(try allocator.dupe(u8, a));
        }
        return std.process.execv(allocator, list.items);
    } else {
        try std.io.getStdOut().writeAll(HELP_STAGE0);
    }
}

fn invokeZig(comptime stage: u2, allocator: std.mem.Allocator, arg_it: *std.process.ArgIterator) !noreturn {
    var tree = try Tree.fromGlobal(allocator);
    defer tree.deinit();

    var toolchain = switch (stage) {
        0 => @compileError("Use stage0() for stage0 compilers"),
        1 => try tree.stage1ToolsTargetHost(allocator),
        2 => try tree.stage2ToolsTargetHost(allocator),
        3 => try tree.stage3ToolsTargetHost(allocator),
    };
    defer toolchain.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append(try arena.allocator().dupe(u8, toolchain.zig));

    while (arg_it.next()) |arg| {
        try args.append(try arena.allocator().dupe(u8, arg));
    }

    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();

    if (stage == 3) {
        const zig_lib_dir = try std.fs.path.resolve(arena.allocator(), &.{ tree.root, "lib" });
        try envmap.put("ZIG_LIB_DIR", zig_lib_dir);
    }

    return std.process.execve(arena.allocator(), args.items, &envmap);
}

const HELP =
    \\zigd <command>
    \\
    \\Build and manage the zig compiler from the source tree.
    \\
    \\Use ZIGD_TREE to specify the zig source tree.
    \\
    \\Available Commands:
    \\help - Print this message and exit.
    \\build - Build specific component.
    \\stage0 - Invoke stage 0 compiler.
    \\bootstrap - Invoke bootstrap zig compiler.
    \\stage1 - Invoke stage 2 zig compiler.
    \\stage2 - Invoke stage 3 zig compiler.
    \\stage3 - Invoke development zig compiler.
    \\tree - Print the active tree name.
    \\env - Print environment values.
    \\
;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var arg_it = try std.process.ArgIterator.initWithAllocator(allocator);
    defer arg_it.deinit();

    const program_name = arg_it.next() orelse unreachable; // The first argument is the program name

    const command = arg_it.next() orelse {
        std.debug.print("Unspecified command. Use \"{s} help\" to list available commands.\n", .{program_name});
        return error.UnspecifiedCommand;
    };

    if (std.mem.eql(u8, command, "help")) {
        const out = std.io.getStdOut();
        try out.writeAll(HELP);
    } else if (std.mem.eql(u8, command, "tree")) {
        var tree = try Tree.fromGlobal(allocator);
        defer tree.deinit();

        const out = std.io.getStdOut();
        try out.writeAll(tree.root);
        try out.writeAll("\n");
    } else if (std.mem.eql(u8, command, "stage0")) {
        try stage0(allocator, &arg_it);
    } else if (std.mem.eql(u8, command, "build")) {
        try build(allocator, &arg_it);
    } else if (std.mem.eql(u8, command, "stage1")) {
        try invokeZig(1, allocator, &arg_it);
    } else if (std.mem.eql(u8, command, "stage2")) {
        try invokeZig(2, allocator, &arg_it);
    } else if (std.mem.eql(u8, command, "stage3")) {
        try invokeZig(3, allocator, &arg_it);
    } else {
        return error.UnknownCommand;
    }
}
