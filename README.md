# dez

A shared starting point for a project we haven't defined yet.

Right now this repo holds **Claude Code skills** — reusable instruction sets that
Claude picks up automatically when the work matches. They live in
`.claude/skills/`, so any Claude Code session started from this directory can use
them with no setup.

## Getting them

```bash
git clone https://github.com/dezpez1/dez.git
cd dez
claude
```

That's it. Skills in `.claude/skills/` are discovered automatically.

## What's here

Five skills, chosen for the stage we're actually at — two people, no decided
project, trying to figure out what to build.

| Skill | What it does |
|---|---|
| `ask-questions-if-underspecified` | Forces clarifying questions before implementing. Asks 1–5 scannable multiple-choice questions instead of guessing at vague scope. |
| `let-fate-decide` | Draws a 12-house tarot spread to break ties when a prompt is vague or delegated. Deliberate entropy injection — the playful counterpart to the skill above. |
| `open-sourcing` | Release-readiness workflow: secrets audit first, then licensing, docs, CI, packaging. This repo is public and has none of that yet. |
| `git-cleanup` | Categorizes local branches and worktrees as merged / superseded / active before deleting anything. Gated on explicit confirmation at two points. |
| `property-based-testing` | Finds code where property tests beat example tests — encode/decode pairs, parsers, validators, normalizers — and writes them. |

The first two are a matched pair and worth knowing about together.
`ask-questions-if-underspecified` triggers when the tone is precision-seeking;
`let-fate-decide` triggers when it's casual ("whatever", "idk", "you pick"). Both
exist because an undefined request is the failure mode where agents waste the most
work.

## Executable content

Three of these ship shell/Python scripts, which run on your machine. Every one was
read before it went in:

- `let-fate-decide/scripts/draw_cards.py` — pure stdlib, uses `secrets` for
  randomness. No network, no subprocess, no dependencies.
- `open-sourcing/scripts/check_readiness.sh` — read-only. Checks for README,
  LICENSE, CI, tests, and greps tracked files for accidentally-committed keys.
- `open-sourcing/scripts/detect_org.sh` — reads local git remotes and committer
  emails to pick a guidance profile. Local only.

None of these skills install hooks. Nothing runs automatically at session start.

## What was deliberately left out

Two skills from the same upstream were excluded because they rewrite your
environment rather than just advising:

- **`modern-python`** installs `SessionStart` PATH shims that make bare `python`,
  `pip`, `pipx`, and `uv` **exit 1** with a message telling you to use `uv run`.
  Reasonable if you've committed to uv, hostile if you haven't.
- **`gh-cli`** hooks `PreToolUse` on WebFetch and Bash to intercept GitHub
  requests, and hooks `SessionEnd` to delete cloned repos.

Both are legitimate and well-built — they're just opt-in decisions, not defaults
someone should inherit from a clone. Pull them from upstream if you want them.

Also skipped: **`second-opinion`** (routes work to a second model for review) needs
the `codex` CLI installed and an `.mcp.json` at the repo root. Good skill, but it's
dead config until that's set up.

## Anthropic's official skills

The 17 skills at [anthropics/skills](https://github.com/anthropics/skills) —
`algorithmic-art`, `canvas-design`, `theme-factory`, `web-artifacts-builder`,
`webapp-testing`, `mcp-builder`, and others — are **not vendored here**. That repo
ships no LICENSE file, so there's no grant to redistribute copies. Clone it
directly instead:

```bash
git clone https://github.com/anthropics/skills.git
```

Then copy the ones you want into `.claude/skills/`, or point Claude at them where
they sit. Note that `docx`, `pdf`, `pptx`, `xlsx`, `skill-creator`, and
`claude-api` already ship with Claude Code — you have those without doing anything.

## Attribution

All five skills come from
[trailofbits/skills](https://github.com/trailofbits/skills), licensed
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Full license text
is in [LICENSE-CC-BY-SA-4.0.txt](LICENSE-CC-BY-SA-4.0.txt).

The skill directories are copied **unmodified**. If you edit one, ShareAlike says
that modified skill stays under CC BY-SA 4.0 — it does not affect unrelated code
you write in this repo.
