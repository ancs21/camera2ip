const std = @import("std");
const Io = std.Io;

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
    try stdout.flush();
}

test "writeBanner prints app name, version, and scaffold marker" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    try std.testing.expectEqualStrings("webcam2ip v0.1.0 — scaffold ok\n", w.buffered());
}
