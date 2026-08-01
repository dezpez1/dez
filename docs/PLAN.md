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

- **Web app (PWA), not native.** One codebase, runs on both phones instantly via URL, fullscreen-capable, and sidesteps app-store policy friction entirely for this subject matter
- **Stack:** Vite + React + WebGL shaders for the field (Three.js or regl — shader-quality visuals are the whole "looks cool" requirement; Canvas2D won't cut it)
- **Sync:** tiny Node WebSocket server relaying touch/stroke/state events (~100 lines; deploy on Fly/Railway). Sync events, not pixels — both clients deterministically render the same field from the same event stream (also gives replay for free: the Morning View replays the event log)
- **Audio:** MediaRecorder API; store locally during session, upload after
- **Transcription + summary:** async next-day job — Whisper (or equivalent) for transcripts, Claude API for the integration summary. *Implementation note: consult the `claude-api` skill before writing any API code (per its trigger rules)*
- **Repo:** app code lives in `dezpez1/dez`

## Privacy & safety (non-negotiable)

- `dez` is **public** — code can live there, but session data can never: recordings, transcripts, and summaries are voice memos of tripping people. `.gitignore` all data dirs from day one
- Sync server requires a session secret; no open relay. Recordings stay client-side until the user explicitly saves; server stores nothing long-term in MVP
- API keys in `.env`, never committed
- Grounding mode ships in the first usable build, not last — it's the safety spine
- No anxiety mechanics anywhere: no timers, no progress bars, no notifications during a session

## Build order (MVP)

1. **The Field, solo:** Vite + React + shader canvas; breathing ambient visual with palette seeds; touch → persistent blooms. (This alone is demoable and "looks cool on mushrooms")
2. **Ground Me:** gesture + slow/dim/breath state in the shader
3. **Two-player sync:** WS server + session codes; event-stream architecture with deterministic rendering
4. **Capture:** hold-to-talk, local audio storage, timestamps on the event stream
5. **Before screen:** intention + palette seeding
6. **Morning View:** event-log replay, async transcription, Claude integration summary, gallery save
7. Polish pass against the trip-UX rules (target sizes, motion tuning, no-text audit)

Steps 1–2 are the first weekend demo. Steps 1–6 are the MVP.

## Verification

- Dev server via `.claude/launch.json` + browser preview; two browser tabs joined to one session to prove sync (bloom in tab A appears in tab B)
- Phone testing over LAN (both their phones on the same session — the real acceptance test)
- Replay test: after a fake session, Morning View replays the identical field evolution from the event log
- Grounding test: gesture reachable and functional from every state of the session screen
- Fake-audio pipeline test: record → transcript → summary end-to-end with mundane test audio before any real use
