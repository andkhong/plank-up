# Plank Up — Design & Implementation Plan

> Complete. Synthesized from five agents — UI/UX design, system architecture,
> implementation blueprint, adversarial QA, and market research — with cross-agent
> conflicts resolved and load-bearing claims independently spot-checked.

## Context

**The problem.** Opening Instagram or TikTok is a near-zero-friction habit loop. Existing
app blockers add friction that is trivially bypassed — a tap on "ignore limit," a
password the user themselves set. The friction is cognitive, so the user simply decides
to stop caring.

**The idea.** Plank Up replaces cognitive friction with *physical* friction. Blocked apps
stay blocked until the user completes a plank, verified in real time by the front camera
via on-device pose estimation. You cannot decide your way past a plank. The cost is
paid in effort, not willpower, and the side effect is a daily core workout.

**Intended outcome.** A shippable consumer app on both the App Store and Google Play
where a user can: pick apps to block, be intercepted when they reach for one, prop their
phone on the floor, hold a verified 30–90 second plank with live form coaching, and earn
a proportional window of access.

## Market reality — read this before the rest

Market research was commissioned to settle the v1 scope question with evidence rather than
engineering intuition. It found something the three build agents could not have known, and it
changes the recommended course of action.

### The niche is not empty. It is crowded, and it already has a winner.

**At least 40 shipping apps** already gate app access behind camera-verified exercise —
Pushscroll, PushUp Time, StepBloc, RepScroll, FitBlok, squat to scroll, SquatLock, Fit to
Scroll, SweatPass, and roughly thirty more. TechCrunch covered the category on 2026-08-01.

**Plank is already covered.** FitBlok, RepScroll, Replock, Fit to Scroll, SweatPass and
Pushscroll all support it. One app — *PushUp: Screen Time & Fitness* — ships literally this
mechanic: a 60-second plank for 10 minutes of scrolling. Nobody ships plank-*only*, which is
the remaining differentiation, and it is thin.

### It is a power law, and the tail is brutal

| App | Traction | Revenue |
|---|---|---|
| **Pushscroll** | ~200K users, 18K ratings, 4.7★ | **~$100K MRR, $1M+ year one** |
| PushUp Time | 12K ratings, 4.7★ | not public |
| PushLock | — | $481 MRR |
| **Push Up Time** (different app) | 580 ratings, **4.7★** | **$11 MRR. Listed for sale at $263.** |
| FitBlok | 25 ratings | abandoned after 4 months |

That fourth row is the one to sit with: **a 4.7-star app in this exact category, with 580
ratings, earns eleven dollars a month and is for sale for less than dinner.** A good product
with good reviews is worth approximately zero here. That is the default outcome, not the tail
risk.

### How the winner won, and what it cost

Pushscroll's founders made a **fake demo video from edited YouTube footage of an app that did
not exist.** It got 80,000 views and comments begging them to build it. *Then* they built it —
"around two weeks," "a very simple MVP with only three screens." $30K MRR in four months on
organic content alone: 40M views, 300K downloads, zero paid acquisition.

**Every engineering estimate in this plan is between 7× and 14× that MVP.**

And their first $5,000 on influencer marketing produced "minimal results." Meanwhile a
competitor doing an estimated **40 million monthly views earns ~$6,000 MRR** — so the binding
constraint is not reach. It is the specific hook and funnel.

### Three findings that directly contradict decisions in this plan

**1. The 10-minute cooldown should be cut.** The behaviour-change literature names our exact
design as its worked example of friction that is too strong: *"blocking a user's smartphone
after a daily usage limit has been hit, with no override option"* drives abandonment.
Restriction produces documented reactance — one study participant reported wanting to *"stay
on just out of spite."* Penalty-design research finds **certainty beats severity**, and that
penalties seen as arbitrary generate defiance rather than compliance.

Ours is arbitrary by construction: triggered by a pose classifier, from the worst camera
geometry in the literature, on the exercise with documented keypoint-localisation failures. A
user who held a good 58-second plank and got failed does not conclude their form broke. They
conclude the app is broken — **and they are right.** We would convert our most committed users
into one-star reviewers.

The market has already voted: PushUp Time added an emergency unlock, RepScroll ships
"Emergency Scroll." And forgiveness has the strongest causal evidence in the whole report —
Duolingo's streak freeze cut churn **21%** among at-risk users.

**2. Gamification evidence runs against us in this category.** Ship the streak (the one element
with direct causal evidence) and a simple history. Not XP, not levels, not sixty achievements.
If progression is added later, it should reward **days under a screen-time goal**, not planks
completed.

**3. Our exchange rate is roughly 3× too generous.** We offer 60 seconds → 30 minutes. The
closest comparable offers 60 seconds → 10 minutes. We are selling screen time at a third of
the going rate, which works directly against the deterrence effect that users say is the
entire point.

### Two things nobody had flagged

**The market leader's plank feature reportedly does not work.** A reviewer describes it as
having *"only worked one time,"* on version 1.273, after 18 months and $1M of revenue. A 2026
JMIR study found camera positioning significantly affects pose accuracy, with diagonal and
frontal views at 180–200cm performing best — **our floor-level, side-on, close-range setup is
near the worst geometry in that study.** Plank is separately a documented hard case: OpenPose
localises only 12 of 18 keypoints in a plank.

**App Review Guideline 4.10 names Screen Time APIs explicitly** as something you may not
monetize. In practice Apple permits Opal, Jomo, Freedom and forty exercise-blockers to charge,
so the operative reading is that you may not charge for bare API access — only for your own
value-add. Direct design consequence: **position the paid tier as the pose engine and the
analytics, never as "pay to block apps."** Existing negative reviews in the category already
use the dangerous framing (*"$12 just to block SCREEN TIME"*).

### The recommended next action costs an afternoon, not seven months

**Make the fake demo video this week, before writing any code.** Plank, phone on the floor,
timer, Instagram unlocking. Post it. If it doesn't land, seven months have been saved for the
price of an afternoon. None of the three engineering options contained this step.

In parallel, **submit the Family Controls entitlement request immediately** — for the app *and
every extension*. It is granted per-target, and a parent app can be approved while its
extensions are not, at which point `ManagedSettings` and `DeviceActivity` triggers are silently
ignored outside development.

## Locked-in product decisions

