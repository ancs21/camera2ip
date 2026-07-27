# webcam2ip

Turns a Mac's webcam into a network-reachable IP camera. Written in Zig
as a learning project — no auth, no UI, no recording. Point a browser
or VLC at it and see live video.

## Requirements

- macOS
- Zig 0.16.0 ([zigup](https://github.com/marler8997/zigup) recommended for managing versions)
- A camera (built-in or USB)

## Build & run

```sh
zig build run
```

First run: macOS will prompt for camera access — click **Allow**. If
you don't see a prompt, your terminal app may already hold camera
permission from a previous grant (check **System Settings → Privacy &
Security → Camera**).

You'll see output like:

```
listening on 0.0.0.0:8080 -- reachable at http://<this-machine's-LAN-IP>:8080
find your LAN IP with: ipconfig getifaddr $(route get default | awk '/interface:/{print $2}')
```

Run that command (or check **System Settings → Wi-Fi → Details**) to
find the URL other devices on your network should use.

## Endpoints

| Path | What you get |
|---|---|
| `/` | Plain-text banner, just confirms the server is up |
| `/snapshot.jpg` | A single current JPEG frame |
| `/stream` | Live MJPEG video (`multipart/x-mixed-replace`) — open in a browser, or VLC via **File → Open Network...** |

Every frame includes a small overlay (top-left) showing the app name,
current time, fps, CPU%, and RAM usage.

## Testing

```sh
zig build test
```

Runs the automated suite (unit tests + real-socket integration tests).
A few tests exercise Zig 0.16's newer `Io`-based networking/threading
primitives under concurrent load; very rarely (roughly 1 in 50-100
runs, in testing) a run may hit an intermittent crash isolated to the
test suite's own thread-accumulation pattern, not the running program.
Re-running resolves it.

## Known characteristics (not bugs)

- **No authentication.** Anyone who can reach the machine's IP on port
  8080 can view the stream. Fine for a trusted home network, not for
  anything more exposed.
- **CPU usage is high (100%+) even when idle, and not fully explained.**
  Frame processing is throttled to ~10fps (both at the camera-driver
  level via `activeVideoMinFrameDuration` and as a software backstop),
  and per-frame object allocation was profiled and fixed where found —
  yet overall CPU didn't drop proportionally. Per-thread profiling
  (`sample`, `top -stats th,cpu`) shows the process running **56
  threads**, most spawned internally by AVFoundation/CoreMedia/
  ANEServices for camera session management, not by this codebase's
  own capture loop. The dominant cost appears to be in that internal
  session machinery rather than anything under this project's control,
  but confirming that precisely would need Instruments-level
  time-based profiling, not just sample-based inference — left as an
  open question rather than guessed at further. Not a leak either way —
  verified stable (not growing) in Activity Monitor and with `leaks`
  over multi-minute runs.
- **macOS only.** Uses AVFoundation/CoreImage/ImageIO/CoreText via a
  thin Objective-C shim (`src/platform/macos/`). Raspberry Pi/ESP32
  support would need a separate platform backend.
- **No graceful shutdown.** `Ctrl-C` / `kill` the process; there's no
  cleanup handler.

## Project layout

```
src/
  main.zig            entry point: spawns the capture thread + HTTP server
  http.zig            HTTP server, routing, /snapshot.jpg and /stream handlers
  capture_loop.zig     mutex-guarded "latest frame" slot, fed by the capture thread
  platform/macos.zig   Zig bindings for the Objective-C shim below
  platform/macos/      AVFoundation capture, ImageIO JPEG encode, CoreText overlay
```

See `tasks/plan.md` for the original implementation plan and design
rationale.
