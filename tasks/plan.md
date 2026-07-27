# webcam2ip — v1 Implementation Plan (macOS, Zig 0.16.0)

## Context

This came out of an idea-refine session. The converged direction: a Zig CLI that turns a Mac's webcam into a live MJPEG-over-HTTP stream (`http://localhost:PORT/stream`, viewable in a browser or VLC). The primary motivation is learning Zig systems programming deeply — not shipping speed — so this plan sequences work to retire the riskiest unknowns first rather than leaving them for the end. Raspberry Pi and ESP32 are explicitly out of scope; they're separate future planning passes once this macOS v1 proves the concept.

**Critical grounding note:** the installed toolchain is Zig **0.16.0**, which has moved further than most published docs (including this project's `zig` skill, which documents 0.15.2). Networking and mutexes now live under a new `std.Io` interface, threaded explicitly through an `io: Io` handle obtained from `std.process.Init` — `std.net.zig` no longer exists as a top-level file (moved to `std/Io/net.zig`), and `std.Thread.Mutex`-style code is superseded by `Io.Mutex` (`lock(io)`/`unlock(io)`, `std/Io.zig:1587`). This was verified directly against the installed stdlib source at `/Users/x42/.local/share/zigup/0.16.0/files/lib/std`, not assumed. `std.Thread.spawn` for plain OS threads is unaffected and still works as before. Every task below assumes this corrected API surface.

## Architecture Decisions

- **Thin Objective-C shim, isolated under `src/platform/macos/`.** macOS has no C API for camera capture — AVFoundation is Objective-C only. A `.m`/`.h` shim exposes a plain C ABI, compiled via `exe.root_module.addCSourceFile(...)` and linked against `AVFoundation`, `CoreMedia`, `CoreVideo`, `CoreGraphics`/`ImageIO`, `Foundation` (`exe.root_module.linkFramework(name, .{})`) plus `linkSystemLibrary("objc", .{})` and `link_libc = true`. Keeping all platform code under one directory means a later Linux/Pi port only needs a new shim, not a rewrite of the server/streaming logic.
- **One ABI ownership convention, established once (T2), reused everywhere:** shim functions returning owned memory `malloc()` it C-side; Zig calls a matching `_free()`. ARC handles ObjC objects inside the `.m` file; explicit `CFRetain`/`CFRelease` only for Core Foundation types.
- **JPEG encoding via ImageIO/CoreGraphics inside the shim**, not a third-party C library and not hand-rolled CoreFoundation interop from Zig — keeps the "lean, no extra deps" goal without taking on manual `CFRetain`/`CFRelease` bookkeeping as a second thing to learn simultaneously.
- **A dedicated capture thread, started once at process startup (Phase 2, not deferred to Phase 3).** It owns and pumps its own `CFRunLoop` (needed because `AVCaptureDevice.requestAccess`'s completion handler dispatches to the main queue, which nothing drains in a bare CLI), captures, JPEG-encodes each frame, and writes the bytes into a **double-buffered**, `Io.Mutex`-guarded "latest frame" slot. Double buffering avoids a reader ever observing a torn frame. `/snapshot.jpg` (Phase 2) and `/stream` (Phase 3) both just read this slot — building a separate request-triggered capture path for the snapshot endpoint and throwing it away later was avoided.
- **Thread-per-connection HTTP accept loop.** A long-lived `/stream` client must not block a quick `/snapshot.jpg` request. This is a deliberate reading of "no multi-client optimization" as "don't optimize for many concurrent streams," not "block everything behind one connection."
- **No graceful shutdown (SIGINT/Ctrl-C handling) in v1.** Not in the converged scope; `kill`/Ctrl-C-terminate is acceptable for a learning-focused v1.

## Dependency Graph

```
T1 (scaffold)
 ├─> T2 (ObjC FFI spike)
 ├─> T3 (Io.net spike)
 └─> T4 (Io.Mutex + cross-thread spike)

T2 ─> T5 (AVFoundation session + callback proof)
T5 ─> T6 (raw pixel extraction → .ppm)
T6 ─> T7 (JPEG encode → .jpg)

T3 ─> T8 (HTTP server skeleton)
T4 ─> T9 (long-lived capture loop + latest-frame slot)  ┐
T7 ─> T9 ────────────────────────────────────────────────┘

T8 ─> T10 (/snapshot.jpg)
T9 ─> T10

T8 ─> T11 (/stream, MJPEG)
T9 ─> T11

T10 ─> T12 (multi-client pass + README)
T11 ─> T12
```

Phase 0 = {T1–T4} · Phase 1 = {T5–T7} · Phase 2 = {T8–T10} · Phase 3 = {T11–T12}

---

## Phase 0 — Foundation & De-risking

Goal: retire the two biggest unknowns (ObjC interop, and the 0.16 `Io`/networking/concurrency surface) before either is load-bearing for real feature code.

### T1 — Bare project scaffold
- **Description:** `build.zig`, `build.zig.zon` (`minimum_zig_version = "0.16.0"`), `src/main.zig`. Use `pub fn main(init: std.process.Init) !void` from the start (not zero-param `main`) — every later task needs `init.io` (networking, mutex, sleep) and `init.gpa`/`init.arena`. `zig build run` prints a startup banner.
- **Acceptance criteria:** `zig build run` compiles and prints the banner; `zig build test` passes (trivially).
- **Verification:** run `zig build run`; run `zig build test`.
- **Dependencies:** none. **Files:** `build.zig`, `build.zig.zon`, `src/main.zig`. **Size:** S

### T2 — ObjC↔Zig FFI spike
- **Description:** `src/platform/macos/shim.m` + `shim.h` expose one C-ABI function that does something genuinely ObjC (allocates/uses an `NSString`, returns a derived value) — proving Foundation actually links and runs, not just that C linking works. Compiled via `addCSourceFile` with `-fobjc-arc`, linked against `Foundation` + `libobjc`, `link_libc = true`. Hand-write the `extern "c" fn` declaration in `src/platform/macos.zig` rather than `@cImport`-ing ObjC/Foundation headers. Document the ABI ownership convention (malloc/free + ARC boundary) in `shim.h`.
- **Acceptance criteria:** build links successfully; the function is called from `main.zig` and its result is verifiably correct.
- **Verification:** run binary, confirm output; remove the framework link and confirm the build fails (sanity check it was actually required).
- **Dependencies:** T1. **Files:** `src/platform/macos/shim.{h,m}`, `src/platform/macos.zig`, `build.zig`. **Size:** S

### T3 — Zig 0.16 `Io.net` spike
- **Description:** Using `init.io`: `Io.net.IpAddress.parseLiteral`/`.listen(&addr, io, .{...})` → `Server`, loop `server.accept(io)` → `Stream`, `stream.reader(io, buf)`/`stream.writer(io, buf)`, echo a fixed reply, close. No `std.http` involved — isolates "does raw `Io.net` work" from "does the HTTP layer built on it work."
- **Acceptance criteria:** `curl`/`nc` against the raw listener gets the fixed reply; survives repeated sequential connections.
- **Verification:** manual `curl`/`nc` test; `lsof -p <pid>` stays flat across repeated connects (no fd leak).
- **Dependencies:** T1. **Files:** `src/main.zig` (spike, later refactored into `src/http.zig` in T8). **Size:** S/M — least-documented API surface in the project; budget extra time.

### T4 — `Io.Mutex` + cross-thread spike
- **Description:** Spawn a plain OS thread via `std.Thread.spawn` (confirmed unaffected by the `Io` changes), pass the same `io` value into it by value, and from both threads `Io.Mutex.lock(io)`/`.unlock(io)` around a shared counter. Validates that an `io` handle is safe to use for locking from a thread not itself spawned through any `Io`-managed mechanism — exactly the situation the real capture thread (T9) will be in.
- **Acceptance criteria:** final count is deterministically `N_main + N_thread` across repeated runs.
- **Verification:** run 10+ times in a loop; a flaky result is a real finding that must be resolved before Phase 2.
- **Dependencies:** T1. **Files:** `src/main.zig` (spike, pattern reused in `src/capture_loop.zig`). **Size:** S

**Checkpoint — Phase 0:** ObjC/Foundation linking works with a documented ownership convention; raw `Io.net` sockets work; `Io.Mutex` cross-thread locking is proven correct under repeated runs.

---

## Phase 1 — Capture spike (no network)

### T5 — AVFoundation session + delegate callback proof
- **Description:** Shim opens the default camera, builds an `AVCaptureSession` + `AVCaptureVideoDataOutput`, sets a sample-buffer delegate, starts the session, proves at least one callback fires (counter/flag only, no pixel extraction yet). **Architectural decision:** run the entire capture session (permission request + session + delegate) on its own dedicated `std.Thread`, which owns and pumps its own `CFRunLoop` with a bounded timeout — keeps the HTTP accept loop's main thread untouched and confines the run-loop-pump requirement to one place. Confirm on-device that permission completion handlers actually fire from a background thread's own run loop.
- **Acceptance criteria:** on a real Mac, the camera permission prompt appears on first run; once granted, a delegate callback fires within a bounded timeout; a clear non-hanging error path exists if no camera is present or permission is denied.
- **Verification:** on-device test with permission not-yet-granted, then granted, then camera covered/unavailable (confirm timeout, not a hang).
- **Dependencies:** T2. **Files:** `src/platform/macos/capture.{h,m}`, `src/platform/macos.zig`, `build.zig` (+`AVFoundation`, `CoreMedia`, `CoreVideo`). **Size:** M in code, but **highest-uncertainty task in the project** — whether a bare unsigned Terminal-launched binary even gets a permission prompt (vs needing an `.app` bundle/`Info.plist`) can only be answered by hands-on testing, not more design. Budget slack around this task.

### T6 — Raw pixel extraction → `.ppm`
- **Description:** Extend the shim so the callback copies the `CVPixelBuffer`'s raw bytes (width, height, `bytesPerRow` stride, pixel format — macOS camera output is typically YUV, not RGB; conversion via `CVPixelBufferLockBaseAddress` + a `CIImage`/`CIContext` render is real work) into a Zig-owned buffer per T2's ABI convention. Zig writes it to an uncompressed `.ppm`.
- **Acceptance criteria:** the `.ppm`, opened in Preview, correctly shows the camera's view — correct colors (no channel swap), correct orientation, no stride-tearing.
- **Verification:** capture an asymmetric test scene, confirm color/orientation; run twice, confirm each file is a fresh frame.
- **Dependencies:** T5. **Files:** `src/platform/macos/capture.{h,m}`, `src/main.zig`. **Size:** S/M

### T7 — JPEG encode via ImageIO → `.jpg`
- **Description:** Shim function using `CGImageDestinationCreateWithData` (targeting `CFMutableData`) from a `CGImage` built off the pixel buffer, kept inside the ObjC shim (ARC/Foundation idioms) rather than pure-Zig CoreFoundation interop.
- **Acceptance criteria:** resulting `.jpg` opens correctly with colors/orientation matching the T6 `.ppm` from the same capture.
- **Verification:** manual open; compare against the T6 output from the same run.
- **Dependencies:** T6. **Files:** `src/platform/macos/capture.{h,m}`, `src/main.zig`, `build.zig` (+`ImageIO`, `CoreGraphics`). **Size:** M

**Checkpoint — Phase 1:** a single frame captures from the real camera and becomes a valid, correctly-colored JPEG on disk; the run-loop/permission/TCC behavior has been observed on-device, not just designed around.

---

## Phase 2 — Networked snapshot

### T8 — HTTP server skeleton
- **Description:** Real accept loop using `Io.net.IpAddress.listen`/`.accept` (from T3), feeding `stream.reader(io,buf).interface`/`stream.writer(io,buf).interface` into `std.http.Server.init`, `.receiveHead()`, routing on `request.head.target`. GET `/` returns a static response via `Request.respond`. Thread-per-connection (`std.Thread.spawn(...).detach()`) per the architecture decision above.
- **Acceptance criteria:** `curl http://localhost:PORT/` returns 200 with correct headers; concurrent curls from two terminals both succeed.
- **Verification:** `curl -v`; two-terminal concurrent test.
- **Dependencies:** T3. **Files:** `src/http.zig`, `src/main.zig`. **Size:** M

### T9 — Long-lived capture loop + mutex-guarded latest-frame slot
- **Description:** At startup, spawn the T5-designed capture thread (own pumped `CFRunLoop`, session start, permission handling). Its callback, per frame: extract pixels (T6), JPEG-encode (T7), store into a double-buffered slot guarded by `Io.Mutex` (T4's proven pattern). Include a standalone debug harness (main thread prints "latest frame size + timestamp" every second) to soak-test the hand-off *before* any HTTP code depends on it.
- **Acceptance criteria:** runs for several minutes with continuously updating frame timestamps/sizes, no stall/crash/memory growth.
- **Verification:** run harness 5+ minutes; wave at camera, confirm content changes are reflected; spot-check memory via Activity Monitor/`leaks`.
- **Dependencies:** T4, T7. **Files:** `src/capture_loop.zig` (new), `src/main.zig`. **Size:** M/L — second-highest risk in the project ("works once" vs "works correctly under sustained access" is a different bar). **If it grows past a day's work, split** into T9a (loop + double buffer + soak harness, raw frames only) and T9b (add JPEG encoding into the loop).

### T10 — Wire `/snapshot.jpg`
- **Description:** `GET /snapshot.jpg` reads the latest JPEG out of T9's slot under lock, returns via `Request.respond` with `Content-Type: image/jpeg`. Explicit startup-race handling: if a request arrives before the capture thread's first frame, either block briefly (bounded) or return `503` — pick one, document it.
- **Acceptance criteria:** repeated `curl -o out.jpg .../snapshot.jpg` produces valid, visibly fresh JPEGs; correct headers; startup race behaves as decided.
- **Verification:** repeated curls with visual diffs; restart server and immediately curl to exercise the race.
- **Dependencies:** T8, T9. **Files:** `src/http.zig`, `src/capture_loop.zig`. **Size:** S

**Checkpoint — Phase 2:** `/snapshot.jpg` returns real, fresh camera JPEGs over HTTP; the capture loop + mutex hand-off is soak-tested independently of the HTTP layer.

---

## Phase 3 — Live MJPEG stream (v1 done)

### T11 — `/stream` MJPEG handler
- **Description:** `GET /stream` via `Request.respondStreaming(buffer, options)` → `BodyWriter`. Loop at ~10fps (`Io.sleep`/timer via `io`): lock T9's mutex, read latest JPEG, unlock, write `--boundary\r\nContent-Type: image/jpeg\r\nContent-Length: N\r\n\r\n<bytes>\r\n`, `.flush()`. Detect client disconnect via write/flush failure and break the loop. Use the conventional mjpg-streamer-style boundary/framing rather than inventing one.
- **Acceptance criteria:** a browser at `.../stream` shows live updating video; **VLC's Open Network Stream at the same URL also plays it — test both explicitly**, don't assume browser success implies VLC compatibility. Disconnecting a client causes the handler thread to exit within a bounded time (CPU% doesn't pin at 100%).
- **Verification:** browser test; VLC test; `curl .../stream | xxd | head` to eyeball raw framing; disconnect test with Activity Monitor open.
- **Dependencies:** T8, T9. **Files:** `src/http.zig` or `src/stream.zig`. **Size:** M — if VLC needs meaningfully different framing than browsers, split into T11a (browser/chunked+multipart) and T11b (VLC compatibility pass).

### T12 — Multi-client sanity pass + README
- **Description:** Confirm `/stream` connected + `/snapshot.jpg` request doesn't wedge the server (validates T8's thread-per-connection choice); confirm two simultaneous `/stream` tabs each get independent video. README covers build/run and how to grant camera TCC permission for this binary.
- **Acceptance criteria:** documented manual test matrix passes; a fresh clone can build/run/grant-permission/see-stream from the README alone.
- **Verification:** manual multi-window test; re-run steps simulating a first-run experience.
- **Dependencies:** T10, T11. **Files:** `README.md`, minor fixes across `src/*`. **Size:** S

**Checkpoint — Phase 3 = v1 done:** browser or VLC at `.../stream` shows live video, no auth/UI/recording/config file — matches converged scope exactly.

---

## Risks / Mitigations

| # | Risk | Mitigation |
|---|---|---|
| 1 | `AVCaptureSession` delegate never fires from a bare CLI (no `NSApplication` run loop) | T5 isolated on-device spike before any dependent code exists |
| 2 | macOS camera TCC permission for an unsigned, bare-Mach-O, Terminal-launched binary — may need an `.app` bundle/`Info.plist`, may silently deny instead of prompting | Cannot be resolved by code review; tested hands-on in T5, early enough that a "needs `.app` bundle" finding doesn't blow up the build design later |
| 3 | Assumed APIs don't exist in 0.16.0 (`std.net.Address.listen`, `std.Thread.Mutex`-style locking) | T3/T4 spikes done before HTTP/concurrency code depends on the corrected `Io.net`/`Io.Mutex` shapes — verified directly against installed stdlib source |
| 4 | Pixel format handling (YUV→RGB, `bytesPerRow` stride padding) — silent color/tearing corruption | T6's raw `.ppm` dump gives an eyeballable checkpoint before JPEG compression can mask the same bug |
| 5 | `multipart/x-mixed-replace` + chunked encoding compatibility differs between browsers and VLC | T11 tests both explicitly, uses a conventional boundary format |
| 6 | Frame hand-off race/tearing under sustained run | T9's double-buffer design + dedicated soak-test harness, independent of HTTP debugging |
| 7 | ObjC/CoreFoundation memory ownership across the C ABI is easy to get wrong (leak/double-free) | T2 establishes one convention, reused by every later shim function; T9's soak test surfaces leaks via memory growth |
| 8 | Whether an `io` handle is safe to use from a thread not spawned through `Io` | T4 spike proves this explicitly, 10+ runs, before T9 relies on it |
| 9 | Graceful shutdown (Ctrl-C) leaves the capture session in a bad state | Out of scope for v1 by design — see Not Doing |

## Assumptions Being Made (flag if wrong)

1. Thread-per-connection HTTP accept loop (not strictly serial).
2. Capture session is long-lived from process startup (Phase 2), not opened per-request.
3. No SIGINT/graceful-shutdown handling in v1.
4. Default port **8080** (macOS AirPlay Receiver squats on 5000/7000 on modern macOS).
5. Uses whatever camera `AVCaptureDevice.default(for: .video)` returns — no device-selection mechanism (consistent with "no config file").
6. ObjC ABI convention: malloc/free for shim-owned buffers, ARC inside `.m` files, explicit `CFRetain`/`CFRelease` only for Core Foundation types.

## Not Doing (v1, explicit)

- Raspberry Pi / ESP32 ports — future planning pass, after this proves the concept.
- Auth, recording, motion detection, multi-client optimization beyond "doesn't wedge."
- A packaged `.app` bundle / code signing, unless T5's on-device testing shows it's required for camera permission to work at all.
- Config file / CLI flags — hardcoded port/resolution/fps for v1.
- Graceful shutdown handling.

## Verification (end-to-end, once v1 is built)

1. `zig build run` starts the server, prints "listening on :8080".
2. First run: macOS camera permission prompt appears; grant it.
3. `curl -o out.jpg http://localhost:8080/snapshot.jpg` → valid JPEG, visibly matches current camera view.
4. Open `http://localhost:8080/stream` in a browser → live video.
5. Open the same URL in VLC (Open Network Stream) → live video.
6. Close the browser tab → server-side handler exits within a few seconds, CPU% drops back to idle.

### Critical Files
- `/Users/x42/Code/Learning/webcam2ip/build.zig`
- `/Users/x42/Code/Learning/webcam2ip/src/main.zig`
- `/Users/x42/Code/Learning/webcam2ip/src/platform/macos/capture.m` (+ `shim.m`/`.h`)
- `/Users/x42/Code/Learning/webcam2ip/src/capture_loop.zig`
- `/Users/x42/Code/Learning/webcam2ip/src/http.zig`
