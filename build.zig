const std = @import("std");
const host_os = @import("builtin").os.tag;

/// Minimum Android API level: AndroidBitmap_compress (the JPEG encoder
/// this project uses instead of vendoring libjpeg) landed in 30.
const android_min_api = 30;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "webcam2ip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const android_libc_file = configurePlatform(b, exe.root_module);
    exe.root_module.link_libc = true;
    if (android_libc_file) |f| exe.setLibCFile(f);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Shares exe.root_module, so the C sources and linked libraries come
    // along already -- only the Compile-step-level libc file has to be
    // repeated here.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (android_libc_file) |f| exe_tests.setLibCFile(f);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

/// Adds the capture backend for `module`'s target: the ObjC shim +
/// system frameworks on macOS, the NDK C shim + its libraries on
/// Android. Call once per module -- exe and exe_tests share one, and
/// adding the C sources twice is a duplicate-symbol link error.
///
/// Returns the libc file each Compile step must be given (Android only;
/// null on macOS), since that one setting lives on the step rather than
/// the module.
fn configurePlatform(b: *std.Build, module: *std.Build.Module) ?std.Build.LazyPath {
    const target = module.resolved_target.?.result;

    if (target.abi.isAndroid()) return configureAndroid(b, module, target);

    switch (target.os.tag) {
        .macos => {
            module.addCSourceFiles(.{
                .root = b.path("src/platform/macos"),
                .files = &.{ "shim.m", "capture.m" },
                .flags = &.{"-fobjc-arc"},
            });
            for ([_][]const u8{
                "Foundation", "AVFoundation", "CoreMedia", "CoreVideo",
                "CoreImage",  "CoreGraphics", "ImageIO",   "CoreText",
            }) |framework| module.linkFramework(framework, .{});
            module.linkSystemLibrary("objc", .{});
            return null;
        },
        else => std.debug.panic(
            "no capture backend for {s} -- see src/platform.zig",
            .{@tagName(target.os.tag)},
        ),
    }
}

fn configureAndroid(b: *std.Build, module: *std.Build.Module, target: std.Target) std.Build.LazyPath {
    const ndk = ndkPath(b) orelse std.debug.panic(
        "Android NDK not found -- pass -Dndk=/path/to/ndk, or set ANDROID_NDK_HOME / ANDROID_HOME",
        .{},
    );
    const host_tag = switch (host_os) {
        // The NDK ships no darwin-arm64 prebuilt; the x86_64 one runs
        // under Rosetta on Apple Silicon.
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => std.debug.panic("unsupported NDK host {s}", .{@tagName(host_os)}),
    };
    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt", host_tag, "sysroot" });

    // The NDK lays out headers/libs under *its* triple, which isn't
    // always Zig's triple for the same target (32-bit arm is
    // arm-linux-androideabi there, armv7a-... here).
    const ndk_triple = switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => std.debug.panic("unsupported Android arch {s}", .{@tagName(target.cpu.arch)}),
    };

    // The API level rides on the target triple ("...-android.30"), and
    // Zig turns it into __ANDROID_API__ for the C sources itself -- so
    // this is the one place that decides which NDK stubs get linked, and
    // too low a value fails deep inside the NDK headers rather than here.
    const api_level = target.os.version_range.linux.android;
    if (api_level < android_min_api) std.debug.panic(
        "Android API {d} is too old (need {d}+ for AndroidBitmap_compress) -- build with -Dtarget={s}-linux-android.{d}",
        .{ api_level, android_min_api, @tagName(target.cpu.arch), android_min_api },
    );

    const include_dir = b.pathJoin(&.{ sysroot, "usr/include" });
    const crt_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, ndk_triple, api_level });

    module.addSystemIncludePath(.{ .cwd_relative = include_dir });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ include_dir, ndk_triple }) });
    module.addLibraryPath(.{ .cwd_relative = crt_dir });

    // Zig bundles no bionic, so point it at the NDK's headers/CRT
    // explicitly -- without this, link_libc on an Android target fails
    // with "libc not available".
    const libc_conf = b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ include_dir, include_dir, crt_dir });
    const write_files = b.addWriteFiles();

    module.addCSourceFiles(.{
        .root = b.path("src/platform/android"),
        .files = &.{"capture.c"},
        .flags = &.{"-std=c11"},
    });
    for ([_][]const u8{
        "camera2ndk", // ACameraManager / ACameraDevice
        "mediandk", // AImageReader
        "jnigraphics", // AndroidBitmap_compress
        "log",
    }) |lib| module.linkSystemLibrary(lib, .{});

    return write_files.add("android-libc.conf", libc_conf);
}

/// -Dndk, then the usual env vars, then the newest NDK under ANDROID_HOME.
fn ndkPath(b: *std.Build) ?[]const u8 {
    if (b.option([]const u8, "ndk", "Path to the Android NDK")) |p| return p;
    for ([_][]const u8{ "ANDROID_NDK_HOME", "ANDROID_NDK_ROOT" }) |name| {
        if (b.graph.environ_map.get(name)) |value| {
            if (value.len > 0) return value;
        }
    }

    const sdk = b.graph.environ_map.get("ANDROID_HOME") orelse return null;
    const ndk_root = b.pathJoin(&.{ sdk, "ndk" });
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, ndk_root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (entry.kind != .directory) continue;
        // Version dirs look like "29.0.14206865" -- same component
        // widths in practice, so lexicographic order picks the newest.
        if (newest == null or std.mem.order(u8, entry.name, newest.?) == .gt) {
            newest = b.dupe(entry.name);
        }
    }
    return if (newest) |name| b.pathJoin(&.{ ndk_root, name }) else null;
}
