const std = @import("std");
const Io = std.Io;

/// Binds and starts listening on `address`. Split from `acceptLoop` so
/// tests can bind synchronously before spawning the accept loop on a
/// background thread, avoiding a listen-vs-connect race.
pub fn listen(io: Io, address: *const Io.net.IpAddress) !Io.net.Server {
    return address.listen(io, .{ .reuse_address = true });
}

/// Handles each accepted connection on its own detached thread, so a
/// long-lived client (the future MJPEG /stream) can't block a quick
/// request (the future /snapshot.jpg) on another connection. Never
/// returns under normal operation.
pub fn acceptLoop(io: Io, server: *Io.net.Server) void {
    while (true) {
        const conn = server.accept(io) catch return;
        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, conn }) catch {
            conn.close(io);
            continue;
        };
        thread.detach();
    }
}

/// Convenience wrapper combining `listen` + `acceptLoop` for callers
/// (main.zig) that don't need to observe the bound server separately.
pub fn serve(io: Io, address: *const Io.net.IpAddress) !void {
    var server = try listen(io, address);
    defer server.deinit(io);
    acceptLoop(io, &server);
}

fn handleConnection(io: Io, conn: Io.net.Stream) void {
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buf);
    var stream_writer = conn.writer(io, &write_buf);

    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = server.receiveHead() catch return;
    handleRequest(&request) catch return;
}

fn handleRequest(request: *std.http.Server.Request) !void {
    if (std.mem.eql(u8, request.head.target, "/")) {
        try request.respond("webcam2ip\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }

    try request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn readLine(r: *Io.Reader) ![]u8 {
    return (try r.takeDelimiter('\n')).?;
}

test "GET / returns 200 with a webcam2ip body" {
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17174");

    var server = try listen(io, &address);
    // No deinit: acceptLoop below runs on a detached background thread
    // for the rest of this short-lived test process; closing the
    // listening socket out from under a thread possibly blocked in
    // accept() on it isn't a race worth taking on. The fd is reclaimed
    // when the test binary exits.
    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ io, &server });
    accept_thread.detach();

    var client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var write_buf: [256]u8 = undefined;
    var client_writer = client.writer(io, &write_buf);
    try client_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try client_writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var client_reader = client.reader(io, &read_buf);
    const r = &client_reader.interface;

    const status_line = try readLine(r);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "200") != null);

    while (true) {
        const line = try readLine(r);
        if (line.len == 1 and line[0] == '\r') break; // blank line ends headers
    }

    const body = try readLine(r);
    try std.testing.expectEqualStrings("webcam2ip", body);
}
