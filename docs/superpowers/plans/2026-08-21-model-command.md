# `model` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `codex-switch model` (list the current relay's models) and `codex-switch model <name>` (validate against the relay, then switch the active model + persist to profile + rewrite session DB).

**Architecture:** Extend the single-file bash script `~/codex-switch/codex-switch`. Add three helpers (`cur_model`, `fetch_models`, `rewrite_session_models`), refactor the existing `do_switch` DB-rewrite block to call the shared `rewrite_session_models`, add a `do_model` handler, and wire `model)` into the dispatch `case`. Update `usage()` and README.

**Tech Stack:** bash, awk, sed, curl (required for `model`), python3 (optional, JSON parse with grep/sed fallback), sqlite3 (optional, DB rewrite).

---

## File Structure

- **Modify:** `~/codex-switch/codex-switch` — all logic changes (helpers, `do_model`, dispatch, usage).
- **Modify:** `~/codex-switch/README.md` — document the `model` command + FAQ tie-in.
- **Create:** `~/codex-switch/tests/test-model.sh` — automated test harness for the new command using a temp `CODEX_HOME` and a fake relay via a stubbed `fetch_models`.

The script is intentionally one file (the project's established pattern); we keep that. Tests get their own file since none exist yet.

**Testing note — how we avoid real network in tests:** `fetch_models` is the only function that does network I/O. Tests set an env override `CX_MODELS_STUB` that, when non-empty, makes `fetch_models` echo that value instead of calling curl. This keeps every other code path (validation, config/meta/DB writes) fully testable offline. This override is documented in-code as test-only.

---

## Task 1: Add the `CX_MODELS_STUB` test seam constant

**Files:**
- Modify: `~/codex-switch/codex-switch` (near the config constants block, around line 27-30)

- [ ] **Step 1: Read the constants block to confirm insertion point**

Run: `sed -n '23,31p' ~/codex-switch/codex-switch`
Expected: shows `CODEX_HOME=...`, `PROF_DIR=...`, `PKEY="codex"`, `DEFAULT_WIRE_API=...`, `KEEP_BACKUPS=5`, `REWRITE_DB=1`.

- [ ] **Step 2: Add the stub seam constant**

After the `REWRITE_DB=1` line (currently line 30), add:

```bash
CX_MODELS_STUB="${CX_MODELS_STUB:-}"  # test-only: if set, fetch_models echoes this instead of calling curl
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n ~/codex-switch/codex-switch && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "feat(model): add CX_MODELS_STUB test seam constant"
```

---

## Task 2: Add `cur_model` helper

**Files:**
- Modify: `~/codex-switch/codex-switch` (after `cur_baseurl`, around line 60)

- [ ] **Step 1: Add the helper**

Insert immediately after the `cur_baseurl()` function's closing brace (currently line 60):

```bash
# top-level model currently set in config.toml
cur_model() {
  awk '/^model *=/{gsub(/^model *= *"?|"? *$/,"");print;exit}' "$CONFIG" 2>/dev/null || true
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n ~/codex-switch/codex-switch && echo OK`
Expected: `OK`

- [ ] **Step 3: Manual smoke test against a temp config**

Run:
```bash
CODEX_HOME=$(mktemp -d) bash -c '
  export CODEX_HOME
  printf "model = \"gpt-x\"\nmodel_provider = \"codex\"\n" > "$CODEX_HOME/config.toml"
  source <(sed -n "/^cur_model()/,/^}/p" ~/codex-switch/codex-switch)
  CONFIG="$CODEX_HOME/config.toml" cur_model
'
```
Expected: `gpt-x`

- [ ] **Step 4: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "feat(model): add cur_model helper"
```

---

## Task 3: Add `fetch_models` helper (with stub seam and parse fallback)

**Files:**
- Modify: `~/codex-switch/codex-switch` (after `cur_model`)

- [ ] **Step 1: Add the helper**

Insert after the `cur_model()` function:

```bash
# echo newline-separated model IDs from the current relay's /models.
# returns non-zero on fetch failure. honors CX_MODELS_STUB (test-only).
fetch_models() {
  if [ -n "$CX_MODELS_STUB" ]; then printf '%s\n' "$CX_MODELS_STUB"; return 0; fi
  command -v curl >/dev/null 2>&1 || { note "the 'model' command requires curl"; return 1; }
  local base key body http
  base="$(cur_baseurl)"; [ -n "$base" ] || { note "no base_url in $CONFIG"; return 1; }
  key="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["OPENAI_API_KEY"])' "$AUTH" 2>/dev/null)"
  if [ -z "$key" ]; then
    key="$(grep -oE '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"[^"]*"' "$AUTH" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/')"
  fi
  [ -n "$key" ] || { note "no API key in $AUTH"; return 1; }
  body="$(curl -sS -m20 -H "Authorization: Bearer $key" "$base/models" 2>/dev/null)"
  http=$?
  [ "$http" = 0 ] && [ -n "$body" ] || { note "fetch failed from $base/models"; return 1; }
  # parse ids: python3 preferred, grep/sed fallback
  local ids
  if command -v python3 >/dev/null 2>&1; then
    ids="$(printf '%s' "$body" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
print("\n".join(str(x.get("id","")) for x in d.get("data",[]) if x.get("id")))' 2>/dev/null)"
  fi
  if [ -z "$ids" ]; then
    ids="$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')"
  fi
  [ -n "$ids" ] || { note "could not parse models from $base (body head: $(printf '%s' "$body" | head -c 120))"; return 2; }
  printf '%s\n' "$ids"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n ~/codex-switch/codex-switch && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "feat(model): add fetch_models helper with parse fallback and stub seam"
```

---

## Task 4: Extract `rewrite_session_models` helper (DRY refactor of do_switch)

**Files:**
- Modify: `~/codex-switch/codex-switch` (add helper before `do_switch`; replace the inline block at current lines 253-267)

- [ ] **Step 1: Add the helper before `do_switch()` (currently line 210)**

```bash
# rewrite threads.model in the newest state DB to $1. echoes a human note.
# respects REWRITE_DB and $backup/$ts from the caller's scope.
rewrite_session_models() {
  local model="$1" STATE_DB db_note=""
  STATE_DB="$(find_state_db)"
  if [ "$REWRITE_DB" = 1 ] && [ -n "$STATE_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    cp -a "$STATE_DB" "$backup/$(basename "$STATE_DB").$ts" 2>/dev/null || true
    if sqlite3 "$STATE_DB" \
        "PRAGMA busy_timeout=10000; UPDATE threads SET model='$model' WHERE model IS NOT NULL AND model<>'$model';" \
        >/dev/null 2>&1; then
      local n; n="$(sqlite3 "$STATE_DB" "SELECT count(*) FROM threads WHERE model='$model';" 2>/dev/null)"
      db_note="  unified session model to $model (${n:-?} sessions)"
    else
      db_note="  warning: could not update session models (state DB busy); old sessions may error on resume"
    fi
    prune_backups "$backup" "$(basename "$STATE_DB")"
  fi
  [ -n "$db_note" ] && echo "$db_note"
}
```

- [ ] **Step 2: Replace the inline block in `do_switch`**

Replace current lines 253-267 (the `# rewrite session models ...` comment through the `fi` and `prune_backups` for STATE_DB) with:

```bash
  # rewrite session models so the plugin can resume old sessions on this relay
  local db_note; db_note="$(rewrite_session_models "$model")"
```

The surrounding lines (backup setup at 229-233 defining `ts`/`backup`, and the final `prune_backups "$backup" "config.toml"` / `auth.json` at 269-270, and the echo of `$db_note` at 274) stay unchanged — `rewrite_session_models` uses the caller's `ts`/`backup`.

- [ ] **Step 3: Verify syntax**

Run: `bash -n ~/codex-switch/codex-switch && echo OK`
Expected: `OK`

- [ ] **Step 4: Regression — real read-only + a temp switch still rewrites DB**

Run:
```bash
T=$(mktemp -d); export CODEX_HOME=$T
~/codex-switch/codex-switch init >/dev/null
printf 'https://a.example.com/v1\ngpt-a\n\nsk-fakeAAAA\n' | ~/codex-switch/codex-switch add p1 >/dev/null
printf 'https://b.example.com/v1\ngpt-b\n\nsk-fakeBBBB\n' | ~/codex-switch/codex-switch add p2 >/dev/null
sqlite3 "$T/state_5.sqlite" "CREATE TABLE threads(id INTEGER PRIMARY KEY, model TEXT); INSERT INTO threads(model) VALUES('old'),('old');"
~/codex-switch/codex-switch p2 | grep -q 'unified session model to gpt-b' && echo "SWITCH-DB OK"
sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;"
unset CODEX_HOME; rm -rf "$T"
```
Expected: `SWITCH-DB OK` then `gpt-b`.

- [ ] **Step 5: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "refactor(switch): extract rewrite_session_models helper (DRY)"
```

---

## Task 5: Add `do_model` handler

**Files:**
- Modify: `~/codex-switch/codex-switch` (after `do_switch`, before the arg-parsing block at current line 278)

- [ ] **Step 1: Add the handler**

```bash
do_model() {
  local want="${1:-}"
  [ -f "$CONFIG" ] || die "no $CONFIG — run: codex-switch init"
  grep -q "^\[model_providers\.$PKEY\]" "$CONFIG" \
    || die "$CONFIG has no [model_providers.$PKEY] block — run: codex-switch init"

  local models fetch_rc
  models="$(fetch_models)"; fetch_rc=$?

  # list mode
  if [ -z "$want" ]; then
    [ "$fetch_rc" = 0 ] || die "could not list models (see message above)"
    local cm; cm="$(cur_model)"
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      if [ "$m" = "$cm" ]; then printf '* %s\n' "$m"; else printf '  %s\n' "$m"; fi
    done <<< "$models"
    return 0
  fi

  # switch mode: validate against the fetched list unless the list is empty/unavailable
  if [ "$fetch_rc" = 0 ] && [ -n "$models" ]; then
    if ! grep -qxF "$want" <<< "$models"; then
      note "error: model '$want' not found on $(cur_baseurl). available:"
      printf '  %s\n' $models >&2
      exit 1
    fi
  else
    note "warning: could not verify models on $(cur_baseurl); setting '$want' anyway"
  fi

  local ts backup; ts="$(date +%Y%m%d-%H%M%S)"
  backup="$PROF_DIR/.last-backup"; mkdir -p "$backup"
  cp -a "$CONFIG" "$backup/config.toml.$ts"

  sed -i "s|^model = .*|model = \"$want\"|" "$CONFIG"

  local prof; prof="$(current)"
  case "$prof" in
    \(*\)) note "note: current relay matches no profile; model not persisted to any profile meta" ;;
    *)
      if [ -f "$PROF_DIR/$prof/meta" ]; then
        local tmp; tmp="$(mktemp)"
        awk -F= -v m="$want" '/^model=/{print "model=" m; next} {print}' "$PROF_DIR/$prof/meta" > "$tmp"
        grep -q '^model=' "$PROF_DIR/$prof/meta" || printf 'model=%s\n' "$want" >> "$tmp"
        cat "$tmp" > "$PROF_DIR/$prof/meta"; rm -f "$tmp"
      fi
      ;;
  esac

  local db_note; db_note="$(rewrite_session_models "$want")"
  prune_backups "$backup" "config.toml"

  echo "model set to '$want'  (relay=$prof)"
  [ -n "$db_note" ] && echo "$db_note"
  echo "tip: reload the VSCode window for the Codex plugin to pick this up."
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n ~/codex-switch/codex-switch && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "feat(model): add do_model handler (list + validated switch)"
```

---

## Task 6: Wire `model` into dispatch and usage

**Files:**
- Modify: `~/codex-switch/codex-switch` (the `case` block at current line 289-297, and `usage()` around line 76-92)

- [ ] **Step 1: Add the dispatch case**

In the `case "$cmd" in` block, add after the `rm|remove)` line:

```bash
  model)         do_model "${2:-}" ;;