| Decision | Choice |
|---|---|
| Stack | Flutter (UI + logic) + native Swift/Kotlin modules (pose detection, OS blocking) |
| Unlock economy | **Revised toward category norm** — roughly 30s → 7 min, 60s → 15 min, 90s → 30 min. Exact numbers to tune; the previous rate sold screen time at a third of what competitors charge |
| Duration choice | User picks target duration at session start |
| Form break | Immediate cue + timer **pauses**. It never fails the session |
| Failure penalty | **None — cut.** Giving up early earns proportional partial credit. Low pose confidence never penalizes |
| Differentiation | **Accessibility is the wedge** — unclaimed in this category and an explicit Apple featuring criterion |
| Bypass policy | Escapable with friction: confirmation + enforced delay to disable or edit list |
| Data | Fully local. No account, no backend, no cloud sync |
| Platform order | iOS first, Android second |
| Camera | Front camera, phone propped on floor for a side-on body view |
| Default blocklist | TikTok, Instagram, YouTube, X, Reddit, Snapchat — user-customizable |
| Mascot | Corgi. Placeholder art now; asset slots specified for a future illustrator |
| **Blocking schedule** | User-defined recurring windows (days + time range), not always-on |
| **Monetization** | Freemium subscription. Core blocking + plank free |
| **Exercises** | Plank (free, timed hold); squats + pushups (paid, rep-counted) |
| **Progression** | Rich: achievements, levels/XP, weekly/monthly charts |

### Consequences of the expanded scope

Three of those decisions are not additive — they change the shape of the system:

- **Schedules** introduce a precedence problem. A scheduled block window, an earned
  unlock window, and a failure cooldown can all be in force at once. That resolution
  logic must be one source of truth, and it has to be readable from native processes
  running while the Flutter engine is dead.
- **Rep-counted exercises** change the session state machine. A plank accumulates
  seconds of good form; a squat counts valid reps with down/up phase segmentation,
  depth validation, and debouncing. The exercise-evaluator abstraction is now load-
  bearing rather than speculative, and the unlock economy needs a rep-based equivalent.
- **Subscriptions without a backend** mean local-only entitlement checks (StoreKit 2 /
  Play Billing). Acceptable for self-improvement software, but the limits should be
  stated rather than discovered later.

## Architecture

Accepted. The organizing idea is **three concentric rings of trust and liveness**, with
boundaries placed by *liveness requirement* rather than convenience — code goes native only
if it must run while Dart is dead, or if it must touch 30fps of pixels.

- **Ring 0 — Shared policy state.** A versioned record under 4 KB in an App Group
  (iOS `UserDefaults`) / DataStore (Android). The only thing every process agrees on. It
  outlives the Flutter engine, the app process, and reboots.
- **Ring 1 — Native enforcers.** Small, dependency-free Swift/Kotlin that read Ring 0 and
  apply or lift blocks. Deliberately near-brainless: read state, compare timestamps, set
  shield. They run when Dart is dead.
- **Ring 2 — Dart.** All product semantics and all code that changes often. The only writer
  of intent.

### Form evaluation

The key measurement is **signed normalized hip deviation** — the perpendicular offset of the
hip from the shoulder→ankle line, projected onto the measured gravity vector and normalized
by body length. The sign is what matters: negative is sag, positive is pike. A raw
`angle(shoulder, hip, ankle)` returns an unsigned 0–180° value and literally cannot tell the
two apart, which is why the naive approach fails.

Bands: good ≤12°, degraded 12–22°, broken >22°, with release hysteresis at 9° to stop
oscillation. State changes require 4 of the last 6 frames (~270 ms at 15 Hz) — that is the
answer to "one bad frame shouldn't trigger a warning."

**Gravity is a first-class input**, shipped with every frame from the accelerometer. Because
the phone is propped on the floor, image-space "up" cannot be assumed — it must be measured.
Every geometric check is therefore orientation-independent, and phone-knocked-over detection
comes free from the same signal.

A pushup is deliberately *the plank body-line gate plus elbow cycling* — the same code with a
loosened band, not a second implementation.

### The hold-vs-rep asymmetry

This is the subtle part of generalizing the state machine:

- **Hold:** `quality == broken` pauses accumulation *and* arms the grace timer. Sustained → fail.
- **Reps:** a bad rep **voids the rep and cues** — it never fails the session. Only leaving
  position arms grace. Failing someone's whole session over one shallow squat would be wrong.
- Both get a **stall watchdog** (no progress 20s → warn, 35s → fail), which closes the
  "hold the top of a squat forever" hole reps would otherwise have.

Two guards that are non-obvious and load-bearing: `graceUses > 3` and `cumulativePaused > 12s`
both force a fail. Without them a user can alternate good/bad form and pause the timer
indefinitely.

Credited time accumulates from **native frame timestamps**, not a Dart `Timer`, making it
immune to UI-thread jank; single deltas are clamped to 200 ms so a hitch cannot over-credit.

### Interruptions — all resolved in the user's favor

| Event | Outcome |
|---|---|
| Phone knocked over | Gravity change >25° in <300ms → `aborted`, **no cooldown**. If a gravity discontinuity occurred in the 2s before pose loss, the terminal state is `aborted`, never `failed` |
| App backgrounded | 30s re-entry window, resumes at framing with progress intact. Beyond that, fail. Backgrounding can never *gain* anything since the timer doesn't run while away |
| Incoming call | Detected via `CXCallObserver` / `TelephonyCallback` → `aborted`, no penalty |
| Force-quit mid-attempt | Heartbeat every 2s; stale >15s on next launch → `abandoned`. No reward, **no cooldown** — we cannot distinguish a crash from a force-quit, and force-quitting already grants nothing |
| Reboot mid-cooldown | Survives via dual-clock. Boot-id change falls back to wall clock, floored at `min(remainingWall, fullCooldown)` |

### Precedence algebra

`shouldBlock(app, now)` is a pure function, specified once and **implemented three times**
(Dart, Swift, Kotlin) — code cannot be shared into a 6 MB extension. The answer to "one
source of truth where Dart is dead" is: *you cannot share the code, so share the
specification and its tests.* A single JSON test-vector suite runs in all three languages in
CI; any divergence fails the build.

1. Master disabled → allow
2. App not in blocklist → allow
3. **Cooldown live → block** (outranks unlock; fail closed on any race)
4. **Unlock live and app in scope → allow** (an earned unlock outranks a scheduled window — that is the entire point of the product)
5. Inside an enabled schedule window → block
6. Otherwise allow

The "earn 60 minutes at 08:00 for a window that opens at 09:00" footgun is closed at the
source rather than patched: `canStartAttempt()` requires that something is *currently*
blocked.

### Clock tampering — the trick

Every deadline stores a **pair**: wall clock and monotonic clock. A cooldown expires only
when **both** have passed. An unlock is live only while **both** say so. Therefore setting
the clock forward satisfies wall but not mono → the cooldown persists and the unlock
*shortens*. Setting it backward satisfies neither. **Clock games can only ever hurt the
user.** Android additionally has `SystemClock.currentNetworkTimeClock()` (API 33+,
user-unadjustable); iOS has no trusted-time equivalent and we accept that.

### iOS unlock expiry — three independent fail-closed mechanisms

