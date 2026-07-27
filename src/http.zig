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

// keep_alive = false on every respond()/respondStreaming() call below:
// handleConnection calls receiveHead() exactly once per connection and
// then closes it regardless (see below), so this server never actually
// reuses a connection for a second request -- keep-alive was providing
// no real benefit. It was, however, actively dangerous: std.http.Server's
// default keep_alive=true means respond() calls discardBody() to
// drain any declared-but-undelivered request body, and a state-machine
// bug in Zig 0.16.0's Reader.discardRemaining() (EndOfStream treated
// as success without reaching the `.ready` state discardBody then
// asserts on) turns a client that declares a body and disconnects
// before sending it into a full process crash -- verified live via
// `nc` and reproduced in the test below. Setting keep_alive=false
// skips discardBody entirely, closing this off structurally rather
// than depending on a stdlib bug getting fixed upstream.

fn handleRequest(io: Io, gpa: std.mem.Allocator, request: *std.http.Server.Request) !void {
    if (std.mem.eql(u8, request.head.target, "/")) {
        try request.respond("webcam2ip\n", .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    }

    if (std.mem.eql(u8, request.head.target, "/snapshot.jpg")) {
        return handleSnapshot(io, gpa, request);
    }

    if (std.mem.eql(u8, request.head.target, "/stream")) {
        return handleStream(io, gpa, request);
    }

    try request.respond("not found\n", .{
        .status = .not_found,
        .keep_alive = false,
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
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return;
    };
    defer gpa.free(frame.data);

    try request.respond(frame.data, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "image/jpeg" }},
    });
}

const stream_boundary = "frame";

/// Traditional close-delimited MJPEG streaming (multipart/x-mixed-replace,
/// no transfer-encoding wrapper) rather than HTTP/1.1 chunked -- matches
/// what mjpg-streamer and most MJPEG cameras actually do, for maximum
/// consumer compatibility (browsers and VLC both expect this framing).
fn handleStream(io: Io, gpa: std.mem.Allocator, request: *std.http.Server.Request) !void {
    var respond_buf: [8192]u8 = undefined;
    var body_writer = try request.respondStreaming(&respond_buf, .{
        .respond_options = .{
            .transfer_encoding = .none,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "multipart/x-mixed-replace; boundary=" ++ stream_boundary },
            },
        },
    });

    while (true) {
        Io.sleep(io, .fromMilliseconds(100), .awake) catch return; // ~10fps

        const maybe_frame = capture_loop.copyLatestFrame(io, gpa) catch return;
        const frame = maybe_frame orelse continue; // not ready yet, try again next tick
        defer gpa.free(frame.data);

        body_writer.writer.print("--" ++ stream_boundary ++ "\r\ncontent-type: image/jpeg\r\ncontent-length: {d}\r\n\r\n", .{frame.data.len}) catch return;
        body_writer.writer.writeAll(frame.data) catch return;
        body_writer.writer.writeAll("\r\n") catch return;
        body_writer.flush() catch return;
    }
}

fn readLine(r: *Io.Reader) ![]u8 {
    return (try r.takeDelimiter('\n')).?;
}

/// Binds, spawns a detached acceptLoop, and returns once the loop is
/// live enough to accept -- callers connect to `address` immediately
/// after. Each test uses a distinct port to avoid cross-test races.
/// Callers should `stop()` the returned handle before the test ends --
/// letting acceptLoop threads accumulate as permanently-blocked/detached
/// for the rest of the test binary's life (an earlier version of this
/// helper did that) raised the number of live threads all contending on
/// shared global mutexes (capture_loop's slot, std.testing.allocator's
/// own internal one) enough to trigger a rare, genuine crash inside
/// Io.Mutex/DebugAllocator's locking under that stress. Production
/// (main.zig) has exactly one long-lived accept loop, not one per test,
/// so it doesn't hit this.
const TestServer = struct {
    io: Io,
    server: *Io.net.Server,
    accept_thread: std.Thread,

    fn stop(self: TestServer) void {
        self.server.deinit(self.io); // unblocks the pending accept() with an error
        self.accept_thread.join();
        std.heap.page_allocator.destroy(self.server);
    }
};

fn startTestServer(io: Io, request_gpa: std.mem.Allocator, address: *const Io.net.IpAddress) !TestServer {
    // Heap-allocated: a stack-local here would go out of scope (and the
    // pointer below would dangle) once this function returns, while
    // acceptLoop keeps using it until stop() is called.
    const server = try std.heap.page_allocator.create(Io.net.Server);
    server.* = try listen(io, address);
    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ io, request_gpa, server });
    return .{ .io = io, .server = server, .accept_thread = accept_thread };
}