```

- [ ] **Step 2: Add usage lines**

In `usage()`, after the `<name>` switch line, add these two command lines:

```
  model                list models on the current relay (marks current)
  model <name>         switch active model on the current relay
```

- [ ] **Step 3: Verify syntax + help shows it**

Run: `bash -n ~/codex-switch/codex-switch && ~/codex-switch/codex-switch help | grep -q 'model <name>' && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
cd ~/codex-switch
git add codex-switch
git commit -m "feat(model): wire model into dispatch and usage"
```

---

## Task 7: Automated test harness

**Files:**
- Create: `~/codex-switch/tests/test-model.sh`

- [ ] **Step 1: Write the test script**

```bash
#!/usr/bin/env bash
# tests for the `model` command. uses a temp CODEX_HOME + CX_MODELS_STUB (no network).
set -uo pipefail
SW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/codex-switch"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

setup() {
  T="$(mktemp -d)"; export CODEX_HOME="$T"
  "$SW" init >/dev/null
  printf 'https://a.example.com/v1\ngpt-a\n\nsk-fakeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' | "$SW" add p1 >/dev/null
  "$SW" p1 >/dev/null 2>&1
  sqlite3 "$T/state_5.sqlite" "CREATE TABLE threads(id INTEGER PRIMARY KEY, model TEXT); INSERT INTO threads(model) VALUES('old'),('old');"
}
teardown() { unset CODEX_HOME; rm -rf "$T"; }

