# codex-switch: `model` command (list & switch models)

Date: 2026-08-21
Status: Approved design, ready for implementation plan
Target: open-source repo `~/codex-switch/codex-switch` (synced to `~/.local/bin` via `install.sh` later)

## Problem

A codex-switch profile pins exactly one `model=` per relay. To use a different
model the relay offers, the user must hand-edit `config.toml` — and they don't
know which model names the relay actually accepts. Guessing a name the relay
lacks produces `503 model_not_found` (already hit in practice). The VSCode plugin
only lets you pick from its built-in whitelist, whose names often don't match a
relay's custom names (e.g. dmx's `-cdx` suffixes, n1n's `-high` suffixes), so the
plugin shows "Custom" and can't switch to relay-specific models.

## Goal

Add a `model` command to codex-switch that (1) lists the models the **current
relay** actually offers, and (2) switches the active model to one of them, with
validation to prevent picking an unsupported name.

## Command interface

Single command, argument-dispatched:

- `codex-switch model` (no argument) — **list** models available on the current relay.
- `codex-switch model <name>` — **switch** the active model to `<name>`.
- `--no-db` — (existing global flag) when present with `model <name>`, skip the
  session-DB rewrite.

## Behavior

### `codex-switch model` (list)

1. Read current `base_url` from the `[model_providers.codex]` block of
   `config.toml` (reuse existing `cur_baseurl`).
2. Read the active API key from `auth.json`.
3. `curl -sS -m20` the relay's `<base_url>/models` with `Authorization: Bearer <key>`.
4. Parse model IDs from the JSON response:
   - python3 JSON parse preferred.
   - Fallback (no python3): `grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"'` then strip.
5. Print each model ID, one per line, marking the current model (top `model =`
   line in `config.toml`, read via new `cur_model`) with a leading `*`.
6. On fetch/parse failure: print HTTP status + first ~200 bytes of body to stderr
   and exit 1. Do not modify anything.

### `codex-switch model <name>` (switch)

1. Fetch + parse the model list (same as list mode).
2. **Validate**: if `<name>` is not in the fetched list:
   - If the list is non-empty → print
     `error: model '<name>' not found on <relay>. available:` + the list, exit 1.
   - If the list is empty (fetch returned nothing parseable but did not hard-fail)
     → print a "could not verify models on <relay>" warning and proceed anyway
     (so a flaky `/models` endpoint never locks the user out).
3. Backup `config.toml` to `.last-backup/config.toml.<ts>` (reuse existing backup +
   `prune_backups` machinery).
4. Edit top-level `model = "<name>"` in `config.toml` (reuse existing `sed` pattern).
5. Write back to the current profile's meta: set `model=<name>` in
   `cc-profiles/<current>/meta`.
   - "Current profile" = the profile whose `base_url` matches config's current
     `base_url` (reuse existing `current`).
   - If `current` resolves to unknown (no profile matches) → skip the meta write
     and print a warning that the choice was not persisted to any profile. Config
     + DB still updated.
6. Rewrite session models: newest `state_*.sqlite` (via existing `find_state_db`),
   `UPDATE threads SET model='<name>' WHERE model IS NOT NULL AND model<>'<name>'`.
   Skip entirely if `--no-db`. Reuse the same busy-timeout + backup + fallback
   behavior as `do_switch`.
7. Print confirmation: new model, relay, and (if DB touched) session count.

## Shared-logic refactor (targeted, not a rewrite)

`do_switch` currently inlines the session-DB rewrite block. Extract it into a
helper `rewrite_session_models <model>` that both `do_switch` and `do_model` call,
so the SQL and fallback handling exist in exactly one place. This is the only
structural change to existing code; `do_switch`'s external behavior is unchanged.

New helpers:
- `cur_model` — echo the top `model = "..."` value from `config.toml` (mirrors `cur_baseurl`).
- `fetch_models` — echo newline-separated model IDs from the current relay's
  `/models`; non-zero exit on fetch failure.
- `rewrite_session_models <model>` — the extracted DB-rewrite block; echoes a
  human-readable note (or warning) for the caller to print.
- `do_model [<name>]` — the command handler.

## Dispatch

Add `model)` to the `case` block in the arg dispatcher. `--no-db` is already
stripped globally before dispatch, so it applies to `model` automatically.

## Error handling summary

| Situation | Behavior |
|---|---|
| No `curl` | error "model command requires curl", exit 1 |
| `/models` HTTP error or non-JSON | print status + body head, exit 1, no writes |
| `model <name>`, name not in non-empty list | refuse, print available list, exit 1 |
| `model <name>`, list empty (flaky endpoint) | warn "could not verify", proceed |
| current source unknown (no matching profile) | update config + DB, warn meta not persisted |
| state DB busy / no sqlite3 | same as `do_switch`: warn, config+meta still applied |

## Dependencies

- `curl` — **required** for the `model` command (already used in the user's
  workflow; not required for `init`/`add`/`rm`/`switch`).
- `python3` — optional; grep/sed fallback for JSON parse.
- `sqlite3` — optional; DB rewrite skipped with a warning if absent (unchanged).

## Testing

Extend the temp-`CODEX_HOME` harness (`bash -n` + functional):

1. **Parse path** — feed `fetch_models`' parser a canned `/models` JSON blob
   (both python3 and grep/sed fallback) → correct ID extraction.
2. **Switch writes** — with a fake `state_*.sqlite` and a stubbed model list,
   `model <name>` updates config top `model`, writes profile meta, and rewrites
   `threads.model`.
3. **`--no-db`** — `model <name> --no-db` leaves the DB untouched.
4. **Validation** — `model <bad-name>` against a non-empty stub list refuses and
   exits 1 without writing.
5. **Unknown source** — config base_url matching no profile → config/DB updated,
   meta-write warning emitted.
6. **Dispatch / syntax** — `bash -n`; `model` appears in help text.
7. **Real relay** — one manual `model` (list) run against n1n and dmx to confirm
   live parse works.

## Out of scope

- Interactive numbered selection (chose the arg-based form).
- A separate `--temp`/`--once` non-persisting switch (chose always-persist to meta).
- Editing the plugin's model whitelist / making the plugin show a friendly name
  (documented as expected behavior in the README, not changed by this tool).
- Syncing to `~/.local/bin/codex-switch` — a separate user-triggered `install.sh` step.

## Documentation

Add a README section documenting `codex-switch model` / `model <name>`, and a FAQ
note tying it to the "plugin shows Custom / can't switch relay models" question:
model names come from the relay's `/models`, not the plugin whitelist.