test "GET / returns 200 with a webcam2ip body" {
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17174");
    const test_server = try startTestServer(io, std.testing.allocator, &address);
    defer test_server.stop();

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
    const test_server = try startTestServer(io, gpa, &address);
    defer test_server.stop();

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

test "GET /stream sends a multipart frame whose boundary matches the header" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rgba = [_]u8{ 0, 0, 255, 255 } ** 4; // 2x2 solid blue
    capture_loop.seedFrameForTesting(io, std.heap.page_allocator, &rgba, 2, 2, 8);

    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17176");
    const test_server = try startTestServer(io, gpa, &address);
    defer test_server.stop();

    var client = try address.connect(io, .{ .mode = .stream });

    var write_buf: [256]u8 = undefined;
    var client_writer = client.writer(io, &write_buf);
    try client_writer.interface.writeAll("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try client_writer.interface.flush();

    var read_buf: [8192]u8 = undefined;
    var client_reader = client.reader(io, &read_buf);
    const r = &client_reader.interface;

    const status_line = try readLine(r);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "200") != null);

    var saw_multipart_header = false;
    while (true) {
        const line = try readLine(r);
        if (line.len == 1 and line[0] == '\r') break; // blank line ends the top-level response headers
        if (std.mem.indexOf(u8, line, "multipart/x-mixed-replace; boundary=" ++ stream_boundary) != null) {
            saw_multipart_header = true;
        }
    }
    try std.testing.expect(saw_multipart_header);

    // First frame part: boundary line, its own headers, blank line, JPEG bytes.
    const boundary_line = try readLine(r);
    try std.testing.expectEqualStrings("--" ++ stream_boundary, boundary_line[0 .. boundary_line.len - 1]); // drop trailing \r

    var part_content_length: ?usize = null;
    while (true) {
        const line = try readLine(r);
        if (line.len == 1 and line[0] == '\r') break;
        if (std.mem.startsWith(u8, line, "content-length: ")) {
            part_content_length = try std.fmt.parseInt(usize, line["content-length: ".len .. line.len - 1], 10);
        }
    }
    const len = part_content_length orelse return error.MissingContentLength;
    const jpeg_bytes = try r.take(len);
    try std.testing.expectEqual(@as(u8, 0xFF), jpeg_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), jpeg_bytes[1]); // JPEG SOI marker

    // Close explicitly (not deferred) and give the server's detached
    // handler thread time to notice on its next ~100ms-cadence write
    // attempt and run its own per-iteration cleanup, rather than racing
    // this test's (and the whole binary's) teardown against a
    // still-in-flight background allocation.
    client.close(io);
    try Io.sleep(io, .fromMilliseconds(400), .awake);
}

test "a POST with an undelivered body does not crash the server" {
    // Regression test for a real, verified DoS: std.http.Server's
    // default keep_alive=true means discardBody() runs when a request
    // declares a body that never arrives, and a state-machine bug in
    // Zig 0.16.0's Reader.discardRemaining() (EndOfStream treated as
    // success without reaching the `.ready` state discardBody then
    // asserts on) panics the whole process, not just this connection.
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parseLiteral("127.0.0.1:17177");
    const test_server = try startTestServer(io, std.testing.allocator, &address);
    defer test_server.stop();

    // Declare a body that never arrives, then disconnect before sending it.
    {
        var client = try address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        var write_buf: [256]u8 = undefined;
        var client_writer = client.writer(io, &write_buf);
        try client_writer.interface.writeAll("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999999\r\n\r\n");
        try client_writer.interface.flush();
    }

    // Give the server a moment to process (and, if unfixed, crash the
    // whole test binary -- not just fail this assertion).
    try Io.sleep(io, .fromMilliseconds(200), .awake);

    // If the process is still alive, an unrelated fresh request on a
    // new connection should succeed normally.
    var client2 = try address.connect(io, .{ .mode = .stream });
    defer client2.close(io);

    var write_buf2: [256]u8 = undefined;
    var client_writer2 = client2.writer(io, &write_buf2);
    try client_writer2.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try client_writer2.interface.flush();

    var read_buf2: [1024]u8 = undefined;
    var client_reader2 = client2.reader(io, &read_buf2);
    const status_line = try readLine(&client_reader2.interface);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "200") != null);
}
