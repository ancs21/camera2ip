# webcam2ip

Turns a Mac's webcam into a network-reachable IP camera. Written in Zig as a
learning project: no auth, no UI, no recording. Point a browser or VLC at it
and see live video.

## Requirements

- macOS
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
- macOS only. Uses AVFoundation/CoreImage/ImageIO/CoreText through a thin
  Objective-C shim (`src/platform/macos/`). A Pi or ESP32 port would need
  its own platform backend.
- No graceful shutdown. `Ctrl-C` or `kill` the process; there's no cleanup
  handler.

## Project layout

```
src/
  main.zig            entry point: spawns the capture thread + HTTP server
  http.zig            HTTP server, routing, /snapshot.jpg and /stream handlers
  capture_loop.zig     mutex-guarded "latest frame" slot, fed by the capture thread
  platform/macos.zig   Zig bindings for the Objective-C shim below
  platform/macos/      AVFoundation capture, ImageIO JPEG encode, CoreText overlay
```