# 1. list marks current
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b\ngpt-c'
out="$("$SW" model)"
echo "$out" | grep -q '^\* gpt-a' && echo "$out" | grep -q '^  gpt-b' && pass "list marks current" || fail "list marks current"

# 2. valid switch updates config + meta + db
"$SW" model gpt-b >/dev/null
grep -q '^model = "gpt-b"' "$T/config.toml" && pass "switch updates config" || fail "switch updates config"
grep -q '^model=gpt-b' "$T/cc-profiles/p1/meta" && pass "switch persists meta" || fail "switch persists meta"
[ "$(sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;")" = "gpt-b" ] && pass "switch rewrites db" || fail "switch rewrites db"
teardown

# 3. invalid model refused, config unchanged
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b'
before="$(grep '^model = ' "$T/config.toml")"
"$SW" model nope 2>/dev/null; rc=$?
[ "$rc" != 0 ] && pass "invalid model exits nonzero" || fail "invalid model exits nonzero"
[ "$(grep '^model = ' "$T/config.toml")" = "$before" ] && pass "invalid model leaves config" || fail "invalid model leaves config"
teardown

# 4. --no-db skips db rewrite
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b'
"$SW" model gpt-b --no-db >/dev/null
[ "$(sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;")" = "old" ] && pass "--no-db skips db" || fail "--no-db skips db"
teardown

