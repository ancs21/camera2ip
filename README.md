# webcam2ip

Turns a Mac's or Android phone's camera into an IP camera. Written in Zig as a
learning project: no auth, no UI, no recording. Point a browser or VLC at it
and watch.

## Requirements

- macOS, or Android on API 30+
- Zig 0.16.0 ([zigup](https://github.com/marler8997/zigup) recommended)
- A camera

## macOS

```sh
zig build run
```

The first run asks for camera access. No prompt usually means your terminal
already has it (System Settings, Privacy & Security, Camera). On startup it
prints the port plus a command for finding your LAN IP, which is the address
other devices should use.

`zig build` defaults to `-Doptimize=ReleaseSmall`, since the hot path lives in
the ObjC shim rather than in Zig. Use `-Doptimize=Debug` for backtraces and
safety checks. You get a ~220KB binary linked only against system frameworks.
It isn't signed, so a copy from another machine may need
`xattr -d com.apple.quarantine`.

## Android

The same server, running on the phone. No APK, no Gradle, no Java: it builds
as a command-line binary you push over adb.

```sh
zig build -Dtarget=aarch64-linux-android.30   # NDK found via ANDROID_HOME
adb push zig-out/bin/webcam2ip /data/local/tmp/
adb shell chmod 755 /data/local/tmp/webcam2ip
adb shell /data/local/tmp/webcam2ip
```

Reach it with `adb forward tcp:8080 tcp:8080`, or over wifi at the phone's LAN
IP. The `.30` is required, not cosmetic: the JPEG encoder is
`AndroidBitmap_compress`, which landed in API 30. Pass `-Dndk=/path/to/ndk` if
`ANDROID_HOME` isn't set.

A bare process can't show a permission dialog, so it inherits the camera access
of whatever UID starts it. From `adb shell` that's the `shell` user, which
normally holds it. If your device refuses, the process exits with
`permission_denied`, and the fix (wrapping it in a NativeActivity APK) isn't
implemented.

Frames arrive upright, rotated using the sensor's reported orientation. Two
things differ from the macOS build. There's no overlay, because the NDK ships
no font rasterizer. And the camera runs at its native frame rate instead of
being pinned to 10fps, so surplus frames get dropped after capture, which costs
power rather than CPU.

If adb can't see a Samsung phone over USB, it's usually Auto Blocker (Settings,
Security and privacy). Wireless debugging avoids it.

## Endpoints

| Path | What you get |
|---|---|
| `/` | Plain-text banner, confirms the server is up |
| `/snapshot.jpg` | One current JPEG frame |
| `/stream` | Live MJPEG (`multipart/x-mixed-replace`); works in a browser or in VLC |

On macOS every frame carries a small overlay in the top-left: app name, time,
fps, CPU%, RAM.

## Testing

```sh
zig build test
```

Unit tests plus real-socket integration tests. Roughly 1 run in 50-100 hits an
intermittent crash in the test suite's own thread-accumulation pattern, not in
the server. Re-run it.

## Known characteristics

- No authentication. Anyone who can reach port 8080 can watch. Fine on a home
  network, less fine on café wifi, which a phone joins far more often than a
  desktop does.
- CPU sits high (100%+) even at idle on macOS. Frames are throttled to ~10fps
  and per-frame allocations are tight, but most of the 56 threads in the
  process belong to AVFoundation's own session machinery rather than to the
  capture loop. Confirming that needs Instruments, so it stays open. Memory
  holds flat over long runs, so it isn't a leak.
- Android is verified on a Galaxy A15 (Android 15, arm64). The emulator is
  useless for testing capture: its fake camera feeds no frames to any client,
  including the stock camera app.
- No graceful shutdown. Ctrl-C it.

## Layout

`main.zig` spawns the capture thread and the HTTP server, then logs a
heartbeat. `capture_loop.zig` owns the mutex-guarded latest-frame slot that
everything else reads. `http.zig` serves it. `platform.zig` and
`platform/capture_abi.h` define the contract that `platform/macos/` and
`platform/android/` implement.
