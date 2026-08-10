# The Session Surface — a two-player trip companion (working name: **Mycelium**)

## Context

Jacob + friend (GitHub: dezpez1), both 19, technical, AI-fluent, building something fun together in `dezpez1/dez` (public repo, currently only vendored Claude Code skills — app is greenfield). They take mushrooms together and want an app that harnesses the altered state during their shared sessions.

**Standing constraint:** no ordering/procurement/marketplace functionality of any kind — that part of the original idea is out and stays out. This is an experience app around their own use, with harm-reduction defaults baked in.

**Their answers:** core modes = ambient visuals + transforming canvas + realization recorder (explicitly *not* a voice AI guide); phase = the whole arc (before/during/after); shared model = two-player synced; payoff = all four (creativity, insight, amplification, grounding).

**The synthesis (the spine):** those aren't three features — they're one surface. A shared generative visual field both phones are inside of. Touching it blooms/ripples it and the strokes persist, woven into the field. A hold-to-talk button captures spoken thoughts with timestamps. The intention set beforehand seeds the field (palette, motion, motif). The next morning, the app replays the field's evolution + transcribes the voice notes into an integration view. **Every session produces a permanent artifact; sessions accumulate into a gallery.**

Working-name options to offer them: **Mycelium** (two nodes, one living network — almost too on-the-nose), Spore, Loom, Inner Space.

## Product shape

### Before (5 min, sober, normal UX)
- Create a session → big-type room code / QR; friend joins
- Each sets a one-line intention (or one shared question); pick a palette/mood seed
- Intention seeds the field's colors, motion character, and a motif

### During (the trip — trip UX rules apply)
- **The Field:** fullscreen generative shader visual, slow breathing default. Both phones render the same shared field; touch events sync so a bloom on one phone appears on both. Strokes persist and slowly integrate into the pattern
- **Capture:** one giant hold-to-talk button. Records audio + timestamp. No playback during the session (no rabbit holes) — capture only
- **Ground Me:** two-finger press-and-hold anywhere → field dims and slows to breath pacing (~5.5s cycle), optional haptic pulse. Always reachable, zero navigation. Releasing eases back gently
- Trip UX ground rules everywhere: no text beyond single words, huge targets, no timers/clocks, no sudden visual changes, calm defaults

### After (next morning, normal UX)
- **The Morning View:** time-lapse replay of the field's evolution; voice notes on a timeline with async transcripts; a gentle AI-written summary that connects what was said back to the intention and surfaces the realizations worth keeping
- Save the session to the gallery: final field render + notes + summary = the artifact

## Tech

**Native iOS, deployed from Xcode.** (Superseded the original PWA plan — they're
shipping to their own devices via Xcode, so App Store policy is irrelevant, and
native buys three things the web couldn't: Metal instead of WebGL, real
CoreHaptics for the grounding pulse, and peer-to-peer sync with no server.)

- **Stack:** Swift + SwiftUI + Metal. Deployment target iOS 17, `TARGETED_DEVICE_FAMILY = 1,2`
- **The Field:** two-pass Metal renderer with a ping-pong accumulation buffer.
  Pass 1 computes domain-warped fbm + touch blooms and blends with the previous
  frame; pass 2 tonemaps to the drawable. The feedback buffer is what makes
  strokes persist and get woven into the pattern
- **Sync:** `MultipeerConnectivity` — peer-to-peer over WiFi/Bluetooth, **no
  server to deploy and no session data leaving the two devices**. Sync events,
  not pixels: the field is a pure function of `(time, seed, bloom log)`, so
  replaying the log reproduces a session exactly. Replay comes free
- **Audio:** `AVAudioRecorder`, written to the app container
- **Transcription:** Apple's on-device `Speech` framework — keeps voice memos
  of tripping people off the network entirely
- **Summary:** Claude API, the one thing that leaves the device, and only on
  explicit opt-in. *Implementation note: consult the `claude-api` skill before
  writing any API code (per its trigger rules)*
- **Repo:** app code lives in `dezpez1/dez` under `ios/Mycelium`

## Privacy & safety (non-negotiable)

- `dez` is **public** — code can live there, but session data can never: recordings, transcripts, and summaries are voice memos of tripping people. `.gitignore` all data dirs from day one
- Sync server requires a session secret; no open relay. Recordings stay client-side until the user explicitly saves; server stores nothing long-term in MVP
- API keys in `.env`, never committed
- Grounding mode ships in the first usable build, not last — it's the safety spine
- No anxiety mechanics anywhere: no timers, no progress bars, no notifications during a session

## Build order (MVP)

1. ~~**The Field, solo:**~~ **DONE** — Metal shader canvas, breathing ambient visual with palette seeds, touch → persistent blooms
2. ~~**Ground Me:**~~ **DONE** — two-finger hold → dim/desaturate/slow + haptic breath pulse
3. ~~**Two-player sync:**~~ **CUT** (Jacob, 2026-08-05: "I don't care about the two phone sync personally"). The event-log architecture it justified stays — replay is built on it
4. ~~**Capture:**~~ **DONE** 2026-08-09 — hold-the-circle voice notes, per-session event log + recordings in the app container. Shipped alongside **audio reactivity** (not in the original plan): mic → band envelopes → the field moves with the music. See `ios/README.md` → Audio
5. **Before screen:** intention + palette seeding
6. **Morning View:** event-log replay, async transcription, Claude integration summary, gallery save
7. Polish pass against the trip-UX rules (target sizes, motion tuning, no-text audit)

Steps 1–2 were the first weekend demo. Steps 1–6 minus 3 are the MVP.

## Verification

- Dev server via `.claude/launch.json` + browser preview; two browser tabs joined to one session to prove sync (bloom in tab A appears in tab B)
- Phone testing over LAN (both their phones on the same session — the real acceptance test)
- Replay test: after a fake session, Morning View replays the identical field evolution from the event log
- Grounding test: gesture reachable and functional from every state of the session screen
- Fake-audio pipeline test: record → transcript → summary end-to-end with mundane test audio before any real use
