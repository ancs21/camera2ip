# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Zig learning project: turns a Mac's built-in/USB webcam into a network-reachable
MJPEG-over-HTTP IP camera. No auth, no UI, no recording, no config file — deliberately
minimal v1 scope. macOS only (AVFoundation has no cross-platform equivalent).

## Commands

```sh
zig build run    # build + run; starts capture thread + HTTP server on 0.0.0.0:8080
zig build test   # unit tests + real-socket integration tests
```

Run a single test by name:
```sh
zig build test --test-filter "onFrame throttles"
```

No lint/format-check step exists beyond `zig build` itself (which fails on compile errors).
`zig fmt src build.zig` is the formatter if asked to format.

First `zig build run` triggers a macOS camera permission prompt — must be granted
interactively; cannot be automated. If a terminal app already holds camera permission
from a previous grant, no prompt appears (check System Settings → Privacy & Security → Camera).

The test suite is very rarely (~1 in 50-100 runs) subject to an intermittent crash isolated
to the test binary's own thread-accumulation pattern under Zig 0.16's `Io`-based primitives
(see `startTestServer`'s doc comment in `src/http.zig`), not the running program. Re-run if hit.

## Critical version gotcha

Toolchain is **Zig 0.16.0**, which is newer than most published docs/training data reflect.
`std.net` no longer exists as a top-level module — networking moved to `std.Io.net`
(`Io.net.IpAddress`, `.listen(io, ...)`, `Server.accept(io)`, `Stream.reader(io, buf)`/
`.writer(io, buf)`). Mutexes are `Io.Mutex` (`lock(io)`/`unlock(io)`), not
`std.Thread.Mutex`. Wall-clock/monotonic time is `Io.Timestamp.now(io, .real | .awake)`,
not `std.time.timestamp()`/`nanoTimestamp()` (removed). `std.Thread.spawn` for plain OS
threads is unaffected. `pub fn main(init: std.process.Init) !void` is the entry point
shape — `init.io` and `init.gpa` thread through everywhere. Don't reach for pre-0.16
networking/mutex/time patterns from memory; check `src/http.zig`, `src/capture_loop.zig`,
and `src/main.zig` for the actual current-version usage first. (The `zig` skill exists in
this environment but documents 0.15.2 — it does not reflect 0.16's `Io` surface.)

## Architecture

Three concurrent execution contexts, connected only through a mutex-guarded slot:

```
capture thread (dedicated, detached)          HTTP accept loop (main thread)
  platform/macos/capture.m:                     http.zig: listen + accept
    AVCaptureSession, pumps its own                → thread-per-connection,
    CFRunLoop forever                                 each detached
    → onFrame() callback per frame            handleConnection → route on
      (capture_loop.zig, runs ON the             request.head.target:
       capture thread's queue)                    /            -> banner
        throttle to ~10fps (software              /snapshot.jpg -> one frame
          backstop; camera driver also              from the slot
          throttled via                          /stream       -> loop: read
          activeVideoMinFrameDuration)               slot every ~100ms, write
        draw overlay (CoreText, in place)           as multipart/x-mixed-replace
        encode JPEG (ImageIO)
        lock -> write into g_slot -> unlock
                          |
                          v
              FrameSlot { mutex, jpeg bytes, width, height, ... }
              (capture_loop.zig, module-level global)
                          ^
                          | lock -> copy bytes out -> unlock
                          |
              readers: main.zig's 1s debug harness (writes frame.jpg),
              http.zig's /snapshot.jpg and /stream handlers
```

- **`src/main.zig`** — entry point. Spawns the capture thread and the HTTP thread
  (both detached, both expected to run for the process lifetime), then itself runs a
  debug harness loop that copies the latest frame every second to `frame.jpg` (gitignored;
  a visual soak-test aid, not a feature).
- **`src/capture_loop.zig`** — owns `g_slot` (`FrameSlot`), the single hand-off point
  between the capture thread and everything else. `onFrame` (invoked synchronously on
  AVFoundation's capture queue) throttles, draws the overlay, JPEG-encodes, and stores
  into the slot under `Io.Mutex`. `copyLatestFrame` is the only read path — it copies
  bytes out while holding the lock (fast memcpy) rather than the writer double-buffering,
  so the writer is never blocked by a slow reader. Test-only hooks (`seedFrameForTesting`,
  `resetForTesting`) let other modules' tests drive frames without a real camera —
  **always call these through the lock**, never poke `g_slot` fields directly (an earlier
  unsynchronized version caused a real, reproducible data-race crash inside `Io.Mutex`).
- **`src/http.zig`** — listen/accept loop (`Io.net`), thread-per-connection so a
  long-lived `/stream` client can't block `/snapshot.jpg`. `/stream` uses traditional
  close-delimited `multipart/x-mixed-replace` (not chunked transfer-encoding) — matches
  mjpg-streamer/most MJPEG cameras, for both-browser-and-VLC compatibility.
- **`src/platform/macos.zig`** — hand-written `extern "c" fn` declarations for the ObjC
  shim (no `@cImport` of ObjC/Foundation headers). Mirrors the C ABI declared in
  `src/platform/macos/capture.h`.
- **`src/platform/macos/`** — the only platform-specific code in the project; a Linux/Pi
  port would mean writing a new directory like this one, not touching `http.zig` or
  `capture_loop.zig`. `shim.{h,m}` is a minimal proof that Foundation actually links.
  `capture.{h,m}` does the real work: `AVCaptureSession` setup + permission request,
  YUV→RGBA conversion, JPEG encoding (ImageIO), text overlay (CoreText), process CPU/RSS
  stats (`getrusage`). `w2i_capture_run_continuous` pumps its calling thread's `CFRunLoop`
  forever — it must be called from a dedicated thread, never the main/HTTP thread.

**ABI ownership convention** (established once, reused by every shim function): ObjC
objects are ARC-managed inside the `.m` files and never cross the C boundary directly.
Buffers/strings returned to Zig are `malloc()`'d C-side and freed via a matching
`w2i_*_free()` call from Zig. Core Foundation types, if ever added, would need explicit
`CFRetain`/`CFRelease` since ARC doesn't manage them.

**Frame throttling**: target ~10fps end-to-end, enforced twice — at the camera-driver
level (`activeVideoMinFrameDuration`) and as a software backstop in `onFrame` (skip
frames arriving faster than `target_frame_interval_ns`). JPEG encoding is the expensive
step per profiling; skipping frames rather than encoding every one is the main CPU lever.
See the README's "Known characteristics" section for the current unresolved CPU
investigation (56 threads, most from AVFoundation/CoreMedia internals, not this codebase).

## Testing notes

- `capture_loop.zig`'s `FrameSlot` is a module-level global shared across the whole test
  binary. Tests that seed/reset it use `std.heap.page_allocator` for the slot's own
  storage (intentionally never freed — matches production, where the slot lives for
  process lifetime) but `std.testing.allocator` for anything returned to the caller
  (e.g. `copyLatestFrame`'s copies), so the leak checker still verifies what it should.
- `http.zig`'s `startTestServer`/`TestServer` helper binds synchronously before spawning
  the accept loop on a background thread (avoids a listen-vs-connect race), and must be
  `stop()`'d before the test ends — letting detached accept-loop threads accumulate across
  the whole test binary's lifetime previously triggered a rare crash under concurrent
  `Io.Mutex`/`DebugAllocator` contention.
- Each test binds a distinct port to avoid cross-test races.