The main app is usually dead when an unlock expires, and `DeviceActivity` is documented as
unreliable past ~45 minutes. So:

1. **Chained segments.** Never one 60-minute interval — decompose into ≤40 min segments
   honoring the 15-min floor (60 min becomes 35 + 25), using rotating activity names from a
   fixed pool to avoid name-collision clobbering. **Every callback is guarded against Ring 0;
   a callback firing is never itself treated as "time's up."**
2. **Buffered final segment** at `expiry + 90s`, so early fires merely reschedule and late
   fires cost ≤90s of over-unlock. Accept the slop; don't fight the API.
3. **Foreground reconciliation** on every `didBecomeActive`, recomputing from first
   principles and applying **synchronously before any `await`** — async suspension mid-apply
   is a documented way to leave some apps blocked and others open.

Default posture throughout: **fail closed.** For a self-control app, a silent unblock the
user never asked for is the worst possible outcome.

Scheduling uses **one daily-repeating activity per time-range**, with the extension checking
"is today a selected weekday?" and no-opping if not. The naive encoding (one activity per
schedule × weekday) costs 7 activities for a week and would allow roughly two schedules
before hitting the 20-activity cap.

### Android — no AccessibilityService

`UsageStatsManager` polling at ~800 ms, inside a `specialUse` foreground service, with a
translucent full-screen Activity as the interstitial. Two verified reasons to avoid
AccessibilityService entirely, either sufficient on its own:

1. Play policy reserves `isAccessibilityTool` for genuine disability-assistance tools and
   rejects blockers that use it where `UsageStatsManager` suffices.
2. **Android 17 (stable 2026-06-16) Advanced Protection Mode auto-revokes AccessibilityService
   from non-accessibility apps** — it breaks precisely for the security-conscious users most
   likely to want this app.

Cost is ~700 ms of detection latency, which users do not perceive. This also eliminates
alarms entirely: the polling service already runs, so it evaluates schedules inline as a pure
function — sidestepping the `SCHEDULE_EXACT_ALARM` policy problem completely.

Android 17's revocation is worse than a reliability risk: it is a **silent, retroactive kill
switch on already-shipped installs**, with no code path available to prevent it.

**`SYSTEM_ALERT_WINDOW` is still required, and this is the easiest thing in the project to
break by accident.** We no longer use it to draw overlays. We hold it because it is the only
applicable **background-activity-launch exemption** — and per Android's own documentation,
running a foreground service is explicitly *not* one. Our polling service is a background
context by definition, so without this permission it cannot launch the interstitial at all.
A future reader who sees "we don't draw overlays anymore" and removes the permission will
silently disable blocking on every device. It needs a manifest comment, an isolated
`InterstitialLauncher` file to hold the explanation, and a line in the code-review checklist.

The interstitial is a **translucent full-screen Activity subclassing `FlutterActivity`**, not
an overlay window. It owns the back button (an overlay lets Back fall through to the app
underneath), behaves correctly across OEM skins, and — usefully — means the Android block
screen is built from the same Flutter widgets as the rest of the app rather than a parallel
native UI.

Removing the AccessibilityService takes Play policy submissions from **four to one**, dropping
the riskiest, and removes the need for `QUERY_ALL_PACKAGES` (a `<queries>` element with a
MAIN/LAUNCHER filter enumerates launchable apps without a restricted-permission review).
Android effort drops from 5.5 to 4.0 engineer-weeks.

### Anti-cheat — proportionate

Threat model: **the user is cheating themselves.** The bar is "make cheating more effort than
the plank," not "unforgeable." Two checks, both free from data already in the frame:

- **Gravity coherence** — a phone propped on the floor has a stable signature; holding it up
  to point at a screen fails immediately.
- **Micro-motion liveness** — real planking has continuous involuntary motion (breathing at
  0.2–0.5 Hz, postural tremor). Near-zero variance over a 3s window **kills a still photo
  outright.**

Explicitly not doing face matching or device attestation — over-engineering, and face
matching would drag biometric data into the privacy story. A tripped check ends the session
as `invalidated`: no reward, **but no cooldown** — false positives must never punish.

The cheapest control of all is one line in settings: *"You can cheat this. It only works if
you don't."*

## UI/UX design

### Theme

**Solar Dusk** from the 21st.dev community gallery (@serafimcloud) — verified to exist. It was
picked because it is close to literally the corgi's coat: light background `#FDFBF7` is the
white chest, `secondary` `#E4C090` is the tan coat, `primary` `#B45309`/`#F97316` is the
red-sable saddle, dark background `#1C1917` is the black of a tricolour.

The decisive property, though, is that it already contains a **cool counterpoint** — dark
`accent` `#1E4252` and `chart-2` `#0EA5E9` — so the theme itself establishes blue as the
non-brand hue, which is what makes the signal system possible without inventing a palette.

One deliberate adaptation: in light mode the theme's `chart-2` and `chart-4` are duplicates
and `chart-3`/`chart-5` are two golds adjacent to the orange. An orange/gold/gold ramp is
unreadable for deuteranopes, so the dark-mode blue is promoted into the light chart ramp.
The primary categorical pair is always orange-vs-blue.

### The mascot-vs-warning collision, resolved

A corgi is `#B45309`–`#F97316`. The instinctive warning colour is amber. At five feet, in a
dim room, seen sideways by someone whose eyes are watering, those are the same colour — the
most safety-critical signal in the product would be indistinguishable from brand furniture.

The fix is two moves together:

**The warning is a luminance event, not a hue event.** The warm band is evacuated from the
signal system entirely. Good form is a dark teal field (~2% luminance); a form fault flips
the screen to **near-white** (~90%) with dark text — the theme's own foreground and
background swapping places. Grace is `destructive` red (~17%). Every adjacent transition is
a large luminance step, so nothing depends on telling two similar colours apart. It survives
full achromatopsia and direct sunlight.

**Orange is earned.** The corgi and all warm hues are banned from the framing and live
workout screens, and reappear at the instant of success. The constraint becomes the
emotional arc: the orange is what you were working for.

Four redundant channels per state — luminance, hue, motion rate (0/1/2 Hz), audio — so any
one alone suffices.

### The live workout screen

The camera is deliberately **not** the hero: 25% opacity, desaturated, under a state-colour
wash. At five feet a video preview is useless detail, but a dim silhouette still tells you
you're in frame.

The skeleton is **not** 33 landmarks — at that distance it's spaghetti. It is seven points
and one thick line: a spine polyline (shoulder→hip→ankle), a dashed reference line showing
the ideal, and a 28pt hip dot. **The gap between the hip dot and the dashed line is the
error, made literal.** No numbers, no gauges — the geometry is the instrument.

