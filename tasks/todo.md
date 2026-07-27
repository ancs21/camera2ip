# webcam2ip — Task List

Full detail (acceptance criteria, verification, files, sizing) in `tasks/plan.md`.

## Phase 0: Foundation & De-risking
- [x] T1 — Bare project scaffold (S)
- [x] T2 — ObjC↔Zig FFI spike (S)
- [x] T3 — Zig 0.16 `Io.net` spike (S/M)
- [x] T4 — `Io.Mutex` + cross-thread spike (S)

### Checkpoint: Phase 0
- [ ] ObjC/Foundation linking works, ownership convention documented
- [ ] Raw `Io.net` sockets work (curl/nc against a loopback listener)
- [ ] `Io.Mutex` cross-thread locking proven correct across 10+ runs

## Phase 1: Capture spike (no network)
- [x] T5 — AVFoundation session + delegate callback proof (M, highest uncertainty)
- [x] T6 — Raw pixel extraction → `.ppm` (S/M)
- [ ] T7 — JPEG encode via ImageIO → `.jpg` (M)

### Checkpoint: Phase 1
- [ ] Single frame captures from the real camera and becomes a valid, correctly-colored JPEG on disk
- [ ] Camera permission / TCC behavior observed on-device (not just designed around)

## Phase 2: Networked snapshot
- [ ] T8 — HTTP server skeleton (M)
- [ ] T9 — Long-lived capture loop + mutex-guarded latest-frame slot (M/L, second-highest risk)
- [ ] T10 — Wire `/snapshot.jpg` (S)

### Checkpoint: Phase 2
- [ ] `/snapshot.jpg` returns real, fresh camera JPEGs over HTTP
- [ ] Capture loop soak-tested independently for 5+ minutes, no stall/crash/memory growth

## Phase 3: Live MJPEG stream (v1 done)
- [ ] T11 — `/stream` MJPEG handler (M)
- [ ] T12 — Multi-client sanity pass + README (S)

### Checkpoint: Phase 3 = v1 complete
- [ ] Browser at `/stream` shows live video
- [ ] VLC (Open Network Stream) at the same URL also shows live video
- [ ] Disconnecting a client stops CPU spin within a few seconds
- [ ] No auth / UI / recording / config file — matches converged v1 scope
