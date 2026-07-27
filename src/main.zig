const std = @import("std");
const Io = std.Io;
const macos = @import("platform/macos.zig");
const http = @import("http.zig");
const capture_loop = @import("capture_loop.zig");

const app_name = "webcam2ip";
const app_version = "2026.07.27";

pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{s} v{s} — scaffold ok\n", .{ app_name, app_version });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try writeBanner(stdout);
    try stdout.print("objc shim greeting length: {d}\n", .{macos.shimGreetingLength()});
    try stdout.writeAll("starting continuous capture on a dedicated thread (grant the permission prompt if macOS shows one)...\n");
    try stdout.flush();

    const capture_thread = try std.Thread.spawn(.{}, runCaptureLoopThread, .{ io, gpa });
    capture_thread.detach();

    // 0.0.0.0, not 127.0.0.1: reachable from other devices on the local
    // network, not just this machine -- the whole point of "webcam2ip."
    // No auth (deliberate v1 scope), so anyone on the same network can
    // reach the stream/snapshot; fine for a home LAN, not for anything
    // more exposed.
    const address = try Io.net.IpAddress.parseLiteral("0.0.0.0:8080");
    const http_thread = try std.Thread.spawn(.{}, runHttpThread, .{ io, gpa, address });
    http_thread.detach();
    try stdout.writeAll(
        "listening on 0.0.0.0:8080 -- reachable at http://<this-machine's-LAN-IP>:8080\n" ++
            "find your LAN IP with: ipconfig getifaddr $(route get default | awk '/interface:/{print $2}')\n",
    );
    try stdout.flush();

    // Liveness heartbeat -- no file I/O (a prior version wrote frame.jpg
    // to cwd every second, which followed symlinks and could overwrite
    // anything the process had permission to touch).
    var elapsed_seconds: u32 = 0;
    while (true) : (elapsed_seconds += 1) {
        try Io.sleep(io, .fromSeconds(1), .awake);

        if (try capture_loop.copyLatestFrame(io, gpa)) |frame| {
            defer gpa.free(frame.data);
            try stdout.print("[{d}s] frame {d}x{d}, {d} bytes\n", .{ elapsed_seconds, frame.width, frame.height, frame.data.len });
        } else {
            try stdout.print("[{d}s] waiting for first frame...\n", .{elapsed_seconds});
        }
        try stdout.flush();
    }
}

fn runCaptureLoopThread(io: Io, gpa: std.mem.Allocator) void {
    // 20s permission-wait timeout -- generous enough for a human to
    // notice and click the prompt during manual testing, still bounded.
    const result = capture_loop.run(io, gpa, 20_000);
    // capture_loop.run() only returns on permission/session-setup
    // failure (a running session blocks forever).
    std.debug.print("capture loop exited early: {t}\n", .{result});
}

fn runHttpThread(io: Io, gpa: std.mem.Allocator, address: Io.net.IpAddress) void {
    http.serve(io, gpa, &address) catch |err| {
        std.debug.print("http server exited early: {t}\n", .{err});
    };
}

test {
    // `@import` alone does not pull a file's `test` blocks into the binary
    // (see zig skill std-testing.md) -- this forces platform/macos.zig's
    // and http.zig's tests to actually run under `zig build test`.
    _ = macos;
    _ = http;
    _ = capture_loop;
}

test "writeBanner prints app name, version, and scaffold marker" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    try std.testing.expectEqualStrings("webcam2ip v2026.07.27 — scaffold ok\n", w.buffered());
}