The **grace iris** is the best single invention in the spec: a 48pt border that shrinks
inward on a strictly linear curve over exactly 3000ms. It encodes remaining grace
*spatially*, so a user who can't read the number, can't hear audio, and can't distinguish
red from amber still perceives that the screen is closing on them. Linear, not eased,
because it represents literal time and easing would lie about it.

The counter sits on the half of the screen nearest the user's head, determined once at
position-check and **locked for the session** so it never moves mid-effort.

Nothing animates during a clean hold except the counter and the rail. Motion is the warning
channel; idle motion poisons it.

### Two clocks: the Wall and the Pass

The schedule is **the Wall**. An earned unlock is **the Pass** — a hole punched through it.
All copy uses this frame, so "blocked until 6pm" and "22 minutes left" stop being
contradictory. A persistent day timeline on Home renders both simultaneously.

Reconciliation is designed, not silent: if a pass would outlive the wall, the app says so
*before* the user works for it — *"Apps unlock on their own in 10 minutes anyway. Still want
to plank?"* Selling someone access they already have is how an app gets deleted.

### Accessibility without a bypass

The first draft had a hole: deny camera permission → unverified manual timer → unlock. That
made camera denial the optimal strategy for every user. Or pick "Breathing Hold" at
onboarding and earn identical rewards from mere presence in frame, forever.

The principle that fixes it: **the mechanism keeping an accommodation from becoming a bypass
is not proof and not gatekeeping — it is price.** We charge in time rather than asking
anyone to justify themselves. No documentation, no attestation, no shame.

- **Honor Mode deleted.** Camera denied is an honest dead end with two doors. Nobody gets
  trapped because the camera prompt comes at onboarding step 4, *before* Screen Time
  authorization at step 7 — a user who refuses the camera never reaches a state where
  anything is blocked.
- **Adapted exercises** (knee plank, incline plank, wall sit, seated arm hold, chair
  sit-to-stand) are configured once in Settings, not offered in the session-time picker.
  Each is camera-verified, effortful, and failable on the same terms, so each earns the
  identical reward with no second-class marking.
- **Recovery Mode** replaces Breathing Hold: time-limited to 14 days, entered through the
  same 5-minute friction gate, and it requires **verified stillness within a tight motion
  envelope** — not mere presence. Priced at **3×**: a 30s plank equals 90s of stillness.
  That rate is the whole mechanism. Nobody mid-craving picks a silent, motionless six-minute
  hold over a sixty-second plank, while someone with a broken wrist gets a dignified path
  that costs patience rather than pain.
- Switching among verified exercises is free; switching into or out of adapted/recovery
  modes carries the friction gate plus a 24-hour settle, so nobody shops for the cheapest path.

### Gamification's inversion problem

Stated bluntly in the spec, and worth repeating: gamification rewards doing more of a thing;
this product exists to make someone do *less* of a thing. If XP flows from completed planks,
and planks grant screen time, the optimal player unlocks Instagram more often than they
otherwise would. We'd have built an engine that manufactures the craving it was meant to
interrupt.

Four structural counterweights, all load-bearing:

1. **Daily XP cap at three sessions' worth.** Beyond that, sessions still grant unlock time
   but earn zero XP — removing the grind incentive at no cost to what the user came for.
2. **The Discipline track rewards refusal and is the most prestigious.** "Pressed Not Now
   ten times" is worth more than "completed ten planks."
3. **The headline stat is "time you didn't take"** — minutes earned minus minutes used. The
   scoreboard points at restraint, not throughput.
4. **We never celebrate an unlock.** Not an achievement, not a notification, not a chart.

### The mascot

**Biscuit**, a Pembroke Welsh Corgi. Never expresses disappointment in the user — on
cooldown it is *asleep*, not sad. Doesn't talk; the app's coach voice talks and Biscuit
barks. Absent from the framing and workout screens entirely.

The economics work through an **anchor-point rig**: one body per pose plus four named anchors
(collar, head, back, ground) that accessories snap to. 14 poses × 12 accessories = 168
combinations from 26 assets. Without the rig, level cosmetics are unshippable.

**Placeholder:** a deliberate geometric proto-Biscuit drawn in a Flutter `CustomPainter` —
on-palette, correctly proportioned so nothing reflows when real art lands, obviously not
final so nobody ships it by accident, and zero licensing risk. Screens reference a state
*enum* through a `MascotRegistry`, never a file path, so the illustrator's work drops in
without touching a screen.

### Session surfaces are dark-locked

Browsing screens follow the system light/dark setting — cream and tan under a tan dog is the
best the brand looks. But framing, countdown, workout, fail and cooldown are dark regardless:
the luminance ladder needs a dark baseline for the white warning flash to have headroom to
flash *into*, OLED power matters over a 90-second full-screen camera session, and a cream
screen at max brightness two feet from a straining face is hostile.

### Friction delay: 5 minutes for the wait, 15 as a floor elsewhere

This went back and forth twice and landed somewhere better than either starting position.

The 15-minute `DeviceActivitySchedule` floor is real, but it governs **different screens than
the wait**. It correctly constrains the minimum schedule window length, and the minimum
"turn blocking off for X" duration — because auto-re-enable has to fire while the app is
dead, so that genuinely needs DeviceActivity.

**The wait itself doesn't, because of the direction of the action.** To complete a disable the
user must open the app and press a button. Force-quitting doesn't turn blocking off — it
leaves blocking *on*. The only thing that must survive a force-quit is the request's *start*
timestamp, and losing that can only ever make the wait longer, never shorter. There is no
attack in the disable direction for DeviceActivity to defend against.

Clock manipulation is closed by a **dual-clock commit gate**: store both wall clock and
`systemUptime` at request time, and require *both* to have advanced ≥300s. A backward wall-clock
jump or a reboot resolves to whichever is more conservative.

The product argument is the decisive one. A user can revoke Screen Time authorization in
about four taps, and we cannot prevent it. So our friction is a **speed bump for the impulsive
user, not a vault against the determined one.** Fifteen minutes buys no extra protection from
someone determined — they'll use the four-tap route — while making the honest user, coming in
through the front door we designed, wait three times as long to turn off a feature they own.
That edges from friction toward hostage-taking.

**Five minutes for the wait. Fifteen as the floor on schedule windows and off-durations.
Hard Mode extends the wait to 30, opt-in.** Plus a 2-minute arming window so the user has to
return deliberately rather than catching it passively.

### iOS default blocklist: the workaround

Since we cannot preselect apps on iOS, this got promoted from a card to a full three-beat
onboarding step:

1. **Choose your six** on *our* screen — a checklist with the six app names as plain text,
   pre-ticked, editable. Output is a shopping list the user holds in their head.
