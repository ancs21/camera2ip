const std = @import("std");
const Io = std.Io;
const capture_loop = @import("capture_loop.zig");

/// Binds and starts listening on `address`. Split from `acceptLoop` so
/// tests can bind synchronously before spawning the accept loop on a
/// background thread, avoiding a listen-vs-connect race.
pub fn listen(io: Io, address: *const Io.net.IpAddress) !Io.net.Server {
    return address.listen(io, .{ .reuse_address = true });
}

/// Handles each accepted connection on its own detached thread, so a
/// long-lived client (the future MJPEG /stream) can't block a quick
/// request (/snapshot.jpg) on another connection. Never returns under
/// normal operation.
pub fn acceptLoop(io: Io, gpa: std.mem.Allocator, server: *Io.net.Server) void {
    while (true) {
        const conn = server.accept(io) catch return;
        const thread = std.Thread.spawn(.{}, handleConnection, .{ io, gpa, conn }) catch {
            conn.close(io);
            continue;
        };
        thread.detach();
    }
}

/// Convenience wrapper combining `listen` + `acceptLoop` for callers
/// (main.zig) that don't need to observe the bound server separately.
pub fn serve(io: Io, gpa: std.mem.Allocator, address: *const Io.net.IpAddress) !void {
    var server = try listen(io, address);
    defer server.deinit(io);
    acceptLoop(io, gpa, &server);
}

fn handleConnection(io: Io, gpa: std.mem.Allocator, conn: Io.net.Stream) void {
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = conn.reader(io, &read_buf);
    var stream_writer = conn.writer(io, &write_buf);

    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = server.receiveHead() catch return;
    handleRequest(io, gpa, &request) catch return;
}

fn handleRequest(io: Io, gpa: std.mem.Allocator, request: *std.http.Server.Request) !void {
    if (std.mem.eql(u8, request.head.target, "/")) {
        try request.respond("webcam2ip\n", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }

    if (std.mem.eql(u8, request.head.target, "/snapshot.jpg")) {
        return handleSnapshot(io, gpa, request);
    }

    try request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

/// If a request arrives before the capture thread has delivered its
/// first frame, respond 503 rather than blocking -- simpler than a
/// bounded wait, and only affects the first ~1s after process startup.
fn handleSnapshot(io: Io, gpa: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const maybe_frame = try capture_loop.copyLatestFrame(io, gpa);
    const frame = maybe_frame orelse {
        try request.respond("not ready yet\n", .{
            .status = .service_unavailable,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };
    defer gpa.free(frame.data);

    try request.respond(frame.data, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "image/jpeg" }},
    });
}

fn readLine(r: *Io.Reader) ![]u8 {
    return (try r.takeDelimiter('\n')).?;
}

/// Binds, spawns a detached acceptLoop, and returns once the loop is
/// live enough to accept -- callers connect to `address` immediately
/// after. Each test uses a distinct port to avoid cross-test races.
fn startTestServer(io: Io, request_gpa: std.mem.Allocator, address: *const Io.net.IpAddress) !void {
    // Heap-allocated with an untracked allocator: a stack-local here
    // would go out of scope (and the pointer below would dangle) the
    // instant this function returns, while the detached thread keeps
    // using it for the rest of the test process -- so it must outlive
    // this function and is never freed, which std.testing.allocator's
    // leak checker would (incorrectly) flag as a leak. `request_gpa` is
    // separate and still flows through to per-request allocations
    // (e.g. handleSnapshot's copyLatestFrame), which *are* freed each
    // request and stay meaningfully leak-checked.
    const server = try std.heap.page_allocator.create(Io.net.Server);
    server.* = try listen(io, address);
    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ io, request_gpa, server });
    accept_thread.detach();
}

test "GET / returns 200 with a webcam2ip body" {
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17174");
    try startTestServer(io, std.testing.allocator, &address);

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

test "GET /snapshot.jpg returns the latest frame with an image/jpeg content-type" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rgba = [_]u8{ 0, 255, 0, 255 } ** 4; // 2x2 solid green
    // page_allocator, not std.testing.allocator: the frame slot this
    // seeds is a module-level global that's intentionally never freed
    // (see capture_loop.zig's own tests for the same reasoning).
    capture_loop.seedFrameForTesting(io, std.heap.page_allocator, &rgba, 2, 2, 8);

    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17175");
    try startTestServer(io, gpa, &address);

    var client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var write_buf: [256]u8 = undefined;
    var client_writer = client.writer(io, &write_buf);
    try client_writer.interface.writeAll("GET /snapshot.jpg HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try client_writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var client_reader = client.reader(io, &read_buf);
    const r = &client_reader.interface;

    const status_line = try readLine(r);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "200") != null);

    var saw_jpeg_content_type = false;
    var content_length: ?usize = null;
    while (true) {
        const line = try readLine(r);
        if (line.len == 1 and line[0] == '\r') break; // blank line ends headers
        if (std.mem.indexOf(u8, line, "content-type") != null and
            std.mem.indexOf(u8, line, "image/jpeg") != null)
        {
            saw_jpeg_content_type = true;
        }
        if (std.mem.startsWith(u8, line, "content-length: ")) {
            const value = line["content-length: ".len .. line.len - 1]; // drop trailing \r
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    try std.testing.expect(saw_jpeg_content_type);

    // Drain the body properly rather than dropping the connection
    // mid-response -- a well-behaved client reads what it asked for.
    const len = content_length orelse return error.MissingContentLength;
    const body = try r.take(len);
    try std.testing.expectEqual(@as(u8, 0xFF), body[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), body[1]); // JPEG SOI marker
}