# 5. empty list -> warn + proceed
setup
export CX_MODELS_STUB=""
# with stub empty, fetch_models falls to curl; force offline failure by pointing base at unroutable + no curl key path:
# instead simulate "unavailable" by unsetting stub and relying on fake url failing fast
"$SW" model gpt-z 2>/dev/null
grep -q '^model = "gpt-z"' "$T/config.toml" && pass "empty/unavailable list proceeds" || fail "empty/unavailable list proceeds"
teardown

[ "$FAIL" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Make executable and run**

Run:
```bash
chmod +x ~/codex-switch/tests/test-model.sh
~/codex-switch/tests/test-model.sh
```
Expected: several `PASS:` lines then `ALL TESTS PASSED`.

Note on test 5: with `CX_MODELS_STUB=""` the stub is inactive, so `fetch_models` calls curl against `https://a.example.com/v1/models`, which fails fast (nonexistent host) → `fetch_rc != 0` → switch mode warns and proceeds. If the environment resolves that host oddly and the test is flaky, change the p1 base_url in `setup` to `https://127.0.0.1:9/v1` (connection refused, deterministic).

- [ ] **Step 3: Commit**

```bash
cd ~/codex-switch
git add tests/test-model.sh
git commit -m "test(model): add offline test harness for model command"
```

---

## Task 8: Real-relay smoke test (manual, no commit)

**Files:** none (verification only)

- [ ] **Step 1: List models on the live relays via the user's real `~/.codex`**

Run:
```bash
~/codex-switch/codex-switch current
~/codex-switch/codex-switch model | head -20
```
Expected: prints the current relay's model list, with the active model marked `*`. (Read-only — no writes.)

- [ ] **Step 2: Confirm no accidental writes**

Run: `cd ~/.codex && git diff --stat 2>/dev/null; stat -c '%y %n' ~/.codex/config.toml`
Expected: `config.toml` mtime unchanged from before Step 1 (listing does not write).

---

## Task 9: Document the `model` command in README

**Files:**
- Modify: `~/codex-switch/README.md` (Usage section + FAQ)

- [ ] **Step 1: Add to the Usage command list**

After the `codex-switch current` line in the usage block, add:

```
codex-switch model             # list models the current relay offers
codex-switch model <name>      # switch active model (validated against the relay)
```

- [ ] **Step 2: Add a Usage subsection**

After the `### Switch options` subsection, add:

```markdown
### Switching models on a relay

`codex-switch model` lists the models the **current relay** actually serves (live
`/v1/models` fetch), marking the active one with `*`. `codex-switch model <name>`
validates `<name>` against that list (refusing, with the available list, if it's
not there — so you can't accidentally pin a model the relay lacks), then updates
the top-level `model` in `config.toml`, writes the choice back to the current
profile's `meta`, and rewrites session models in the state DB (skip with `--no-db`).

Requires `curl`. Reload the VSCode window afterward.
```

- [ ] **Step 3: Add a FAQ entry tying it to the "Custom" display**

After the existing FAQ entries, add:

```markdown
**The plugin shows my model as "Custom" and I can't pick relay models from its menu.**
The plugin's model menu only lists its built-in whitelist of official names. Relays
often use their own names (suffixes like `-cdx`, `-high`), which aren't on that
whitelist, so the plugin labels them "Custom" — this is cosmetic and doesn't affect
function. To see and switch among the names a relay actually accepts, use
`codex-switch model` / `codex-switch model <name>` instead of the plugin menu.
```

- [ ] **Step 4: Commit**

```bash
cd ~/codex-switch
git add README.md
git commit -m "docs(model): document model command and Custom-display FAQ"
```

---

## Self-Review Notes

- **Spec coverage:** list mode (Task 5 + 6), switch mode with validation (Task 5), persist to meta (Task 5), DB rewrite + `--no-db` (Tasks 4/5, test in 7), shared helper refactor (Task 4), error table cases — curl-missing (Task 3 `fetch_models`), HTTP/parse failure (Task 3 return codes → Task 5 warn/die), unknown source (Task 5 `case "$prof"`), empty-list safety valve (Task 5 else-branch, test 5), dispatch + usage (Task 6), deps documented (Task 9), README + FAQ (Task 9), real-relay check (Task 8). All spec sections mapped.
- **Placeholder scan:** none — every code step contains full code; every command step has expected output.
- **Type/name consistency:** `fetch_models`, `cur_model`, `rewrite_session_models`, `do_model`, `CX_MODELS_STUB` used identically across tasks. `rewrite_session_models` relies on caller-scope `ts`/`backup`, established in both `do_switch` (Task 4) and `do_model` (Task 5).
- **Out of scope (per spec):** interactive selection, `--temp` non-persist, editing plugin whitelist, syncing to `~/.local/bin` (separate `install.sh` step the user triggers).