2. **The system picker** opens, with the list shown one last time in a sticky banner.
3. **Verify** — we show their list beside a small **native SwiftUI island** rendering
   `Label(token)` for each selection. That renders the real app icon and name *by the system*
   without our code ever reading either, so the user can compare with their own eyes. This
   closes the loop Apple's privacy model opens.

Plus a durable fix for never being able to name apps back to the user: they **name the
selection themselves** ("The bad four"), and that user-authored string is what the app
displays everywhere afterwards.

### Android permission copy, corrected

The Android onboarding now asks for **usage access** ("so Plank Up can tell which app is in
front — that's the only thing it's used for") and **display-over-other-apps** ("so Plank Up
can show the block screen").

That second string matters more than it looks. We don't ask for the overlay permission in
order to draw an overlay — we ask because it is the only background-activity-launch exemption
available to us, and without it the monitoring service cannot launch the block screen at all.
The design spec explicitly instructs against writing copy about "drawing over other apps,"
on the grounds that it is both scarier and less true.

## Implementation blueprint

Accepted. Package and version claims were independently spot-checked (drift 2.35.0,
purchases_flutter 10.12.0, Flutter 3.47 stable all confirmed against pub.dev and
flutter.dev).

### Toolchain

Flutter 3.47.2 / Dart 3.13. **iOS floor 16.0** — not a Flutter constraint but a Screen
Time one: `AuthorizationCenter.requestAuthorization(for: .individual)`, the self-control
authorization path, is iOS 16+. On iOS 15 the only path is `.child`, which requires a
parent's Apple ID and is the wrong product. Android minSdk 26, target/compile SDK 36
(Play requires 36 for new apps as of 2026-08-31). JDK 17, AGP 9.1, Kotlin 2.4, Xcode 27.

**This machine currently has no Flutter, no Xcode (Command Line Tools only), and no JDK.**
Setup is a real task, not a given.

**Neither core feature works in a simulator.** Screen Time simply does not exist there, and
emulator webcam passthrough gives a head-and-shoulders desk view — the opposite of a
floor-level side-on body view. Physical devices are required from day one, including one
mid-tier iPhone (the pose spike must run on the *slowest* supported device, not the newest)
and one Samsung specifically, since aggressive background-process killing is the single
biggest Android enforcement risk.

### Dependencies

Riverpod (state), drift (persistence), permission_handler, haptic_feedback, audioplayers,
fl_chart, flutter_local_notifications, purchases_flutter (RevenueCat).

Two notable rejections, both for the same reason — they force camera frames across the
Flutter bridge:
- **`camera`** — streams raw buffers into Dart. A 640×480 YUV420 frame is ~460 KB; at 30fps
  that is ~13.8 MB/s across the bridge, then back to native for inference.
- **`google_mlkit_pose_detection`** — healthy and maintained, but its API builds an
  `InputImage` *in Dart*. Right package, wrong shape for a 30fps realtime loop.

All eight community Screen Time packages were surveyed and **all rejected**. None ship the
extensions, which are the actual work; combined adoption across all eight is under 1,000
downloads. We write our own native module and read the MIT-licensed ones as reference.

### Architecture of the bridge

Native owns camera capture, inference, landmark normalization and smoothing. Dart owns
exercise evaluation. Native emits ~15 Hz of landmark data as a flat `Float64List`
(~20 KB/s — three orders of magnitude below raw frames). Preview reaches Flutter as a
`Texture`, not a PlatformView.

Evaluation lives in Dart so there is one implementation rather than two that slowly diverge,
and so it is fixture-testable. The channel contract carries an `evaluatorLocation` field so
evaluation can move to native later without changing a single event shape.

**Pose backend: MediaPipe Pose Landmarker on both platforms.** Chosen over Apple Vision for
landmark-schema parity (one set of thresholds, not two), per-landmark visibility/presence
(load-bearing — the far arm and far leg are occluded in a side-on plank), and 3D world
coordinates (a phone on the floor shooting upward produces severe perspective distortion).
ML Kit was rejected: its Android artifact has been frozen at beta since August 2024.

### Testing

The correctness core is pure Dart with zero Flutter or plugin imports, enforced in CI, with
an injected `Clock` and no `DateTime.now()` anywhere in `domain/`. Unlock economy, cooldown
policy, session machine, schedule resolver, XP/achievement rules and feature gating all
target 100% coverage and run in milliseconds without a device.

**Form evaluation is tested from recorded landmark sequences, not video.** A debug-mode
fixture recorder dumps the `PoseFrame` event stream to JSON Lines exactly as it crossed the
bridge; record real humans once, replay forever at fake-clock speed. The corpus covers the
cases that matter: gradual hip sag (should fail), a brief dip under 3s (must *not* fail),
partial-depth reps, and ambiguous shuffling that must count **zero** reps — false positives
are the failure mode that destroys trust in the product.

Minimum corpus before thresholds are locked: ≥5 subjects × ≥3 body types × ≥2 devices per
exercise, recorded from a fixed marked mat position. Fewer than that overfits to whoever was
in the room.

Blocking behavior cannot be automated. A written manual script runs before every release.
The single most important step: **force-quit the app entirely, let the unlock window expire,
reopen TikTok — the shield must reappear.** That proves `DeviceActivityMonitor` works
independent of the host app.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Family Controls entitlement delay** | Gates TestFlight and the App Store entirely | **Researched and the news is good on eligibility**: "apps where the core value is the user restricting their own usage" is an explicitly qualifying category, and Opal, Freedom, one sec, Jomo, ScreenZen and Brick all ship on it. The risk is *schedule*, not rejection — there is no SLA and no status visibility, and Feb/Mar 2026 requests were reported still unanswered months later. **Submit all bundle IDs on day one.** Develop against the *development* entitlement, which needs no approval, so engineering is never blocked by the wait |
| **BlazePose requires a visible head** | Could break detection for the core exercise | Verified model constraint — BlazePose uses a face detector as its person-detection proxy. A tucked chin viewed from floor level can drop detection entirely. Framing gate must hard-require face landmarks; coaching copy steers head position ("eyes on the floor a foot ahead"). **Dropout rate must be measured in the calibration shoot, not guessed** |
| **False rejections of good form** | Trust-destroying — a wrong 10-min cooldown | Tune asymmetrically: false-accept <5% but **false-reject <2%**, because the costs are wildly unequal. A new user's first failure of any exercise grants a 2-minute grace unlock and no cooldown, with an apology. Per-user baseline calibration, plus a user-facing strictness setting as the pressure-release valve |
| **MediaPipe on iOS is a supply-chain liability** | Permanent dependency on an abandoned build | Two open, vendor-neglected issues on our most critical code path: versions 0.10.33+ are broken for CocoaPods consumers (forcing a pin to **0.10.21, a 2024 build**), and the `PoseLandmarker` binary has shipped an undeclared required-reason API violation for **~2.5 years**, producing ITMS-91053 on upload. The second is fixable by declaring the reasons in our own privacy manifest. **Decision pending** — see below |
| **Android 17 / API 37 task hijacking** | Forward-compat, ~1 year out | Launching a full-screen interstitial over another app's task is exactly the pattern the new rules police; it requires opt-in via `android:allowCrossUidActivitySwitchFromBelow`. We target API 36 so we aren't subject yet, but Play's target-API treadmill makes this mandatory within about a year. Test on an Android 17 device during the Android milestone, not during a forced SDK bump with the app live |
| **Shield cannot launch the host app** | Breaks the core loop's primary flow | Verified independently by two agents. Workaround: shield action writes an App Group flag, fires a local notification, responds `.defer`; user taps notification. Two taps, not one. Needs a spike to confirm on iOS 27 |
| **iOS caps DeviceActivity at 20 concurrent activities** | Hard ceiling on schedule count | Schedules and unlock windows both consume slots. Must collapse schedules into a few activities with computed boundaries, not one per schedule |
| **Pose accuracy in a real living room** | The product's whole premise | Spike on the slowest supported device before committing. Fixture corpus is the regression suite |
| **Android enforcement on Samsung** | Silent failure — worse than no blocker | Battery optimization kills services. Must survive or degrade loudly via an `enforcementDegraded` event |
| **Play review of AccessibilityService apps** | Weeks of latency, likely rejection round | Stricter review since 2026-01-28. `isAccessibilityTool="false"` is mandatory (we are a self-control tool, not an accessibility aid) plus in-app prominent disclosure. Budget two weeks, not two days |
| **RevenueCat contradicts "fully local"** | Trust and store-disclosure problem | See open question below |
| **Gamification can invert the product** | XP rewards grinding workouts in an app designed to make you do *less* of something | Daily XP cap, honesty message when a block window is about to end anyway, award XP for *giving time back* |

### Settled: Apple Vision on iOS, MediaPipe on Android

The architecture agent had called 3D world landmarks "the deciding technical factor." Asked
to justify it, it worked the geometry properly and **withdrew the claim**.

The result: rotating the camera by obliquity angle φ projects body length to `L·cos φ`, but
the hip's sag/pike offset is perpendicular to the rotation axis and projects **unchanged**.
So `δ_measured = δ_true / cos φ` — obliquity inflates the measurement by a pure scalar and
does not shear it. And `cos φ` is directly recoverable from 2D via the ratio of apparent
shoulder separation to apparent body length. Correction error is second-order and lands well
below the model's own landmark noise.

The sharper argument: **in a true side-on plank, shoulder, hip and ankle are coplanar at
essentially constant depth, so perspective acts as a near-pure scale rather than a shear.
Meanwhile BlazePose's z for the occluded far limb is inferred from a learned prior, not
measured. Trusting learned depth in exactly the configuration where half the body is hidden
is trusting a hallucination.** The 3D advantage was weakest precisely where it was claimed to
matter most.

What genuinely degrades: obliquity tolerance narrows from ±45° to ±35°, which the framing
gate now rejects *quantitatively* rather than heuristically. Joint angles (unlike ratios) do
get distorted by anisotropic scaling, fixed by rescaling the body-axis component by `1/cos φ`
before measuring.

Two Vision bonuses worth banking: it returns **multiple** body observations where BlazePose
is single-person-only, giving free "only one person in frame" anti-cheat; and it does **not**
share BlazePose's architectural requirement that the head be visible — which materially
de-risks the tucked-chin failure mode on the lead platform.

### The fixture-corpus insight that removes the lock-in

I had flagged that re-recording fixtures against a different landmark schema would mean
re-shooting with real humans. The architecture agent's answer dissolves the problem:

**Record video once; derive landmarks twice.** Capture raw clips, attach ground-truth labels
to the **clip timeline** rather than to landmarks, then batch-run each backend offline over
the same clips to produce two landmark fixture sets sharing one label set. Cost is one
processing pass, never a re-shoot — and it directly measures backend agreement, which is the
number you actually want before committing.

Raw clips live in a private, consent-signed, offline archive; the repo holds only landmark
JSON and labels. Generalized: **make the schema a derived artifact rather than the recorded
artifact, and no backend decision is ever expensive again.**

### Timing: the requirement that actually matters

The architecture agent rejected the proposed 80 ms p95 latency target as both unreachable on
mid-range Android and beside the point, setting p50 ≤60 ms / p95 ≤120 ms instead. Its
reasoning is that human reaction to a cue is 200–300 ms, so a 120 ms pipeline is already
below the noise floor of the user's own reaction, and even 200 ms p99 costs 4% of a 3-second
grace window.

The real requirement replaces it:

> **Every accumulation, grace and rep-timing computation uses the native monotonic capture
> timestamp carried in the frame. Dart never calls `DateTime.now()` inside the session loop.**

That makes pipeline latency and Dart jank **mathematically irrelevant to scoring**, which is
what makes a Dart-side evaluator safe in the first place.

In place of a latency SLA there is a **staleness guard**: a frame gap over 400 ms enters
`STALLED`, and 8 seconds cumulative aborts the attempt with **no cooldown**. A dropped
pipeline is our fault; charging the user ten minutes for it is the fastest way to lose them.

### STALLED is not WARNING

A deliberate and important split: **`WARNING` is the user's fault and runs the grace timer;
`STALLED` is our fault and does not.** Collapsing them would make every dropped frame a step
toward a penalty.

The corollary rule, applied throughout: **when uncertain, never fail the user.** Every
ambiguous signal routes to `STALLED`/`ABORTED_INVALID`, not `FAILED`.

But two cases deliberately *do* carry the cooldown, because they are the obvious cheats:
**locking the screen** (a deliberate button press to freeze the timer) and **force-quitting
mid-attempt** (otherwise force-quit is a free retry). Being phoned, being backgrounded by a
system dialog, and having the phone knocked over all carry no penalty.

### Shield handoff: `.close`, not `.defer`

The architecture agent disagreed with both other agents here, and I think it is right.
`UNUserNotificationCenter` called from within a shield-action extension has documented
service-invalidation failures, so it cannot be load-bearing — and `.defer` leaves the user
sitting *inside the distracting app* staring at a shield, which is the opposite of the goal.

Instead: write the pending intent to the App Group **first and synchronously**, fire the
notification **best-effort** with errors ignored, then return `.close`. The blocked app
closes and drops the user on the Home Screen. If the notification landed they tap it; if not
they tap the app icon, and the app reads the same flag on launch and routes to the same
screen. **Both paths converge on the App Group flag, so the notification is a pure
accelerator that can fail harmlessly.**

## Privacy posture

Camera frames never leave the native process. Four properties make that verifiable rather
than merely asserted: the capture module links no networking library; only a `Float64List` of
joints plus gravity and timestamps crosses the channel; nothing in the capture path opens a
file handle; and the app makes zero outbound requests apart from OS-mediated StoreKit/Play
Billing IPC.

Which raises an idea worth chasing: **ship the Android build without
`android.permission.INTERNET`.** An Android app lacking that permission is *structurally
incapable* of exfiltrating anything — the strongest privacy claim available on mobile, and
verifiable by anyone who opens the manifest. Play Billing binds to the Play Store via IPC and
supplies its own permission, so this looks achievable. Unverified, and worth validating early:
if it holds it's worth building marketing around, and if it doesn't we need to know before
promising it.

No third-party SDKs in v1 — no Firebase, no Crashlytics, no Sentry. Real cost (no crash
reporting beyond Xcode Organizer and Play Vitals) in exchange for an airtight "Data Not
Collected" label and a trivial review.

**One build-configuration consequence worth catching early:** do not link Screen Time symbols
before the entitlement is approved. There are documented 2.5.1 rejections for the mere
*presence* of unapproved API. Gate it behind a compile-time flag.

## Open questions for the user

1. **On iOS we cannot ship your default blocklist.** You asked for TikTok, Instagram and
   YouTube to be blocked by default. `ApplicationToken` is opaque and device-local, and there
   is **no API to construct one from an app identity** — we cannot name an app to the system,
   so we cannot preselect it. Android can ship real defaults by package name; iOS cannot.
   The honest design is a guided onboarding step that names the six apps as text while the
   system picker is open, so the user taps them in themselves. This is a platform wall, not a
   design choice, but you should know the requirement can't be met as stated on iOS.

2. **RevenueCat breaks the "no backend" decision.** Subscriptions need server-side receipt
   validation, and `in_app_purchase` explicitly leaves you to do that yourself. RevenueCat
   supplies it without us running a server, but purchase tokens and an anonymous ID leave the
   device — the only cloud dependency in an app otherwise promised as fully local. No health
   data, no session history, no blocklist.

   Worth noting the architecture agent reached a *different* conclusion: StoreKit 2's
   `Transaction.currentEntitlements` is pre-verified and serves from local cache offline, so
   **iOS genuinely needs no server**. Android is the weaker half. Since we ship iOS first,
   the honest option is to defer this decision entirely — build v1 on StoreKit 2 with no
   third party, and revisit when Android lands.

3. **Scope is ~28.5 engineer-weeks** — seven-plus months for one engineer. All three agents
   independently recommended a narrower v1 without being asked to agree with each other.
   They differ on where to cut; see phasing below.

4. **Still unanswered: validate first, or build now?** The research recommends making the demo
   video before writing code, on the grounds that the incumbent did exactly that and it costs
   an afternoon. This is the one decision that determines the shape of everything else.

5. **iOS floor: 16.0 or 17.0?** The agents disagree. 16.0 is the technical minimum (the
   self-control authorization path doesn't exist below it). But iOS 16.0–16.3 had documented
   Screen Time flakiness, and with no crash reporting by design, those are field reports we
   cannot debug. Raising to 17.0 costs install base and eliminates a class of unfixable bugs.

6. **Would you ship Android first if the entitlement stalls?** Worth agreeing *now* rather
   than under pressure. Apple's review has no SLA and no status visibility. If week 6 arrives
   with no answer, inverting the platform order is a legitimate hedge — but only if it was
   decided in advance. (The research argues Android is the weaker half regardless: iOS earns
   ~5× per user, and the Android block is genuinely easier to defeat.)

### Resolved since these were written

- **Bonus-attempt forfeiture** — moot. There is no cooldown to trigger.
- **Rep→unlock coefficients** — deferred. Squats and pushups are no longer v1.
- **RevenueCat vs StoreKit 2** — resolved by shipping iOS first. StoreKit 2's
  `Transaction.currentEntitlements` is pre-verified and serves from local cache offline, so
  iOS genuinely needs no server. Revisit only when Android lands.
- **The 60-minute reliability cliff** — likely moot. With the economy tightened toward the
  category norm, the top tier lands near 30 minutes, comfortably inside the ~45-minute
  `DeviceActivity` window where scheduling is reliable. Worth confirming once the final
  numbers are set.

## Revised v1 — after the market research and the decisions above

### Cutting the cooldown removes a surprising amount of the system

This is the biggest simplification available, and it is worth stating explicitly because
roughly a third of the architecture existed to defend a penalty we no longer have:

- **The dual-clock machinery largely goes away.** Wall-clock plus monotonic pairs, boot-anchor
  detection, clock-anomaly penalties and the checkpoint jump-neutralisation existed mostly to
  stop someone skipping a cooldown. Unlock windows still need expiry handling, but the
  adversarial half of the clock design is gone.
- **A whole state disappears** from the session machine, along with its persistence, its shield
  variant, its Home state, its screen, and its QA scripts.
- **The anti-cheat argument gets easier.** The tester already recommended log-only anti-cheat on
  the grounds that a false reject costs everything and a false accept costs nothing. With no
  penalty, that asymmetry becomes absolute.
- **The riskiest QA gate softens.** "False-reject rate under 0.5%" was set by the cost of a
  wrongly-issued 10-minute punishment. Without it, a mis-detection costs a retry.

What replaces it: form break pauses the timer with a cue. Giving up early earns proportional
credit. Losing the skeleton says *"I can't see you — adjust your phone"* and never fails
anything. **Separating low pose confidence from bad form is now the single highest-value
engineering decision in the product.**

### Accessibility as the wedge changes what ships in v1

This is not a cosmetic repositioning. If accessibility is the differentiation, the adapted
exercises move **out of v1.3 and into v1** — they *are* the product's story, not a later
accommodation.

That means v1 ships: plank, knee plank, incline plank, wall sit, seated arm hold, and chair
sit-to-stand. Each camera-verified with real failure conditions, each earning identical
rewards with no second-class marking. Plus the audio-led session design, which turns out to be
an accessibility feature as much as an ergonomic one — the whole session is usable without
looking at the screen.

The upside is that this is genuinely unclaimed. Forty competitors, none of them serving anyone
who can't do a standard floor exercise. It is also the "Accessibility" line item in Apple's
published featuring criteria, and the category has no featured app that I could find.

The cost is honest: five verified exercise evaluators instead of one, each needing its own
thresholds and its own fixture coverage. That is real work, and it is the work that makes the
product defensible.

### Recommended sequence

1. **This week, before any code.** Make the demo video — plank, phone on the floor, timer,
   Instagram unlocking. Post it. If the hook doesn't pull, an afternoon has saved seven months.
2. **Same week, in parallel.** Submit the Family Controls entitlement for the app **and every
   extension**. It is granted per-target, 4–6+ weeks, currently backlogged, with no SLA — and
   an approved parent app with unapproved extensions fails *silently*.
3. **Week one, as a throwaway spike.** Prototype plank detection at the real geometry: floor
   level, side-on, close range, on carpet, in bad light, wearing a hoodie. Every tier, every
   threshold and the confidence-versus-form split depend on it. The incumbent's plank feature
   reportedly doesn't work; assume this is hard until proven otherwise.
4. **Then build**, if 1 and 3 hold up.

## Superseded: the agents' phasing debate

All three independently converged on **iOS first, plank first, defer the paid exercises** —
without being asked to agree with each other. None thought the stated scope was shippable as
one release. They differed only on details (one schedule vs none, pushups in or out,
subscription day-one or later).

The market research then went further than any of them, and its argument supersedes the
debate: the category's winner shipped three screens in two weeks, so the question isn't which
features to cut from a 28-week plan — it's whether to build a 28-week plan at all before
testing the hook.

**One constraint survives regardless of phasing:** build the `ExerciseEvaluator` interface and
keep the session machine goal-agnostic even while only holds ship. Five adapted exercises now
land in v1 anyway, so the abstraction is load-bearing from day one rather than speculative.

## Verification

The QA pass found five things that invalidate assumptions the other three agents shared.

### 1. Xcode-attached test results are void, not merely unreliable

`AuthorizationCenter.$authorizationStatus` emits when a debugger is attached and is **silent
otherwise**. There are reports of blocking that "worked perfectly in the simulator and failed
completely on a real device when Xcode was not attached."

So every iOS enforcement result obtained from a debugger-attached build is void — and
misleading in the *optimistic* direction. Hard rule: all enforcement, permission and lifecycle
testing runs on TestFlight or release-config builds with no debugger, recording the exact OS
build number. This invalidates the default way most teams would run the device-integration
tier.

### 2. Demographic bias lands in the detector, and landmark fixtures cannot see it

This is the most important finding. BlazePose uses a **face detector as its person-detector
proxy**, and there is a documented skin-tone recall gap in the BlazeFace family for
dark-skinned subjects. A plank is a horizontal body, head down or in profile, five feet away,
often with hair across the face.

So the demographic failure mode is not "the hip angle is 4° off for dark-skinned users." It is
**"no person detected."** And a fixture corpus made of recorded *landmark streams* — which
both other agents converged on — **cannot observe that class of failure at all, because those
fixtures begin at the moment landmarks already exist.** The proposed tier measures only the
half of the pipeline least likely to be biased.

Second problem with landmark-only fixtures: the model ships with the OS and changes
underneath you, so they **cannot be pinned**.

The fix is three fixture tiers rather than one: landmark streams in-repo for per-PR evaluator
tests; **raw video, access-controlled and never bundled**, run nightly and against every OS
beta — the only tier that can see acquisition failure; and synthetic parametric streams for
exhaustive threshold sweeps.

### 3. The 60-minute reward sits past the reliability cliff

`DeviceActivity` schedules are unreliable beyond roughly 45 minutes, and the monitor extension
runs in a ~6 MB process that dies silently with no console output. The 60-minute unlock is
therefore the single riskiest feature in the product.

The test is specified as a measured gate rather than a hope: 10 consecutive trials per
duration, phone in a pocket and left alone (which is what actually memory-pressures the
extension). **10/10 required for 15 and 30 minutes; ≥9/10 for 60.** If 60 misses, it ships cut
or capped at 45 — not shipped with a known silent-failure rate.

### 4. Two silent total-failure modes nobody had caught

- **The 50-token limit.** Exceeding roughly 50 shielded items causes the shield to block
  **nothing**, silently. Needs a boundary test at 49/50/51 and a user-visible error at the
  limit.
- **Web domains.** Opening `instagram.com` in Safari bypasses app-level blocking entirely —
  which defeats five of the six default targets.

### 5. `denyAppRemoval` can require a factory reset

There is a documented bug where it gets stuck enabled even after the controlling app is
uninstalled and authorization is removed, **with device reset as the only remedy**.
Recommendation: don't ship it in v1. A support queue full of people whose phones need factory
resets because our app wouldn't let go is company-ending; a user who uninstalls to reach
TikTok is a user exercising agency.

### The gate we can actually promise

Neither platform offers a read-back API confirming enforcement is real. We can write tokens
and read our own write back; that proves nothing about whether the OS is honoring it. **The
app is structurally incapable of verifying its own core function.**

So the release gate is not "the app always blocks" — we cannot promise that. It is **"the app
never claims protection it doesn't have."** That requires an append-only local
**Enforcement Audit Log** with *silence alarms* (assertions that fire on the absence of an
expected event — "a schedule is active but no extension callback in 50 minutes") and a
user-facing Protection Status screen that goes red with a specific, actionable reason.

A user told "Screen Time access is off, tap to fix" is retained. A user who discovers on their
own that the app has been lying for three weeks is gone.

### Other adopted recommendations

- **Anti-cheat ships log-only, behind a flag.** The user is both adversary and customer;
  cheating is self-harm, not fraud. A false accept costs nothing; a false reject costs a
  10-minute cooldown and probably the install. Roughly 5% of effort, no enforcement in v1.
- **The one exception is partial framing** — propping the phone to hide sagging hips. That gets
  handled as a *form-evaluation* requirement rather than anti-cheat: if the camera can't see
  ankles and shoulders simultaneously, refuse to start. The same code serves the far more
  common honest-framing mistake.
- **The bailout is a safety gate, not a UX nicety.** Someone injured or disabled, whose phone
  is locked by an app demanding a plank they physically cannot do, is a foreseeable bad
  outcome. Tested from every state including mid-cooldown, with camera denied.
- **100% line coverage is a weak gate for a state machine** — it proves branches were reached
  and says nothing about event interleaving, which is the entire risk surface. Replaced with
  property-based model checking over randomized event sequences plus a **mutation score ≥85%**.
- **Test infrastructure is itself an attack surface.** A debug clock shipped in the release
  binary is a one-tap infinite unlock and the cheapest bypass in the product. Automated check
  on the release artifact.
- **Accuracy bar is stated per-attempt and per-cell, never pooled.** A pooled average is
  precisely the statistic that hides the failure we're hunting. False-reject ≤0.5% pooled,
  ≤2% any subject or cell, and **&gt;5% in any cell is a hard blocker.**

### Spec gap that blocks test-writing

The grace period's interaction with brief recovery is undefined, so the boundary fixtures
can't be written. Three options: per-break resetting fully (exploitable by rhythmic cheating),
cumulative per attempt (harsh on the slow-drift case that's most common in real use), or
**per-break with a cumulative cap — recommended at 3 breaks or 9 seconds, whichever comes
first.** Any is testable; "unspecified" is not.
