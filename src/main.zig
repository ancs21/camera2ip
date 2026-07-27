const std = @import("std");
const Io = std.Io;
const macos = @import("platform/macos.zig");

const app_name = "webcam2ip";
const app_version = "0.1.0";

pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{s} v{s} — scaffold ok\n", .{ app_name, app_version });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try writeBanner(stdout);
    try stdout.print("objc shim greeting length: {d}\n", .{macos.shimGreetingLength()});
    try stdout.writeAll("starting camera capture probe on a dedicated thread (grant the permission prompt if macOS shows one)...\n");
    try stdout.flush();

    var probe_result: macos.CaptureProbeResult = undefined;
    const probe_thread = try std.Thread.spawn(.{}, runCaptureProbeThread, .{&probe_result});
    probe_thread.join();

    try stdout.print("capture probe result: {s}\n", .{@tagName(probe_result)});
    try stdout.flush();
}

fn runCaptureProbeThread(out_result: *macos.CaptureProbeResult) void {
    // 20s per phase (permission wait, first-frame wait) -- generous
    // enough for a human to notice and click the permission prompt
    // during manual testing, still bounded so it can't hang forever.
    out_result.* = macos.captureProbe(20_000);
}

// Spike code proving Zig 0.16's Io.net stack works, in isolation from
// std.http. Temporary home -- refactored into src/http.zig in T8.
fn echoOneConnection(io: Io, conn: Io.net.Stream) !void {
    defer conn.close(io);

    var read_buf: [64]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buf);
    const r = &stream_reader.interface;
    _ = try r.takeDelimiter('\n');

    var write_buf: [64]u8 = undefined;
    var stream_writer = conn.writer(io, &write_buf);
    const w = &stream_writer.interface;
    try w.writeAll("pong\n");
    try w.flush();
}

fn echoServerLoop(io: Io, server: *Io.net.Server, connection_count: usize) !void {
    for (0..connection_count) |_| {
        const conn = try server.accept(io);
        try echoOneConnection(io, conn);
    }
}

fn connectAndExpectPong(io: Io, address: *const Io.net.IpAddress) !void {
    var client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var client_write_buf: [64]u8 = undefined;
    var client_writer = client.writer(io, &client_write_buf);
    try client_writer.interface.writeAll("ping\n");
    try client_writer.interface.flush();

    var client_read_buf: [64]u8 = undefined;
    var client_reader = client.reader(io, &client_read_buf);
    const reply = try client_reader.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("pong", reply.?);
}

// Spike proving an `io` handle is safe to use for Io.Mutex locking from a
// thread not itself spawned through any Io-managed mechanism -- exactly
// the situation the real capture thread (T9) will be in.
const SharedCounter = struct {
    mutex: Io.Mutex = .init,
    value: usize = 0,
};

fn incrementMany(io: Io, shared: *SharedCounter, times: usize) !void {
    for (0..times) |_| {
        try shared.mutex.lock(io);
        defer shared.mutex.unlock(io);
        shared.value += 1;
    }
}

test "Io.Mutex guards a counter incremented concurrently from two threads sharing one io handle" {
    const io = std.testing.io;
    var shared = SharedCounter{};
    const iterations_per_thread = 200_000;

    const other_thread = try std.Thread.spawn(.{}, incrementMany, .{ io, &shared, iterations_per_thread });
    try incrementMany(io, &shared, iterations_per_thread);
    other_thread.join();

    try std.testing.expectEqual(@as(usize, iterations_per_thread * 2), shared.value);
}

test "raw Io.net echo server survives repeated sequential connections" {
    const io = std.testing.io;
    const connection_count = 5;

    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17171");
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const server_thread = try std.Thread.spawn(.{}, echoServerLoop, .{ io, &server, connection_count });
    defer server_thread.join();

    for (0..connection_count) |_| {
        try connectAndExpectPong(io, &address);
    }
}

test {
    // `@import` alone does not pull a file's `test` blocks into the binary
    // (see zig skill std-testing.md) -- this forces platform/macos.zig's
    // tests to actually run under `zig build test`.
    _ = macos;
}

test "writeBanner prints app name, version, and scaffold marker" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    try std.testing.expectEqualStrings("webcam2ip v0.1.0 — scaffold ok\n", w.buffered());
}
