# webcam2ip

Turns a Mac's or Android phone's camera into a network-reachable IP camera.
Written in Zig as a learning project: no auth, no UI, no recording. Point a
browser or VLC at it and see live video.

## Requirements

- macOS, or an Android device on API 30+ (see [Android](#android))
- Zig 0.16.0 ([zigup](https://github.com/marler8997/zigup) recommended)
- A camera (built-in or USB)

## Build & run

```sh
zig build run
```

macOS prompts for camera access on first run; click **Allow**. No prompt
usually means your terminal app already has permission (check **System
Settings → Privacy & Security → Camera**).

```
listening on 0.0.0.0:8080 -- reachable at http://<this-machine's-LAN-IP>:8080
find your LAN IP with: ipconfig getifaddr $(route get default | awk '/interface:/{print $2}')
```

Run that command, or check **System Settings → Wi-Fi → Details**, for the
URL other devices should use.

## Release build

`zig build` defaults to `-Doptimize=ReleaseSmall` since the hot path runs in
the ObjC/AVFoundation shim, not Zig, so size matters more than speed here.

```sh
zig build -Doptimize=Debug       # backtraces, safety checks
zig build -Doptimize=ReleaseSafe # optimized, safety checks kept
zig build -Doptimize=ReleaseFast # optimized for speed
```

Result: a single ~220KB arm64 Mach-O binary (`zig-out/bin/webcam2ip`), linked
only against frameworks that ship with macOS. Not code-signed or notarized,
so a copy from elsewhere may need a Gatekeeper override (right-click → Open,
or `xattr -d com.apple.quarantine <path>`).

## Android

Same server, same endpoints, running on the phone itself. It builds as a plain
command-line binary — no APK, no Gradle, no Java — so you push it and run it
over `adb`:

```sh
zig build -Dtarget=aarch64-linux-android.30       # NDK found via ANDROID_HOME
adb push zig-out/bin/webcam2ip /data/local/tmp/
adb shell chmod 755 /data/local/tmp/webcam2ip
adb shell /data/local/tmp/webcam2ip
```

Then reach it from your computer with `adb forward tcp:8080 tcp:8080` (USB), or
straight over wifi at the phone's LAN IP.

The API level in the target (`.30`) is not optional — the JPEG encoder is
`AndroidBitmap_compress`, which landed in 30. Point the build at a specific NDK
with `-Dndk=/path/to/ndk` if `ANDROID_HOME`/`ANDROID_NDK_HOME` isn't set.

Because it runs as a bare process rather than an app, it can't show a
permission dialog — it inherits the camera access of whatever UID starts it.
From `adb shell` that's the `shell` user, which holds `android.permission.CAMERA`
on emulators and userdebug builds. If your device refuses, the process exits
with `permission_denied`; wrapping the binary in a NativeActivity APK (so it can
request the permission properly) is the fix, and is not implemented.

If you connect over USB and `adb` never sees the phone, check Samsung's
**Auto Blocker** (Settings → Security and privacy) — it blocks USB commands
outright. Wireless debugging sidesteps it entirely and suits this project
better anyway.

Two known gaps versus the macOS build, both marked in
`src/platform/android/capture.c`:

- **No overlay.** The timestamp/fps/CPU banner needs a font rasterizer and the
  NDK has none, so frames go out clean.
- **The camera runs at its native frame rate.** macOS pins the driver to 10fps;
  the Android equivalent is device-dependent and can fail session configuration,
  so frames are dropped after capture instead. Costs power, not CPU.

Frames are rotated to upright using the sensor's reported orientation, so a
portrait-held phone streams portrait video.

## Endpoints

| Path | What you get |
|---|---|
| `/` | Plain-text banner, confirms the server is up |
| `/snapshot.jpg` | A single current JPEG frame |
| `/stream` | Live MJPEG video (`multipart/x-mixed-replace`); open in a browser or VLC via File → Open Network... |

Every frame carries a small overlay in the top-left: app name, time, fps,
CPU%, RAM.

## Testing

```sh
zig build test
```

Unit tests plus real-socket integration tests. Rarely (about 1 in 50-100
runs) a test hits an intermittent crash in the suite's own
thread-accumulation pattern, not the running program. Re-run if it happens.

## Known characteristics (not bugs)

- No authentication. Anyone who can reach the machine's IP on port 8080 can
  view the stream. Fine on a trusted home network, not for anything more
  exposed.
- CPU usage runs high (100%+) even at idle. Frames are throttled to ~10fps
  and per-frame allocations are already tight, but CPU doesn't drop
  proportionally. Most of the 56 threads running under the process come from
  AVFoundation/CoreMedia/ANEServices' own camera session machinery, not this
  project's capture loop. That looks like the real cost, but confirming it
  needs Instruments-level profiling, so it's left open. Not a leak: memory
  stays flat over multi-minute runs.
- macOS and Android only. Each has its own backend under `src/platform/`
  (AVFoundation/ImageIO/CoreText via an Objective-C shim; Camera2 NDK +
  AndroidBitmap via a C shim). A Pi or ESP32 port would need a third one.
- The Android build is verified end-to-end on a Galaxy A15 (Android 15,
  arm64): live 480x640 frames over `/snapshot.jpg` and `/stream`. The
  emulator is *not* a useful test target for it — the headless emulator's
  fake camera delivers no frames to any client, including the stock camera
  app.
- No graceful shutdown. `Ctrl-C` or `kill` the process; there's no cleanup
  handler.

## Project layout

```
src/
  main.zig             entry point: spawns the capture thread + HTTP server
  http.zig             HTTP server, routing, /snapshot.jpg and /stream handlers
  capture_loop.zig     mutex-guarded "latest frame" slot, fed by the capture thread
  platform.zig         Zig bindings, shared by every backend
  platform/capture_abi.h  the C ABI every backend implements
  platform/macos/      AVFoundation capture, ImageIO JPEG encode, CoreText overlay
  platform/android/    Camera2 NDK capture, AndroidBitmap JPEG encode
```
