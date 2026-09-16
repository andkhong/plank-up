# Plank Up

Blocks distracting apps until you complete a camera-verified plank.

Existing app blockers add *cognitive* friction — a tap to dismiss, a password you set
yourself — so the user simply decides to stop caring. Plank Up replaces it with physical
friction. You cannot decide your way past a plank.

## Status

Pre-alpha. Domain core and project scaffold only; no UI, no native modules yet.

The build is gated on two things that are not code:

1. **A demo video**, to test whether the hook pulls before committing months to it.
2. **Apple's Family Controls entitlement**, which is manually reviewed with no SLA and must
   be requested for the app *and every extension* — it is granted per-target, and an
   approved app with unapproved extensions fails silently.

## Layout

```
app/                        Flutter app
  lib/domain/               Pure Dart. No Flutter imports, no plugins, no DateTime.now().
    economy/                Effort -> earned access time
    enforcement/            "Is this app blocked right now" — the precedence kernel
    schedule/               Recurring block windows ("the Wall")
packages/plankup_platform/  Native modules: pose detection + OS-level blocking
docs/DESIGN.md              Full design, architecture, QA strategy and market research
fixtures/                   Recorded landmark streams for evaluator regression tests
tool/                       Fixture validator and CI scripts
```

## What the fixtures cannot see

The landmark corpus begins *after* detection already succeeded, so it is
structurally blind to acquisition failure — the case where the model returns no
person at all. That matters because the pose model family uses a face detector
as its person-detector, and that detector has a documented skin-tone recall gap.
A fixture that starts from landmarks has by construction already passed the step
most likely to fail. Closing that gap needs recorded video, which needs consent
management and an artifact store that do not exist yet.

## Design rules that are easy to break by accident

- **`lib/domain/` stays pure.** No `package:flutter`, no plugins, no `DateTime.now()`.
  Time is injected. This is what lets the correctness core run in milliseconds with no
  device.
- **Camera frames never cross the platform channel.** Native owns capture and inference and
  emits ~15 Hz of landmarks (~20 KB/s). Shipping 30fps of frames would be ~13.8 MB/s.
- **Session timing comes from native frame timestamps, never a Dart `Timer`.** This makes
  pipeline latency and UI jank mathematically irrelevant to scoring.
- **Low pose confidence is not bad form.** Losing the skeleton must never fail a session.
  If we can't see you, that's our problem.

## Running

```bash
cd app
flutter test      # 505 passing
flutter analyze
flutter run -d chrome   # the demo harness
```

Requires Flutter 3.47+. Xcode and a physical iPhone are required for Screen Time, which
does not exist in a simulator.

## The demo harness

`flutter run -d chrome` opens a harness that drives the **real** evaluator, session machine
and unlock economy — not a mockup. It has two sources:

- **Synthetic** (default): a slider moves hip deviation through a solved-for body, so the
  form ladder can be exercised deterministically.
- **Live camera**: MediaPipe pose landmarking in the browser, feeding the same canonical
  `PoseFrame` the platform channel will carry on device. Inference runs in JS next to the
  frames and only landmarks cross into Dart — the same boundary as production.

The live camera is a *pipeline* check, not a *form* check. A laptop webcam sits at eye
level with the user facing it, which is not the plank geometry, so the evaluator will
correctly decline to score it. What it proves is that real landmarks flow end to end.
# plank-up
